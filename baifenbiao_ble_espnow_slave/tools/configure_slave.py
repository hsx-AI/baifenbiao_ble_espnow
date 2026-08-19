from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

import serial


MAC_PATTERN = re.compile(r"^[0-9A-F]{2}(?::[0-9A-F]{2}){5}$")


def normalize_mac(value: str) -> str:
    return value.strip().upper().replace("-", ":")


def load_mapping(path: Path) -> tuple[int, list[dict]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    node_id = int(data["node_id"])
    if not 1 <= node_id <= 255:
        raise ValueError("node_id 必须为 1..255")
    meters = []
    slots: set[int] = set()
    meter_ids: set[int] = set()
    macs: set[str] = set()
    for item in data.get("meters", []):
        mac = normalize_mac(str(item.get("mac", "")))
        if not mac:
            continue
        slot = int(item["slot"])
        meter_id = int(item["meter_id"])
        if not 1 <= slot <= 5:
            raise ValueError(f"slot {slot} 超出 1..5")
        if not 1 <= meter_id <= 20:
            raise ValueError(f"meter_id {meter_id} 超出 1..20")
        if not MAC_PATTERN.fullmatch(mac):
            raise ValueError(f"MAC 格式错误: {mac}")
        if slot in slots or meter_id in meter_ids or mac in macs:
            raise ValueError(f"配置内存在重复 slot/meter_id/MAC: {item}")
        slots.add(slot)
        meter_ids.add(meter_id)
        macs.add(mac)
        meters.append({"slot": slot, "meter_id": meter_id, "mac": mac})
    return node_id, meters


def read_available(connection: serial.Serial, duration: float = 0.8) -> None:
    deadline = time.monotonic() + duration
    while time.monotonic() < deadline:
        line = connection.readline()
        if line:
            print(line.decode("utf-8", errors="replace").rstrip())


def send(connection: serial.Serial, command: str, wait: float = 0.35) -> None:
    print(f"> {command}")
    connection.write((command + "\n").encode("ascii"))
    connection.flush()
    read_available(connection, wait)


def configure(port: str, config_path: Path, reboot: bool) -> None:
    node_id, meters = load_mapping(config_path)
    with serial.Serial(port, 115200, timeout=0.12) as connection:
        connection.dtr = False
        connection.rts = False
        print(f"已打开 {port}，等待从站启动……")
        read_available(connection, 1.5)
        send(connection, f"node set {node_id}")
        for slot in range(1, 6):
            send(connection, f"map clear {slot}")
        for item in meters:
            send(connection, f"map set {item['slot']} {item['meter_id']} {item['mac']}")
        send(connection, "map show", 0.8)
        if reboot:
            send(connection, "reboot", 0.2)
            print("配置完成，从站正在重启。")
        else:
            print("配置已保存；执行 reboot 后生效。")


def discover(port: str, seconds: int) -> None:
    with serial.Serial(port, 115200, timeout=0.15) as connection:
        connection.dtr = False
        connection.rts = False
        read_available(connection, 1.0)
        send(connection, "discover on")
        print(f"正在扫描 {seconds} 秒；百分表通常显示为数字名称并带 NUS 标记……")
        read_available(connection, seconds)
        send(connection, "discover off")


def main() -> int:
    parser = argparse.ArgumentParser(description="配置五表 ESP32-C3 从站的 MAC 白名单与全局表号")
    parser.add_argument("--port", required=True, help="从站串口，例如 COM34")
    parser.add_argument("--config", type=Path, help="从站 JSON 映射文件")
    parser.add_argument("--discover", type=int, metavar="SECONDS", help="仅扫描并列出附近 BLE 设备")
    parser.add_argument("--no-reboot", action="store_true", help="写入后暂不重启")
    args = parser.parse_args()
    try:
        if args.discover:
            discover(args.port, args.discover)
        elif args.config:
            configure(args.port, args.config, not args.no_reboot)
        else:
            parser.error("必须提供 --config 或 --discover")
    except (OSError, ValueError, KeyError, json.JSONDecodeError, serial.SerialException) as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
