#include <Arduino.h>
#include <WiFi.h>
#include <esp_now.h>
#include <esp_wifi.h>

#include "meter_protocol.h"

namespace {

constexpr uint32_t SERIAL_BAUD = 115200;
constexpr uint8_t ESPNOW_WIFI_CHANNEL = 1;
constexpr size_t QUEUE_SIZE = 32;

struct ReceivedPacket {
  uint8_t senderMac[6];
  MeterPacket meter;
};

ReceivedPacket queue[QUEUE_SIZE]{};
volatile uint8_t queueHead = 0;
volatile uint8_t queueTail = 0;
volatile uint32_t droppedPackets = 0;
uint32_t receivedPackets = 0;
uint32_t invalidPackets = 0;
portMUX_TYPE queueMux = portMUX_INITIALIZER_UNLOCKED;

void onEspNowReceive(const uint8_t *mac, const uint8_t *data, int length) {
  if (length != static_cast<int>(sizeof(MeterPacket))) {
    ++invalidPackets;
    return;
  }
  uint8_t next = static_cast<uint8_t>((queueHead + 1) % QUEUE_SIZE);
  if (next == queueTail) {
    ++droppedPackets;
    return;
  }
  portENTER_CRITICAL_ISR(&queueMux);
  memcpy(queue[queueHead].senderMac, mac, 6);
  memcpy(&queue[queueHead].meter, data, sizeof(MeterPacket));
  queueHead = next;
  portEXIT_CRITICAL_ISR(&queueMux);
}

bool popPacket(ReceivedPacket &packet) {
  if (queueTail == queueHead) return false;
  portENTER_CRITICAL(&queueMux);
  packet = queue[queueTail];
  queueTail = static_cast<uint8_t>((queueTail + 1) % QUEUE_SIZE);
  portEXIT_CRITICAL(&queueMux);
  return true;
}

void printMac(const uint8_t *mac) {
  for (uint8_t i = 0; i < 6; ++i) {
    if (mac[i] < 0x10) Serial.print('0');
    Serial.print(mac[i], HEX);
    if (i < 5) Serial.print(':');
  }
}

void printHexCompact(const uint8_t *data, size_t length) {
  for (size_t i = 0; i < length; ++i) {
    if (data[i] < 0x10) Serial.print('0');
    Serial.print(data[i], HEX);
  }
}

const char *sourceName(uint8_t flags) {
  if (flags & METER_HEARTBEAT) return "heartbeat";
  if (flags & METER_FROM_HID) return "hid";
  if (flags & METER_FROM_NOTIFY) return "notify";
  if (flags & METER_FROM_READ) return "read";
  return "unknown";
}

void outputPacket(const ReceivedPacket &received) {
  const MeterPacket &packet = received.meter;
  if (!meterPacketValid(packet)) {
    ++invalidPackets;
    Serial.println("# [RX] rejected packet: magic/version/checksum error");
    return;
  }
  ++receivedPackets;
  Serial.print("DATA {\"node_id\":");
  Serial.print(packet.nodeId);
  Serial.print(",\"meter_id\":");
  Serial.print(packet.meterId);
  Serial.print(",\"sequence\":");
  Serial.print(packet.sequence);
  Serial.print(",\"uptime_ms\":");
  Serial.print(packet.uptimeMs);
  Serial.print(",\"valid\":");
  Serial.print((packet.flags & METER_VALID) ? "true" : "false");
  Serial.print(",\"heartbeat\":");
  Serial.print((packet.flags & METER_HEARTBEAT) ? "true" : "false");
  Serial.print(",\"ble_connected\":");
  Serial.print((packet.flags & METER_BLE_CONNECTED) ? "true" : "false");
  Serial.print(",\"value_mm\":");
  Serial.print(packet.value01Um / 10000.0, 4);
  Serial.print(",\"unit\":\"");
  Serial.print((packet.flags & METER_UNIT_INCH) ? "in" : "mm");
  Serial.print("\",\"source\":\"");
  Serial.print(sourceName(packet.flags));
  Serial.print("\",\"ble_rssi\":");
  Serial.print(packet.bleRssi);
  Serial.print(",\"sender_mac\":\"");
  printMac(received.senderMac);
  Serial.print("\",\"raw_hex\":\"");
  printHexCompact(packet.raw, packet.rawLength);
  Serial.println("\"}");
}

void printStats() {
  Serial.printf("# [STATS] received=%lu invalid=%lu dropped=%lu heap=%u channel=%u\n",
                static_cast<unsigned long>(receivedPackets),
                static_cast<unsigned long>(invalidPackets),
                static_cast<unsigned long>(droppedPackets), ESP.getFreeHeap(), ESPNOW_WIFI_CHANNEL);
}

void processSerialCommand() {
  if (!Serial.available()) return;
  String command = Serial.readStringUntil('\n');
  command.trim();
  command.toLowerCase();
  if (command == "stats" || command == "s") printStats();
  else if (command == "reboot") {
    Serial.println("# [CMD] rebooting");
    delay(100);
    ESP.restart();
  } else if (command.length()) {
    Serial.println("# [HELP] commands: stats | reboot");
  }
}

}  // namespace

void setup() {
  Serial.begin(SERIAL_BAUD);
  Serial.setTimeout(20);
  delay(1200);
  Serial.println("\n# === ESP-NOW meter gateway (XIAO ESP32C3) ===");
  WiFi.mode(WIFI_STA);
  esp_wifi_set_promiscuous(true);
  esp_wifi_set_channel(ESPNOW_WIFI_CHANNEL, WIFI_SECOND_CHAN_NONE);
  esp_wifi_set_promiscuous(false);
  Serial.printf("# [BOOT] gateway_mac=%s channel=%u baud=%lu\n", WiFi.macAddress().c_str(),
                ESPNOW_WIFI_CHANNEL, static_cast<unsigned long>(SERIAL_BAUD));
  if (esp_now_init() != ESP_OK) {
    Serial.println("# [FATAL] ESP-NOW init failed; rebooting");
    delay(1000);
    ESP.restart();
  }
  esp_now_register_recv_cb(onEspNowReceive);
  Serial.println("# [READY] waiting for slave packets; commands: stats | reboot");
}

void loop() {
  ReceivedPacket packet{};
  while (popPacket(packet)) outputPacket(packet);
  processSerialCommand();
  static uint32_t lastStatsMs = 0;
  if (millis() - lastStatsMs >= 10000) {
    lastStatsMs = millis();
    printStats();
  }
  delay(2);
}
