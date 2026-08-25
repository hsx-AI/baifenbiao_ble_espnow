#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="percent-meter"
INSTALL_DIR="/opt/percent-meter"
ENV_DIR="/etc/percent-meter"
UDEV_RULES="/etc/udev/rules.d/99-percent-meter-usb.rules"
SYSTEMD_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "请使用 sudo 运行" >&2
  exit 1
fi

echo "[*] 停止并禁用服务"
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
systemctl disable "$SERVICE_NAME" 2>/dev/null || true
rm -f "$SYSTEMD_UNIT"
systemctl daemon-reload

echo "[*] 删除安装目录"
rm -rf "$INSTALL_DIR"

echo "[*] 删除配置与 udev 规则"
rm -rf "$ENV_DIR"
rm -f "$UDEV_RULES"
udevadm control --reload-rules 2>/dev/null || true

echo "[*] 删除系统用户 percent-meter（若存在）"
userdel percent-meter 2>/dev/null || true

echo "卸载完成。"
