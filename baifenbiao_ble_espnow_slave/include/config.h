#pragma once

#include <Arduino.h>

constexpr uint8_t MAX_METERS_PER_NODE = 5;
constexpr uint8_t DEFAULT_NODE_ID = 1;
constexpr uint32_t SERIAL_BAUD = 115200;
constexpr uint8_t ESPNOW_WIFI_CHANNEL = 1;
constexpr uint32_t BLE_SCAN_TIME_MS = 10000;
constexpr uint32_t BLE_RESCAN_DELAY_MS = 1200;
constexpr uint32_t STATUS_INTERVAL_MS = 2000;

// 当前样机的首次启动默认映射。NVS 初始化后，后续使用串口命令修改。
// 新复制的从站请逐台执行 map clear 1，再写入各自的 5 块表。
struct DefaultMeterMap {
  uint8_t meterId;
  const char *mac;
};

constexpr DefaultMeterMap DEFAULT_METER_MAP[MAX_METERS_PER_NODE] = {
    {1, "C4:AD:BF:FE:96:AF"},
    {0, ""},
    {0, ""},
    {0, ""},
    {0, ""},
};

constexpr char NUS_SERVICE_UUID[] = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
constexpr char NUS_RX_UUID[] = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";
constexpr char NUS_TX_UUID[] = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";
