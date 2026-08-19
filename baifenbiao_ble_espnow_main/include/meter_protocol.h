#pragma once

#include <Arduino.h>

constexpr uint32_t METER_PACKET_MAGIC = 0x4D455452;
constexpr uint8_t METER_PACKET_VERSION = 2;
constexpr size_t METER_RAW_MAX = 32;

enum MeterFlags : uint8_t {
  METER_VALID = 1 << 0,
  METER_UNIT_INCH = 1 << 1,
  METER_FROM_NOTIFY = 1 << 2,
  METER_FROM_READ = 1 << 3,
  METER_FROM_HID = 1 << 4,
};

struct __attribute__((packed)) MeterPacket {
  uint32_t magic;
  uint8_t version;
  uint8_t nodeId;
  uint8_t meterId;
  uint8_t flags;
  uint32_t sequence;
  uint32_t uptimeMs;
  int32_t value01Um;  // 0.1 µm units, i.e. 0.0001 mm
  int8_t bleRssi;
  uint8_t rawLength;
  uint8_t raw[METER_RAW_MAX];
  uint32_t checksum;
};

inline uint32_t meterChecksum(const MeterPacket &packet) {
  const uint8_t *bytes = reinterpret_cast<const uint8_t *>(&packet);
  uint32_t hash = 2166136261UL;
  for (size_t i = 0; i < sizeof(MeterPacket) - sizeof(packet.checksum); ++i) {
    hash ^= bytes[i];
    hash *= 16777619UL;
  }
  return hash;
}

inline bool meterPacketValid(const MeterPacket &packet) {
  return packet.magic == METER_PACKET_MAGIC && packet.version == METER_PACKET_VERSION &&
         packet.rawLength <= METER_RAW_MAX && packet.checksum == meterChecksum(packet);
}
