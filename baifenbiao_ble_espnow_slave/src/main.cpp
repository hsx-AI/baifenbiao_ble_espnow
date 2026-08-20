#include <Arduino.h>
#include <NimBLEDevice.h>
#include <Preferences.h>
#include <WiFi.h>
#include <esp_now.h>
#include <esp_wifi.h>

#include <algorithm>
#include <cmath>

#include "config.h"
#include "meter_protocol.h"

namespace {

constexpr uint8_t kBroadcastAddress[6] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
constexpr size_t PACKET_QUEUE_SIZE = 32;

struct MeterMapEntry {
  bool enabled = false;
  uint8_t meterId = 0;
  char mac[18]{};
};

struct MeterRuntime {
  MeterMapEntry map;
  NimBLEClient *client = nullptr;
  NimBLERemoteCharacteristic *dataCharacteristic = nullptr;
  NimBLERemoteCharacteristic *controlCharacteristic = nullptr;
  bool connecting = false;
  bool connected = false;
  int8_t rssi = 0;
  uint32_t sequence = 0;
  uint32_t lastHeartbeatMs = 0;
  uint32_t lastKeepaliveMs = 0;
  uint32_t nextReconnectMs = 0;
  uint8_t reconnectAttempts = 0;
  int32_t lastValue01Um = 0;
  bool hasValue = false;
};

Preferences preferences;
MeterRuntime meters[MAX_METERS_PER_NODE];
uint8_t nodeId = DEFAULT_NODE_ID;
uint8_t keepaliveMode = 0;
uint32_t keepaliveIntervalMs = 90000;
bool discoveryMode = false;
bool rebootRequired = false;
uint32_t lastStatusMs = 0;
uint32_t lastScanStartMs = 0;

const NimBLEAdvertisedDevice *candidateDevice = nullptr;
volatile int8_t candidateSlot = -1;

MeterPacket packetQueue[PACKET_QUEUE_SIZE]{};
volatile uint8_t queueHead = 0;
volatile uint8_t queueTail = 0;
volatile uint32_t droppedPackets = 0;
portMUX_TYPE queueMux = portMUX_INITIALIZER_UNLOCKED;

void printHex(const uint8_t *data, size_t length);

String normalizeMac(String mac) {
  mac.trim();
  mac.toUpperCase();
  return mac;
}

bool validMac(const String &mac) {
  if (mac.length() != 17) return false;
  for (uint8_t i = 0; i < 17; ++i) {
    if ((i + 1) % 3 == 0) {
      if (mac[i] != ':') return false;
    } else if (!isxdigit(static_cast<unsigned char>(mac[i]))) {
      return false;
    }
  }
  return true;
}

String slotKey(const char *prefix, uint8_t index) {
  return String(prefix) + String(index);
}

void saveSlot(uint8_t index) {
  preferences.putUChar(slotKey("mid", index).c_str(), meters[index].map.meterId);
  preferences.putString(slotKey("mac", index).c_str(), meters[index].map.mac);
}

void initializeDefaults() {
  preferences.putBool("initialized", true);
  preferences.putUChar("node", DEFAULT_NODE_ID);
  for (uint8_t i = 0; i < MAX_METERS_PER_NODE; ++i) {
    meters[i].map.meterId = DEFAULT_METER_MAP[i].meterId;
    const String mac = normalizeMac(String(DEFAULT_METER_MAP[i].mac));
    strlcpy(meters[i].map.mac, mac.c_str(), sizeof(meters[i].map.mac));
    meters[i].map.enabled = meters[i].map.meterId > 0 && validMac(mac);
    saveSlot(i);
  }
}

void loadConfiguration() {
  preferences.begin("meter-map", false);
  if (!preferences.getBool("initialized", false)) initializeDefaults();
  nodeId = preferences.getUChar("node", DEFAULT_NODE_ID);
  keepaliveMode = preferences.getUChar("ka-mode", 0);
  if (keepaliveMode > 3) keepaliveMode = 0;
  const uint32_t storedKeepaliveSeconds = preferences.getUInt("ka-sec", 90);
  keepaliveIntervalMs = std::max<uint32_t>(30, std::min<uint32_t>(storedKeepaliveSeconds, 600)) * 1000UL;
  for (uint8_t i = 0; i < MAX_METERS_PER_NODE; ++i) {
    meters[i].map.meterId = preferences.getUChar(slotKey("mid", i).c_str(), 0);
    const String mac = normalizeMac(preferences.getString(slotKey("mac", i).c_str(), ""));
    strlcpy(meters[i].map.mac, mac.c_str(), sizeof(meters[i].map.mac));
    meters[i].map.enabled = meters[i].map.meterId >= 1 && meters[i].map.meterId <= 20 && validMac(mac);
  }
}

const char *keepaliveModeName(uint8_t mode) {
  switch (mode) {
    case 1: return "CRLF(0D0A)";
    case 2: return "QUERY(3F0D0A)";
    case 3: return "NUL(00)";
    default: return "OFF";
  }
}

void printConfiguration() {
  Serial.printf("[MAP] node_id=%u max_slots=%u%s\n", nodeId, MAX_METERS_PER_NODE,
                rebootRequired ? " REBOOT_REQUIRED" : "");
  Serial.printf("[KEEPALIVE] mode=%u name=%s interval_sec=%lu\n", keepaliveMode,
                keepaliveModeName(keepaliveMode),
                static_cast<unsigned long>(keepaliveIntervalMs / 1000UL));
  for (uint8_t i = 0; i < MAX_METERS_PER_NODE; ++i) {
    Serial.printf("[MAP] slot=%u meter_id=%u mac=%s state=%s\n", i + 1,
                  meters[i].map.meterId, meters[i].map.mac[0] ? meters[i].map.mac : "-",
                  !meters[i].map.enabled ? "disabled" :
                  meters[i].connected ? "connected" : meters[i].connecting ? "connecting" : "waiting");
  }
}

bool anyConfigured() {
  for (const auto &meter : meters) if (meter.map.enabled) return true;
  return false;
}

bool needsConnection() {
  const uint32_t now = millis();
  for (const auto &meter : meters) {
    if (meter.map.enabled && !meter.connected && !meter.connecting &&
        static_cast<int32_t>(now - meter.nextReconnectMs) >= 0) return true;
  }
  return false;
}

void scheduleReconnect(MeterRuntime &meter, const char *reason) {
  meter.connected = false;
  meter.connecting = false;
  meter.dataCharacteristic = nullptr;
  meter.controlCharacteristic = nullptr;
  const uint8_t exponent = std::min<uint8_t>(meter.reconnectAttempts, 5);
  const uint32_t delayMs = std::min<uint32_t>(RECONNECT_MIN_DELAY_MS << exponent,
                                               RECONNECT_MAX_DELAY_MS);
  if (meter.reconnectAttempts < 255) ++meter.reconnectAttempts;
  meter.nextReconnectMs = millis() + delayMs;
  Serial.printf("[RECONNECT] meter=%u reason=%s attempt=%u retry_in_ms=%lu\n",
                meter.map.meterId, reason, meter.reconnectAttempts,
                static_cast<unsigned long>(delayMs));
}

bool sendKeepalive(MeterRuntime &meter, bool manual) {
  if (!meter.connected || !meter.client || !meter.client->isConnected() ||
      !meter.controlCharacteristic || keepaliveMode == 0) return false;

  static const uint8_t kCrlf[] = {0x0D, 0x0A};
  static const uint8_t kQuery[] = {0x3F, 0x0D, 0x0A};
  static const uint8_t kNul[] = {0x00};
  const uint8_t *payload = nullptr;
  size_t payloadLength = 0;
  switch (keepaliveMode) {
    case 1: payload = kCrlf; payloadLength = sizeof(kCrlf); break;
    case 2: payload = kQuery; payloadLength = sizeof(kQuery); break;
    case 3: payload = kNul; payloadLength = sizeof(kNul); break;
    default: return false;
  }

  const bool withResponse = meter.controlCharacteristic->canWrite();
  const bool success = meter.controlCharacteristic->writeValue(payload, payloadLength, withResponse);
  Serial.printf("[KEEPALIVE] meter=%u mode=%u payload=", meter.map.meterId, keepaliveMode);
  printHex(payload, payloadLength);
  Serial.printf(" write=%s response=%s trigger=%s\n", success ? "ok" : "failed",
                withResponse ? "yes" : "no", manual ? "manual" : "timer");
  if (!success && (!meter.client || !meter.client->isConnected())) {
    scheduleReconnect(meter, "keepalive-write-failed");
  }
  return success;
}

void sendScheduledKeepalives() {
  if (keepaliveMode == 0) return;
  const uint32_t now = millis();
  for (auto &meter : meters) {
    if (!meter.map.enabled || !meter.connected ||
        now - meter.lastKeepaliveMs < keepaliveIntervalMs) continue;
    meter.lastKeepaliveMs = now;
    sendKeepalive(meter, false);
  }
}

uint8_t connectedCount() {
  uint8_t count = 0;
  for (const auto &meter : meters) if (meter.connected) ++count;
  return count;
}

uint8_t waitingCount() {
  uint8_t count = 0;
  for (const auto &meter : meters) {
    if (meter.map.enabled && !meter.connected) ++count;
  }
  return count;
}

MeterRuntime *runtimeForClient(NimBLEClient *client) {
  for (auto &meter : meters) if (meter.client == client) return &meter;
  return nullptr;
}

MeterRuntime *runtimeForCharacteristic(NimBLERemoteCharacteristic *characteristic) {
  for (auto &meter : meters) if (meter.dataCharacteristic == characteristic) return &meter;
  return nullptr;
}

void printHex(const uint8_t *data, size_t length) {
  for (size_t i = 0; i < length; ++i) {
    if (data[i] < 0x10) Serial.print('0');
    Serial.print(data[i], HEX);
    if (i + 1 < length) Serial.print(' ');
  }
}

bool parseAsciiNumber(const uint8_t *data, size_t length, int32_t &value01Um) {
  char text[64]{};
  const size_t copyLength = std::min(length, sizeof(text) - 1);
  size_t out = 0;
  for (size_t i = 0; i < copyLength; ++i) {
    const char c = static_cast<char>(data[i]);
    if ((c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.') text[out++] = c;
    else if (out > 0 && out < sizeof(text) - 1) text[out++] = ' ';
  }
  text[out] = '\0';

  char *cursor = text;
  bool found = false;
  float latest = 0;
  while (*cursor) {
    while (*cursor == ' ') ++cursor;
    if (!*cursor) break;
    char *end = nullptr;
    const float value = strtof(cursor, &end);
    if (end != cursor) {
      latest = value;
      found = true;
      cursor = end;
    } else {
      ++cursor;
    }
  }
  if (!found || !isfinite(latest)) return false;
  value01Um = static_cast<int32_t>(lroundf(latest * 10000.0f));
  return true;
}

void enqueuePacket(const MeterPacket &packet) {
  portENTER_CRITICAL(&queueMux);
  const uint8_t next = static_cast<uint8_t>((queueHead + 1) % PACKET_QUEUE_SIZE);
  if (next == queueTail) {
    ++droppedPackets;
  } else {
    packetQueue[queueHead] = packet;
    queueHead = next;
  }
  portEXIT_CRITICAL(&queueMux);
}

bool dequeuePacket(MeterPacket &packet) {
  if (queueTail == queueHead) return false;
  portENTER_CRITICAL(&queueMux);
  packet = packetQueue[queueTail];
  queueTail = static_cast<uint8_t>((queueTail + 1) % PACKET_QUEUE_SIZE);
  portEXIT_CRITICAL(&queueMux);
  return true;
}

void queueMeasurement(MeterRuntime &meter, const uint8_t *data, size_t length) {
  MeterPacket packet{};
  packet.magic = METER_PACKET_MAGIC;
  packet.version = METER_PACKET_VERSION;
  packet.nodeId = nodeId;
  packet.meterId = meter.map.meterId;
  packet.flags = METER_FROM_NOTIFY | METER_BLE_CONNECTED;
  packet.sequence = ++meter.sequence;
  packet.uptimeMs = millis();
  packet.bleRssi = meter.rssi;
  packet.rawLength = std::min(length, METER_RAW_MAX);
  memcpy(packet.raw, data, packet.rawLength);
  int32_t parsedValue01Um = 0;
  if (parseAsciiNumber(data, length, parsedValue01Um)) {
    packet.flags |= METER_VALID;
    meter.lastValue01Um = parsedValue01Um;
    meter.hasValue = true;
  }
  packet.value01Um = parsedValue01Um;
  packet.checksum = meterChecksum(packet);
  enqueuePacket(packet);
}

void queueHeartbeat(MeterRuntime &meter) {
  MeterPacket packet{};
  packet.magic = METER_PACKET_MAGIC;
  packet.version = METER_PACKET_VERSION;
  packet.nodeId = nodeId;
  packet.meterId = meter.map.meterId;
  packet.flags = METER_HEARTBEAT;
  if (meter.connected && meter.client && meter.client->isConnected()) {
    packet.flags |= METER_BLE_CONNECTED;
  }
  if (meter.hasValue) packet.flags |= METER_VALID;
  packet.sequence = ++meter.sequence;
  packet.uptimeMs = millis();
  packet.value01Um = meter.lastValue01Um;
  packet.bleRssi = meter.rssi;
  packet.checksum = meterChecksum(packet);
  enqueuePacket(packet);
}

void sendMeterHeartbeats() {
  const uint32_t now = millis();
  for (auto &meter : meters) {
    if (!meter.map.enabled || now - meter.lastHeartbeatMs < METER_HEARTBEAT_INTERVAL_MS) continue;
    meter.lastHeartbeatMs = now;
    queueHeartbeat(meter);
  }
}

void notifyCallback(NimBLERemoteCharacteristic *characteristic, uint8_t *data,
                    size_t length, bool isNotify) {
  MeterRuntime *meter = runtimeForCharacteristic(characteristic);
  if (!meter) return;
  Serial.printf("[BLE] meter=%u %s %u byte(s): ", meter->map.meterId,
                isNotify ? "notify" : "indicate", length);
  printHex(data, length);
  Serial.println();
  queueMeasurement(*meter, data, length);
}

class ClientCallbacks final : public NimBLEClientCallbacks {
 public:
  void onConnect(NimBLEClient *client) override {
    Serial.printf("[BLE] connected peer=%s\n", client->getPeerAddress().toString().c_str());
  }

  void onConnectFail(NimBLEClient *client, int reason) override {
    MeterRuntime *meter = runtimeForClient(client);
    if (meter) scheduleReconnect(*meter, "connect-failed");
    Serial.printf("[BLE] connect failed peer=%s reason=%d\n",
                  client->getPeerAddress().toString().c_str(), reason);
  }

  void onDisconnect(NimBLEClient *client, int reason) override {
    MeterRuntime *meter = runtimeForClient(client);
    if (meter) {
      Serial.printf("[BLE] meter=%u disconnected reason=%d\n", meter->map.meterId, reason);
      scheduleReconnect(*meter, "disconnected");
    }
  }
};

ClientCallbacks clientCallbacks;

class ScanCallbacks final : public NimBLEScanCallbacks {
 public:
  void onResult(const NimBLEAdvertisedDevice *device) override {
    const String address = normalizeMac(String(device->getAddress().toString().c_str()));
    const String name = device->haveName() ? String(device->getName().c_str()) : String();
    if (discoveryMode) {
      Serial.printf("[DISCOVER] mac=%s rssi=%d name='%s'%s\n", address.c_str(), device->getRSSI(),
                    name.c_str(), device->isAdvertisingService(NimBLEUUID(NUS_SERVICE_UUID)) ? " NUS" : "");
    }
    if (candidateSlot >= 0) return;
    for (uint8_t i = 0; i < MAX_METERS_PER_NODE; ++i) {
      if (!meters[i].map.enabled || meters[i].connected || meters[i].connecting) continue;
      if (static_cast<int32_t>(millis() - meters[i].nextReconnectMs) < 0) continue;
      if (address.equalsIgnoreCase(meters[i].map.mac)) {
        meters[i].connecting = true;
        candidateSlot = static_cast<int8_t>(i);
        candidateDevice = device;
        NimBLEDevice::getScan()->stop();
        Serial.printf("[SCAN] matched slot=%u meter=%u mac=%s rssi=%d\n", i + 1,
                      meters[i].map.meterId, address.c_str(), device->getRSSI());
        return;
      }
    }
  }

  void onScanEnd(const NimBLEScanResults &, int reason) override {
    if (reason != 0) Serial.printf("[SCAN] ended reason=%d\n", reason);
  }
};

ScanCallbacks scanCallbacks;

bool connectCandidate(uint8_t slot, const NimBLEAdvertisedDevice *device) {
  if (slot >= MAX_METERS_PER_NODE || !device) return false;
  MeterRuntime &meter = meters[slot];
  Serial.printf("[BLE] connecting slot=%u meter=%u to %s\n", slot + 1, meter.map.meterId,
                device->getAddress().toString().c_str());

  if (!meter.client) {
    meter.client = NimBLEDevice::createClient();
    if (!meter.client) {
      Serial.println("[BLE] createClient failed: connection limit reached");
      scheduleReconnect(meter, "client-limit");
      return false;
    }
    meter.client->setClientCallbacks(&clientCallbacks, false);
    // 50–100 ms connection interval leaves enough radio time for five meters + ESP-NOW.
    meter.client->setConnectionParams(40, 80, 0, 500);
    meter.client->setConnectTimeout(8000);
  }

  if (!meter.client->connect(device, true, false, true)) {
    Serial.printf("[BLE] meter=%u connection failed\n", meter.map.meterId);
    if (meter.connecting) scheduleReconnect(meter, "connect-returned-false");
    NimBLEDevice::deleteClient(meter.client);
    meter.client = nullptr;
    return false;
  }

  NimBLERemoteService *service = meter.client->getService(NUS_SERVICE_UUID);
  if (!service) {
    Serial.printf("[BLE] meter=%u NUS service missing\n", meter.map.meterId);
    meter.client->disconnect();
    meter.connecting = false;
    return false;
  }
  meter.dataCharacteristic = service->getCharacteristic(NUS_TX_UUID);
  if (!meter.dataCharacteristic || !meter.dataCharacteristic->canNotify()) {
    Serial.printf("[BLE] meter=%u NUS notify characteristic missing\n", meter.map.meterId);
    meter.client->disconnect();
    meter.connecting = false;
    return false;
  }
  if (!meter.dataCharacteristic->subscribe(true, notifyCallback)) {
    Serial.printf("[BLE] meter=%u subscribe failed\n", meter.map.meterId);
    meter.client->disconnect();
    meter.connecting = false;
    return false;
  }

  meter.controlCharacteristic = service->getCharacteristic(NUS_RX_UUID);
  if (keepaliveMode != 0 && (!meter.controlCharacteristic ||
      (!meter.controlCharacteristic->canWrite() && !meter.controlCharacteristic->canWriteNoResponse()))) {
    Serial.printf("[KEEPALIVE] meter=%u NUS write characteristic unavailable; strategy disabled for this link\n",
                  meter.map.meterId);
    meter.controlCharacteristic = nullptr;
  }

  meter.rssi = meter.client->getRssi();
  meter.connected = true;
  meter.connecting = false;
  meter.reconnectAttempts = 0;
  meter.nextReconnectMs = 0;
  // Do not write immediately after connection; wait a full interval so startup remains observable.
  meter.lastKeepaliveMs = millis();
  Serial.printf("[BLE] meter=%u ready rssi=%d connected=%u/%u\n", meter.map.meterId,
                meter.rssi, connectedCount(), MAX_METERS_PER_NODE);
  return true;
}

void startScanIfNeeded() {
  if (candidateSlot >= 0 || NimBLEDevice::getScan()->isScanning()) return;
  if (!needsConnection() && !discoveryMode) return;
  if (millis() - lastScanStartMs < BLE_RESCAN_DELAY_MS) return;
  lastScanStartMs = millis();
  NimBLEDevice::getScan()->start(BLE_SCAN_TIME_MS, false, true);
  Serial.printf("[SCAN] started; waiting=%u discovery=%s\n", waitingCount(),
                discoveryMode ? "on" : "off");
}

void sendQueuedPackets() {
  MeterPacket packet{};
  while (dequeuePacket(packet)) {
    const esp_err_t result = esp_now_send(kBroadcastAddress,
                                          reinterpret_cast<const uint8_t *>(&packet), sizeof(packet));
    Serial.printf("[ESPNOW] meter=%u seq=%lu type=%s connected=%s value=%.4f result=%s\n",
                  packet.meterId, static_cast<unsigned long>(packet.sequence),
                  (packet.flags & METER_HEARTBEAT) ? "heartbeat" : "measurement",
                  (packet.flags & METER_BLE_CONNECTED) ? "yes" : "no", packet.value01Um / 10000.0,
                  result == ESP_OK ? "queued" : esp_err_to_name(result));
  }
}

void setupEspNow() {
  WiFi.mode(WIFI_STA);
  esp_wifi_set_promiscuous(true);
  esp_wifi_set_channel(ESPNOW_WIFI_CHANNEL, WIFI_SECOND_CHAN_NONE);
  esp_wifi_set_promiscuous(false);
  Serial.printf("[ESPNOW] STA MAC=%s channel=%u\n", WiFi.macAddress().c_str(), ESPNOW_WIFI_CHANNEL);
  if (esp_now_init() != ESP_OK) {
    Serial.println("[ESPNOW] init failed; rebooting");
    delay(1000);
    ESP.restart();
  }
  esp_now_peer_info_t peer{};
  memcpy(peer.peer_addr, kBroadcastAddress, sizeof(kBroadcastAddress));
  peer.channel = ESPNOW_WIFI_CHANNEL;
  peer.encrypt = false;
  if (esp_now_add_peer(&peer) != ESP_OK) Serial.println("[ESPNOW] broadcast peer add failed");
}

void printHelp() {
  Serial.println("[CMD] map show");
  Serial.println("[CMD] map set <slot 1-5> <meter_id 1-20> <AA:BB:CC:DD:EE:FF>");
  Serial.println("[CMD] map clear <slot 1-5>");
  Serial.println("[CMD] node set <node_id 1-255>");
  Serial.println("[CMD] discover on|off   (only lists devices; whitelist still enforced)");
  Serial.println("[CMD] keepalive show");
  Serial.println("[CMD] keepalive set <mode 0-3> <seconds 30-600>");
  Serial.println("[CMD] keepalive send   (one test write to every connected meter)");
  Serial.println("[CMD] reboot");
}

void processCommand(String command) {
  command.trim();
  if (!command.length()) return;
  if (command.equalsIgnoreCase("help")) {
    printHelp();
    return;
  }
  if (command.equalsIgnoreCase("map show")) {
    printConfiguration();
    return;
  }
  if (command.equalsIgnoreCase("keepalive show")) {
    Serial.printf("[KEEPALIVE] mode=%u name=%s interval_sec=%lu\n", keepaliveMode,
                  keepaliveModeName(keepaliveMode),
                  static_cast<unsigned long>(keepaliveIntervalMs / 1000UL));
    return;
  }
  if (command.equalsIgnoreCase("keepalive send")) {
    if (keepaliveMode == 0) {
      Serial.println("[KEEPALIVE] mode is OFF; configure a mode first");
      return;
    }
    uint8_t sent = 0;
    for (auto &meter : meters) if (sendKeepalive(meter, true)) ++sent;
    Serial.printf("[KEEPALIVE] manual writes successful=%u/%u\n", sent, connectedCount());
    return;
  }
  if (command.equalsIgnoreCase("discover on")) {
    discoveryMode = true;
    NimBLEDevice::getScan()->stop();
    Serial.println("[CMD] discovery enabled");
    return;
  }
  if (command.equalsIgnoreCase("discover off")) {
    discoveryMode = false;
    Serial.println("[CMD] discovery disabled");
    return;
  }
  if (command.equalsIgnoreCase("reboot")) {
    Serial.println("[CMD] rebooting");
    delay(100);
    ESP.restart();
  }

  int slot = 0;
  int meterId = 0;
  char macText[24]{};
  int requestedKeepaliveMode = 0;
  int requestedKeepaliveSeconds = 0;
  if (sscanf(command.c_str(), "keepalive set %d %d", &requestedKeepaliveMode,
             &requestedKeepaliveSeconds) == 2) {
    if (requestedKeepaliveMode < 0 || requestedKeepaliveMode > 3 ||
        requestedKeepaliveSeconds < 30 || requestedKeepaliveSeconds > 600) {
      Serial.println("[KEEPALIVE] invalid; mode=0..3 seconds=30..600");
      return;
    }
    keepaliveMode = static_cast<uint8_t>(requestedKeepaliveMode);
    keepaliveIntervalMs = static_cast<uint32_t>(requestedKeepaliveSeconds) * 1000UL;
    preferences.putUChar("ka-mode", keepaliveMode);
    preferences.putUInt("ka-sec", static_cast<uint32_t>(requestedKeepaliveSeconds));
    for (auto &meter : meters) meter.lastKeepaliveMs = millis();
    Serial.printf("[KEEPALIVE] saved mode=%u name=%s interval_sec=%d; active immediately\n",
                  keepaliveMode, keepaliveModeName(keepaliveMode), requestedKeepaliveSeconds);
    return;
  }
  if (sscanf(command.c_str(), "map set %d %d %23s", &slot, &meterId, macText) == 3) {
    const String mac = normalizeMac(String(macText));
    if (slot < 1 || slot > MAX_METERS_PER_NODE || meterId < 1 || meterId > 20 || !validMac(mac)) {
      Serial.println("[CMD] invalid mapping; use: map set <1-5> <1-20> <MAC>");
      return;
    }
    MeterRuntime &meter = meters[slot - 1];
    meter.map.meterId = static_cast<uint8_t>(meterId);
    strlcpy(meter.map.mac, mac.c_str(), sizeof(meter.map.mac));
    meter.map.enabled = true;
    saveSlot(slot - 1);
    rebootRequired = true;
    Serial.printf("[CMD] saved slot=%d meter_id=%d mac=%s; reboot required\n", slot, meterId, mac.c_str());
    return;
  }
  if (sscanf(command.c_str(), "map clear %d", &slot) == 1) {
    if (slot < 1 || slot > MAX_METERS_PER_NODE) {
      Serial.println("[CMD] invalid slot");
      return;
    }
    MeterRuntime &meter = meters[slot - 1];
    meter.map = MeterMapEntry{};
    saveSlot(slot - 1);
    rebootRequired = true;
    Serial.printf("[CMD] cleared slot=%d; reboot required\n", slot);
    return;
  }
  int newNodeId = 0;
  if (sscanf(command.c_str(), "node set %d", &newNodeId) == 1) {
    if (newNodeId < 1 || newNodeId > 255) {
      Serial.println("[CMD] invalid node id");
      return;
    }
    nodeId = static_cast<uint8_t>(newNodeId);
    preferences.putUChar("node", nodeId);
    rebootRequired = true;
    Serial.printf("[CMD] saved node_id=%u; reboot required\n", nodeId);
    return;
  }
  Serial.println("[CMD] unknown command; type help");
}

void processSerialCommands() {
  if (!Serial.available()) return;
  processCommand(Serial.readStringUntil('\n'));
}

}  // namespace

void setup() {
  Serial.begin(SERIAL_BAUD);
  Serial.setTimeout(50);
  delay(1000);
  Serial.println("\n=== 5-meter BLE -> ESP-NOW slave ===");
  loadConfiguration();
  printConfiguration();
  setupEspNow();

  NimBLEDevice::init("meter-node");
  NimBLEDevice::setPower(3);
  NimBLEScan *scan = NimBLEDevice::getScan();
  scan->setScanCallbacks(&scanCallbacks, true);
  scan->setInterval(100);
  scan->setWindow(70);
  scan->setActiveScan(true);
  if (!anyConfigured()) {
    discoveryMode = true;
    Serial.println("[MAP] no configured meters; discovery automatically enabled");
  }
  printHelp();
}

void loop() {
  processSerialCommands();
  sendScheduledKeepalives();
  sendMeterHeartbeats();
  sendQueuedPackets();

  if (candidateSlot >= 0) {
    const int8_t slot = candidateSlot;
    const NimBLEAdvertisedDevice *device = candidateDevice;
    candidateSlot = -1;
    candidateDevice = nullptr;
    connectCandidate(static_cast<uint8_t>(slot), device);
  }
  startScanIfNeeded();

  if (millis() - lastStatusMs >= STATUS_INTERVAL_MS) {
    lastStatusMs = millis();
    for (auto &meter : meters) {
      if (!meter.connected) continue;
      if (meter.client && meter.client->isConnected()) {
        meter.rssi = meter.client->getRssi();
      } else {
        scheduleReconnect(meter, "link-check-failed");
      }
    }
    Serial.printf("[STATUS] node=%u connected=%u/%u heap=%u dropped=%lu%s\n", nodeId,
                  connectedCount(), MAX_METERS_PER_NODE, ESP.getFreeHeap(),
                  static_cast<unsigned long>(droppedPackets), rebootRequired ? " REBOOT_REQUIRED" : "");
  }
  delay(5);
}
