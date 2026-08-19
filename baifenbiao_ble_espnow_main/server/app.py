from __future__ import annotations

import asyncio
import json
import math
import os
import random
import re
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import serial
from bleak import BleakScanner
from serial.tools import list_ports
from fastapi import Body, FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles


BASE_DIR = Path(__file__).resolve().parent
WEB_DIR = BASE_DIR / "web"
CONFIG_FILE = BASE_DIR / "meter_config.json"
MAX_METERS = 20
BAUD_RATE = int(os.getenv("SERIAL_BAUD", "115200"))
REQUESTED_PORT = os.getenv("SERIAL_PORT", "").strip()
SIMULATE = os.getenv("SIMULATE", "0").lower() in {"1", "true", "yes", "on"}
MAC_PATTERN = re.compile(r"^[0-9A-F]{2}(?::[0-9A-F]{2}){5}$")
NUS_SERVICE = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"


class GatewayState:
    def __init__(self) -> None:
        self.meters: dict[int, dict[str, Any]] = {}
        self.serial_connected = False
        self.serial_port: str | None = None
        self.serial_error: str | None = None
        self.last_gateway_line: str | None = None
        self.total_packets = 0
        self.started_at = time.time()
        self.clients: set[WebSocket] = set()
        self.loop: asyncio.AbstractEventLoop | None = None
        self.stop_event = threading.Event()
        self.serial_thread: threading.Thread | None = None
        self.simulator_task: asyncio.Task[None] | None = None

    def status(self) -> dict[str, Any]:
        now = time.time()
        online = sum(
            1 for meter in self.meters.values()
            if meter.get("ble_connected", False) and now - meter["received_at"] < 6.0
        )
        return {
            "serial_connected": self.serial_connected,
            "serial_port": self.serial_port,
            "serial_error": self.serial_error,
            "baud_rate": BAUD_RATE,
            "simulate": SIMULATE,
            "online_meters": online,
            "total_packets": self.total_packets,
            "uptime_s": round(now - self.started_at, 1),
        }

    def accept_payload(self, payload: dict[str, Any]) -> None:
        try:
            meter_id = int(payload["meter_id"])
        except (KeyError, TypeError, ValueError):
            return
        if not 1 <= meter_id <= MAX_METERS:
            return
        now = time.time()
        heartbeat = bool(payload.get("heartbeat", False))
        previous = self.meters.get(meter_id)
        ble_connected = bool(payload.get("ble_connected", not heartbeat))
        valid = bool(payload.get("valid", False))
        measurement_at = (
            previous.get("measurement_at") if heartbeat and previous else now if not heartbeat else None
        )
        normalized = {
            "node_id": int(payload.get("node_id", 0)),
            "meter_id": meter_id,
            "sequence": int(payload.get("sequence", 0)),
            "valid": valid,
            "value_mm": float(payload.get("value_mm", 0.0)),
            "unit": str(payload.get("unit", "mm")),
            "source": str(payload.get("source", "unknown")),
            "ble_rssi": int(payload.get("ble_rssi", 0)),
            "sender_mac": str(payload.get("sender_mac", "")),
            "raw_hex": str(payload.get("raw_hex", "")),
            "received_at": now,
            "timestamp_ms": int(now * 1000),
            "measurement_at": measurement_at,
            "measurement_timestamp_ms": int(measurement_at * 1000) if measurement_at else None,
            "heartbeat": heartbeat,
            "ble_connected": ble_connected,
        }
        self.meters[meter_id] = normalized
        self.total_packets += 1
        if self.loop:
            self.loop.call_soon_threadsafe(
                lambda: asyncio.create_task(self.broadcast({
                    "type": "status" if heartbeat else "measurement",
                    "data": normalized,
                }))
            )

    async def broadcast(self, message: dict[str, Any]) -> None:
        stale: list[WebSocket] = []
        for client in tuple(self.clients):
            try:
                await client.send_json(message)
            except Exception:
                stale.append(client)
        for client in stale:
            self.clients.discard(client)


state = GatewayState()
ble_scan_lock = asyncio.Lock()


def default_meter_config() -> dict[str, Any]:
    nodes = []
    for node_id in range(1, 5):
        start = (node_id - 1) * 5 + 1
        meters = []
        for slot in range(1, 6):
            meter_id = start + slot - 1
            meters.append({"slot": slot, "meter_id": meter_id, "mac": "", "name": ""})
        nodes.append({"node_id": node_id, "port": "COM34" if node_id == 1 else "", "meters": meters})
    nodes[0]["meters"][0].update({"mac": "C4:AD:BF:FE:96:AF", "name": "021733486"})
    return {"version": 1, "nodes": nodes}


def normalize_mac(value: Any) -> str:
    return str(value or "").strip().upper().replace("-", ":")


def port_key(value: Any) -> str:
    """Windows COM names are case-insensitive; Linux /dev paths are not."""
    port = str(value or "").strip()
    return port.upper() if os.name == "nt" else port


def validate_meter_config(payload: dict[str, Any]) -> dict[str, Any]:
    nodes = payload.get("nodes")
    if not isinstance(nodes, list) or len(nodes) != 4:
        raise ValueError("配置必须包含4台从站")
    normalized_nodes: list[dict[str, Any]] = []
    seen_nodes: set[int] = set()
    seen_meters: set[int] = set()
    seen_macs: set[str] = set()
    for node in nodes:
        node_id = int(node.get("node_id", 0))
        if not 1 <= node_id <= 255 or node_id in seen_nodes:
            raise ValueError(f"从站编号无效或重复：{node_id}")
        seen_nodes.add(node_id)
        meters = node.get("meters")
        if not isinstance(meters, list) or len(meters) != 5:
            raise ValueError(f"从站{node_id}必须配置5个槽位")
        clean_meters: list[dict[str, Any]] = []
        seen_slots: set[int] = set()
        for meter in meters:
            slot = int(meter.get("slot", 0))
            meter_id = int(meter.get("meter_id", 0))
            mac = normalize_mac(meter.get("mac"))
            name = str(meter.get("name", ""))[:64]
            if not 1 <= slot <= 5 or slot in seen_slots:
                raise ValueError(f"从站{node_id}槽位无效或重复：{slot}")
            if not 1 <= meter_id <= MAX_METERS or meter_id in seen_meters:
                raise ValueError(f"表号无效或重复：{meter_id}")
            if mac and (not MAC_PATTERN.fullmatch(mac) or mac in seen_macs):
                raise ValueError(f"MAC格式错误或重复：{mac}")
            seen_slots.add(slot)
            seen_meters.add(meter_id)
            if mac:
                seen_macs.add(mac)
            clean_meters.append({"slot": slot, "meter_id": meter_id, "mac": mac, "name": name})
        normalized_nodes.append({
            "node_id": node_id,
            "port": str(node.get("port", "")).strip(),
            "meters": sorted(clean_meters, key=lambda item: item["slot"]),
        })
    return {"version": 1, "nodes": sorted(normalized_nodes, key=lambda item: item["node_id"])}


def load_meter_config() -> dict[str, Any]:
    if not CONFIG_FILE.exists():
        return default_meter_config()
    try:
        return validate_meter_config(json.loads(CONFIG_FILE.read_text(encoding="utf-8")))
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
        print(f"[config] load failed, using defaults: {exc}", flush=True)
        return default_meter_config()


def save_meter_config(payload: dict[str, Any]) -> dict[str, Any]:
    config = validate_meter_config(payload)
    temporary = CONFIG_FILE.with_suffix(".tmp")
    temporary.write_text(json.dumps(config, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(CONFIG_FILE)
    return config


def configure_slave_serial(port: str, node: dict[str, Any]) -> list[str]:
    logs: list[str] = []

    def read_lines(connection: serial.Serial, duration: float) -> None:
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            raw = connection.readline()
            if raw:
                logs.append(raw.decode("utf-8", errors="replace").rstrip())

    def send(connection: serial.Serial, command: str, wait: float = 0.25) -> None:
        logs.append(f"> {command}")
        connection.write((command + "\n").encode("ascii"))
        connection.flush()
        read_lines(connection, wait)

    with serial.Serial(port, BAUD_RATE, timeout=0.08) as connection:
        connection.dtr = False
        connection.rts = False
        read_lines(connection, 0.8)
        send(connection, f"node set {node['node_id']}")
        for slot in range(1, 6):
            send(connection, f"map clear {slot}")
        for meter in node["meters"]:
            if meter["mac"]:
                send(connection, f"map set {meter['slot']} {meter['meter_id']} {meter['mac']}")
        send(connection, "map show", 0.8)
        send(connection, "reboot", 0.15)
    return logs


def candidate_ports() -> list[str]:
    if REQUESTED_PORT:
        return [REQUESTED_PORT]
    ports = list(list_ports.comports())
    preferred = [
        port.device
        for port in ports
        if any(key in (port.description or "").lower() for key in ("usb", "jtag", "uart", "serial", "xiao"))
    ]
    remaining = [port.device for port in ports if port.device not in preferred]
    return preferred + remaining


def serial_worker() -> None:
    while not state.stop_event.is_set():
        ports = candidate_ports()
        if not ports:
            state.serial_connected = False
            state.serial_error = "未发现串口；请连接主站或设置 SERIAL_PORT"
            state.stop_event.wait(2.0)
            continue
        opened = False
        for port_name in ports:
            if state.stop_event.is_set():
                return
            try:
                with serial.Serial(port_name, BAUD_RATE, timeout=0.5) as connection:
                    opened = True
                    state.serial_connected = True
                    state.serial_port = port_name
                    state.serial_error = None
                    print(f"[serial] connected: {port_name} @ {BAUD_RATE}", flush=True)
                    while not state.stop_event.is_set():
                        raw = connection.readline()
                        if not raw:
                            continue
                        line = raw.decode("utf-8", errors="replace").strip()
                        if not line:
                            continue
                        state.last_gateway_line = line
                        print(f"[gateway] {line}", flush=True)
                        if not line.startswith("DATA "):
                            continue
                        try:
                            state.accept_payload(json.loads(line[5:]))
                        except (json.JSONDecodeError, TypeError, ValueError) as exc:
                            print(f"[serial] bad DATA line: {exc}", flush=True)
            except (serial.SerialException, OSError) as exc:
                state.serial_error = f"{port_name}: {exc}"
                continue
            finally:
                state.serial_connected = False
                state.serial_port = None
        if not opened:
            state.stop_event.wait(2.0)


async def simulator() -> None:
    sequence = 0
    started = time.monotonic()
    while not state.stop_event.is_set():
        sequence += 1
        elapsed = time.monotonic() - started
        value = 12.345 + math.sin(elapsed * 0.8) * 0.075 + random.uniform(-0.003, 0.003)
        state.accept_payload(
            {
                "node_id": 1,
                "meter_id": 1,
                "sequence": sequence,
                "valid": True,
                "heartbeat": False,
                "ble_connected": True,
                "value_mm": round(value, 4),
                "unit": "mm",
                "source": "simulation",
                "ble_rssi": -48 + random.randint(-3, 3),
                "sender_mac": "02:00:00:00:00:01",
                "raw_hex": f"{int(value * 1000):08x}",
            }
        )
        await asyncio.sleep(0.2)


@asynccontextmanager
async def lifespan(_: FastAPI):
    state.loop = asyncio.get_running_loop()
    state.stop_event.clear()
    if SIMULATE:
        state.simulator_task = asyncio.create_task(simulator())
        print("[server] simulation mode enabled", flush=True)
    else:
        state.serial_thread = threading.Thread(target=serial_worker, name="serial-reader", daemon=True)
        state.serial_thread.start()
    yield
    state.stop_event.set()
    if state.simulator_task:
        state.simulator_task.cancel()
    if state.serial_thread:
        state.serial_thread.join(timeout=2.0)


app = FastAPI(title="百分表采集看板", lifespan=lifespan)
app.mount("/assets", StaticFiles(directory=WEB_DIR), name="assets")


@app.get("/")
async def index() -> FileResponse:
    return FileResponse(WEB_DIR / "index.html")


@app.get("/api/status")
async def get_status() -> dict[str, Any]:
    return state.status()


@app.get("/api/meters")
async def get_meters() -> dict[str, Any]:
    return {"meters": list(state.meters.values()), "max_meters": MAX_METERS}


@app.get("/api/serial/ports")
async def get_serial_ports() -> dict[str, Any]:
    return {
        "ports": [
            {"device": port.device, "description": port.description or "串口设备", "hwid": port.hwid or ""}
            for port in list_ports.comports()
        ],
        "gateway_port": state.serial_port,
    }


@app.post("/api/ble/scan")
async def scan_ble(payload: dict[str, Any] = Body(default={})) -> dict[str, Any]:
    duration = max(2.0, min(float(payload.get("duration", 8)), 20.0))
    if ble_scan_lock.locked():
        raise HTTPException(status_code=409, detail="蓝牙扫描正在进行中")
    try:
        async with ble_scan_lock:
            discovered = await BleakScanner.discover(timeout=duration, return_adv=True)
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"蓝牙扫描失败：{exc}") from exc
    configured_macs = {
        meter["mac"]
        for node in load_meter_config()["nodes"]
        for meter in node["meters"]
        if meter["mac"]
    }
    devices = []
    for address, (device, advertisement) in discovered.items():
        name = advertisement.local_name or device.name or "未命名设备"
        services = [str(uuid).lower() for uuid in advertisement.service_uuids]
        likely_meter = bool(re.fullmatch(r"\d{6,12}", name)) or NUS_SERVICE in services
        devices.append({
            "address": normalize_mac(address),
            "name": name,
            "rssi": advertisement.rssi,
            "likely_meter": likely_meter,
            "configured": normalize_mac(address) in configured_macs,
            "service_uuids": services,
        })
    devices.sort(key=lambda item: (not item["likely_meter"], -item["rssi"], item["name"]))
    return {"devices": devices, "duration": duration}


@app.get("/api/config")
async def get_config() -> dict[str, Any]:
    return load_meter_config()


@app.put("/api/config")
async def put_config(payload: dict[str, Any] = Body(...)) -> dict[str, Any]:
    try:
        return {"ok": True, "config": save_meter_config(payload)}
    except (OSError, ValueError, TypeError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/configure-slave/{node_id}")
async def configure_slave(node_id: int, payload: dict[str, Any] = Body(default={})) -> dict[str, Any]:
    config = load_meter_config()
    node = next((item for item in config["nodes"] if item["node_id"] == node_id), None)
    if node is None:
        raise HTTPException(status_code=404, detail="未找到从站配置")
    requested_port = str(payload.get("port") or node.get("port") or "").strip()
    if not requested_port:
        raise HTTPException(status_code=400, detail="请选择从站串口")
    if state.serial_connected and port_key(requested_port) == port_key(state.serial_port):
        raise HTTPException(status_code=409, detail=f"{requested_port} 正被主站数据服务占用，不能作为从站配置口")
    available = {port_key(item.device): item.device for item in list_ports.comports()}
    port = available.get(port_key(requested_port))
    if port is None:
        raise HTTPException(status_code=404, detail=f"未找到串口 {requested_port}")
    try:
        logs = await asyncio.to_thread(configure_slave_serial, port, node)
    except (OSError, serial.SerialException) as exc:
        raise HTTPException(status_code=503, detail=f"打开或配置 {port} 失败：{exc}") from exc
    return {"ok": True, "node_id": node_id, "port": port, "logs": logs}


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket) -> None:
    await websocket.accept()
    state.clients.add(websocket)
    await websocket.send_json({"type": "snapshot", "meters": list(state.meters.values()), "status": state.status()})
    try:
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        state.clients.discard(websocket)
    except Exception:
        state.clients.discard(websocket)
