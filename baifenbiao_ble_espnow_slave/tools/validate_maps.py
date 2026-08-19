from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    config_dir = Path(__file__).resolve().parent / "maps"
    seen_meter: dict[int, str] = {}
    seen_mac: dict[str, str] = {}
    errors: list[str] = []
    for path in sorted(config_dir.glob("slave*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        for item in data.get("meters", []):
            mac = str(item.get("mac", "")).strip().upper().replace("-", ":")
            if not mac:
                continue
            meter_id = int(item["meter_id"])
            location = f"{path.name}/slot{item['slot']}"
            if meter_id in seen_meter:
                errors.append(f"表号 {meter_id} 重复：{seen_meter[meter_id]} 与 {location}")
            if mac in seen_mac:
                errors.append(f"MAC {mac} 重复：{seen_mac[mac]} 与 {location}")
            seen_meter[meter_id] = location
            seen_mac[mac] = location
    if errors:
        print("映射校验失败：")
        print("\n".join(f"- {error}" for error in errors))
        return 1
    print(f"映射校验通过：{len(seen_meter)} 块表，MAC 与全局表号均无重复。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
