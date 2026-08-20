# 蓝牙百分表 ESP-NOW 采集系统

系统链路：20 块 BLE 百分表 → 4 个 ESP32-C3 从站（每站最多 5 表）→ ESP-NOW → XIAO ESP32-C3 主站 → USB 串口 → FastAPI/WebSocket → 20 路网页看板。

## 主站烧录

```powershell
cd E:\Desktop\tuixiu_protect\baifenbiao_ble_espnow_main
pio run -t upload --upload-port COM11
```

## 从站烧录

```powershell
cd E:\Desktop\tuixiu_protect\baifenbiao_ble_espnow_slave
pio run -t upload --upload-port COM34
```

从站固件使用 MAC 白名单，每站最多配置 5 块表。MAC 同时映射为全局表号 1–20，未配置的设备不会连接。详细命令和四份 JSON 模板见从站工程的 `README.md`。

典型分配：

| 从站 | node_id | 全局表号 |
|---|---:|---|
| 从站 1 | 1 | 1–5 |
| 从站 2 | 2 | 6–10 |
| 从站 3 | 3 | 11–15 |
| 从站 4 | 4 | 16–20 |

主站无需配置从站 MAC，会接收所有协议正确的 ESP-NOW 广播包，并按 `meter_id` 输出到对应网页卡片。

每个已配置表槽位由从站每 2 秒发送一次状态心跳。网页状态含义：

- **在线**：从站心跳正常，并且对应百分表 BLE 仍连接；数值不变化也不会误报离线。
- **重连中**：从站仍在线，但对应百分表 BLE 已断开；从站按白名单自动扫描并重新订阅。
- **节点离线**：超过 6 秒没有收到该槽位心跳，通常是从站断电、ESP-NOW 信道不一致或主站没有收到无线包。

BLE 断开后会从 1 秒开始重试，连续连接失败时逐步退避，最长 30 秒；重新连接成功后重试计数自动清零。

设备配置页还提供“防关机实验”策略。推荐节点1作为关闭写入的对照组，节点2发送 `0D 0A`，节点3发送 `3F 0D 0A`，节点4发送 `00`，初始间隔90秒。点击“保存并写入从站”时，策略与MAC映射会一起写入从站NVS。

## 启动真实网页服务

```powershell
cd E:\Desktop\tuixiu_protect\baifenbiao_ble_espnow_main\server
python -m pip install -r requirements.txt
.\start_server.ps1 -Port COM11
```

打开 <http://127.0.0.1:8000>。使用 `-Simulate` 时显示的是模拟数据，接真实主站时不要加该参数。

网页顶部包含两个页面：

- **实时监控**：显示 1–20 号表的读数、在线状态、RSSI 和趋势。
- **设备配置**：使用服务器电脑的蓝牙扫描附近设备，将 MAC 分配给 4 台从站的 20 个槽位，并通过选定串口直接写入从站。

批量登记百分表时，应先断开或关闭从站，因为已经与从站建立 BLE 连接的百分表不会继续广播，电脑扫描不到。打开全部百分表后点击“扫描附近百分表”，优先查看标有“疑似百分表”的数字名称设备。分配完成后先保存映射，再依次把每台从站接到电脑并点击“保存并写入从站”。映射持久化保存在 `server/meter_config.json`。

主站串口中，`DATA ` 开头的是供服务端解析的 JSON，`#` 开头的是调试信息。串口输入 `stats` 可查看收包统计，输入 `reboot` 可重启主站。

## Ubuntu 部署

Windows 的 `start_server.ps1` 不能在 Ubuntu 上使用；服务端代码、网页、蓝牙扫描和从站串口配置均支持 Linux。首次安装：

```bash
sudo apt update
sudo apt install -y python3-venv bluez
cd /opt/baifenbiao_ble_espnow_main/server
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
sudo usermod -aG dialout,bluetooth "$USER"
```

重新登录让用户组生效，然后查看主站端口：

```bash
ls -l /dev/serial/by-id/
```

优先使用 `/dev/serial/by-id/...` 这种稳定路径，避免重启后 `/dev/ttyACM0` 编号改变。启动真实服务：

```bash
chmod +x start_server.sh
./start_server.sh --port /dev/serial/by-id/你的XIAO主站设备
```

打开 `http://Ubuntu服务器IP:8000`。配置从站时，网页会列出 `/dev/ttyACM*` 或 `/dev/ttyUSB*` 串口。不要选择正在作为主站使用的端口。

需要开机自启时，复制并修改 `server/percent-meter.service.example` 中的用户名、工程目录和串口路径，然后安装：

```bash
sudo cp percent-meter.service.example /etc/systemd/system/percent-meter.service
sudo systemctl daemon-reload
sudo systemctl enable --now percent-meter.service
sudo systemctl status percent-meter.service
```

如果系统没有 `bluetooth` 用户组，可从 `SupplementaryGroups` 中删除 `bluetooth`，并根据该 Ubuntu 版本的 BlueZ/PolicyKit 配置授予服务用户扫描权限。

## 实测百分表协议

- BLE 模式：SIMPLE / Nordic UART Service
- Service：`6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- Write：`6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
- Notify：`6E400003-B5A3-F393-E0A9-E50E24DCCA9E`
- 数据格式：ASCII，例如 `   2.9915\r\n`
- 网页与无线包保留 0.0001 mm 精度
