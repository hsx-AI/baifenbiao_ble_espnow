# 离线一键部署（U 盘现场服务器）

本目录用于**无公网**现场电脑部署百分表网关服务（FastAPI + WebSocket，端口 8000）。

## 目录结构

```
server/deploy/
├── 一键部署_Windows.bat      # 现场 Windows：双击（需管理员）
├── 一键部署_Ubuntu.sh        # 现场 Ubuntu：sudo 执行
├── install_windows.ps1
├── install_ubuntu.sh
├── uninstall_windows.ps1
├── uninstall_ubuntu.sh
├── prepare_offline_windows.ps1   # 有网 Windows：准备离线包
├── prepare_offline_ubuntu.sh     # 有网 Ubuntu：准备离线包
├── wheels/                       # pip 离线包（由 prepare 脚本生成）
├── debs/ubuntu2404/              # Ubuntu 24.04 离线 deb（由 prepare 生成）
├── nssm/                         # Windows 服务包装器（由 prepare 生成）
├── python-embed/                 # Windows 嵌入式 Python（由 prepare 生成）
├── systemd/percent-meter.service
└── udev/99-percent-meter-usb.rules
```

## 第一步：在有网络的电脑上准备 U 盘（只需做一次）

### Windows 准备机

```powershell
cd ...\baifenbiao_ble_espnow_main\server\deploy
.\prepare_offline_windows.ps1
```

将下载：嵌入式 Python 3.12、NSSM、pip 离线 wheels。

### Ubuntu 24.04 准备机

```bash
cd .../baifenbiao_ble_espnow_main/server/deploy
chmod +x prepare_offline_ubuntu.sh
./prepare_offline_ubuntu.sh
```

将下载：pip wheels、python3-venv / bluez 等 deb 包。

把整个 `baifenbiao_ble_espnow_main`（或至少 `server` 目录）复制到 U 盘。

## 第二步：现场无网电脑一键部署

### Windows 服务器

1. 插入 U 盘，进入 `server\deploy`
2. 双击 **`一键部署_Windows.bat`**（会请求管理员权限）
3. 默认安装到 `C:\PercentMeter`，服务名 `PercentMeter`
4. 浏览器打开 `http://本机IP:8000`

可选：安装前设置主站串口（也可安装后编辑 `C:\PercentMeter\service.env` 并重启服务）：

```powershell
.\install_windows.ps1 -SerialPort COM11
```

### Ubuntu 24.04 服务器

```bash
cd /path/to/usb/.../server/deploy
sudo ./一键部署_Ubuntu.sh
```

默认安装到 `/opt/percent-meter`，systemd 服务名 `percent-meter`。

安装后编辑主站串口（优先用 `/dev/serial/by-id/...` 稳定路径）：

```bash
sudo nano /etc/percent-meter/env
# 设置 SERIAL_PORT=/dev/serial/by-id/你的主站设备
sudo systemctl restart percent-meter
```

查看状态：

```bash
sudo systemctl status percent-meter
journalctl -u percent-meter -f
```

## 卸载

- Windows：以管理员运行 `uninstall_windows.ps1`
- Ubuntu：`sudo ./uninstall_ubuntu.sh`

## 说明

- Windows 使用 NSSM 注册为系统服务，开机自动启动。
- Ubuntu 使用 systemd，并自动安装 udev 规则（USB 串口权限）及服务用户 `percent-meter`（dialout / bluetooth 组）。
- 若未设置 `SERIAL_PORT`，服务端会自动扫描并连接疑似主站串口（与 `app.py` 逻辑一致）。
