#!/usr/bin/env bash
# 现场 Ubuntu 24.04 离线一键部署：安装服务、udev USB 权限、systemd 自启。
set -euo pipefail

INSTALL_DIR="/opt/percent-meter"
SERVICE_NAME="percent-meter"
SERVICE_USER="percent-meter"
ENV_DIR="/etc/percent-meter"
ENV_FILE="$ENV_DIR/env"
UDEV_RULES_DST="/etc/udev/rules.d/99-percent-meter-usb.rules"
SYSTEMD_UNIT_DST="/etc/systemd/system/${SERVICE_NAME}.service"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$SCRIPT_DIR"
SERVER_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
WHEELS_DIR="$DEPLOY_DIR/wheels"
DEBS_DIR="$DEPLOY_DIR/debs/ubuntu2404"

SERIAL_PORT="${SERIAL_PORT:-}"

log() { echo "[*] $*"; }
die() { echo "[!] $*" >&2; exit 1; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  die "请使用 root 运行: sudo $0"
fi

if [[ ! -d "$WHEELS_DIR" ]] || [[ -z "$(find "$WHEELS_DIR" -maxdepth 1 -name '*.whl' -print -quit 2>/dev/null)" ]]; then
  die "缺少 wheels 离线包，请先在有网机器运行 prepare_offline_ubuntu.sh"
fi

log "安装系统依赖（优先使用本地 deb，无网可用）"
if [[ -d "$DEBS_DIR" ]] && compgen -G "$DEBS_DIR/*.deb" > /dev/null; then
  dpkg -i "$DEBS_DIR"/*.deb 2>/dev/null || true
  apt-get install -f -y --no-install-recommends 2>/dev/null || true
else
  log "未找到本地 deb，尝试 apt（需联网或已预装 python3-venv / bluez）"
  apt-get update -qq 2>/dev/null || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3 python3-venv python3-pip bluez 2>/dev/null || true
fi

command -v python3 >/dev/null 2>&1 || die "未找到 python3，请补充 debs/ubuntu2404 离线包"

log "创建系统用户 $SERVICE_USER"
if ! id "$SERVICE_USER" &>/dev/null; then
  useradd --system --home "$INSTALL_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
fi
usermod -aG dialout,bluetooth "$SERVICE_USER" 2>/dev/null || usermod -aG dialout "$SERVICE_USER"

log "安装 udev USB/串口权限规则"
install -m 0644 "$DEPLOY_DIR/udev/99-percent-meter-usb.rules" "$UDEV_RULES_DST"
udevadm control --reload-rules
udevadm trigger

log "部署应用到 $INSTALL_DIR"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --exclude 'deploy' --exclude '__pycache__' "$SERVER_DIR/" "$INSTALL_DIR/"
else
  (
    cd "$SERVER_DIR"
    tar cf - --exclude=deploy --exclude='__pycache__' .
  ) | (
    cd "$INSTALL_DIR"
    tar xf -
  )
fi

log "创建 Python 虚拟环境并离线安装依赖"
python3 -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install --upgrade --no-index --find-links "$WHEELS_DIR" pip setuptools wheel
"$INSTALL_DIR/.venv/bin/pip" install --no-index --find-links "$WHEELS_DIR" -r "$INSTALL_DIR/requirements.txt"

chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"

log "写入环境配置 $ENV_FILE"
mkdir -p "$ENV_DIR"
if [[ -f "$ENV_FILE" ]]; then
  log "保留已有 $ENV_FILE，仅确保目录权限正确"
else
  cat >"$ENV_FILE" <<EOF
# 主站串口（推荐 /dev/serial/by-id/... 稳定路径）
# 留空则服务端自动扫描
SERIAL_PORT=${SERIAL_PORT}
SERIAL_BAUD=115200
SIMULATE=0
EOF
fi
chmod 0640 "$ENV_FILE"
chown root:"$SERVICE_USER" "$ENV_FILE"

log "安装 systemd 服务"
install -m 0644 "$DEPLOY_DIR/systemd/percent-meter.service" "$SYSTEMD_UNIT_DST"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then
  log "服务已启动"
else
  echo "[!] 服务未处于 active，请检查 journalctl -u $SERVICE_NAME -n 50" >&2
fi

echo ""
echo "========================================"
echo " Ubuntu 部署完成"
echo "========================================"
echo "  安装目录: $INSTALL_DIR"
echo "  环境文件: $ENV_FILE"
echo "  服务名:   $SERVICE_NAME"
echo "  访问:     http://<本机IP>:8000"
echo ""
echo "常用命令:"
echo "  sudo systemctl status $SERVICE_NAME"
echo "  sudo journalctl -u $SERVICE_NAME -f"
echo "  sudo systemctl restart $SERVICE_NAME"
echo ""
echo "查看主站稳定串口路径:"
echo "  ls -l /dev/serial/by-id/"
echo ""
