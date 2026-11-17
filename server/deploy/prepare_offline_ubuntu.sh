#!/usr/bin/env bash
# 在有网络的 Ubuntu 24.04 上运行，下载 pip wheels 与系统 deb 离线包。
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
WHEELS_DIR="$SCRIPT_DIR/wheels"
DEBS_DIR="$SCRIPT_DIR/debs/ubuntu2404"

log() { echo "[*] $*"; }
die() { echo "[!] $*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || die "需要 python3"
command -v apt-get >/dev/null 2>&1 || die "需要 apt-get（Ubuntu/Debian）"

mkdir -p "$WHEELS_DIR" "$DEBS_DIR"

log "下载 pip wheels"
python3 -m pip download -r "$SERVER_DIR/requirements.txt" -d "$WHEELS_DIR"
python3 -m pip download pip setuptools wheel -d "$WHEELS_DIR"

log "下载 Ubuntu 24.04 系统 deb（python3-venv / bluez 等）"
PACKAGES=(
  python3
  python3-minimal
  python3-venv
  python3-pip
  python3-distutils
  python3-setuptools
  libpython3-stdlib
  python3.12
  python3.12-minimal
  python3.12-venv
  libpython3.12-stdlib
  libpython3.12-minimal
  bluez
  libbluetooth3
  bluetooth
)

cd "$DEBS_DIR"
for pkg in "${PACKAGES[@]}"; do
  apt-get download "$pkg" 2>/dev/null || log "跳过（可能未找到包名）: $pkg"
done

# 尝试下载依赖（离线 dpkg 安装更完整）
if command -v apt-rdepends >/dev/null 2>&1; then
  log "使用 apt-rdepends 补充依赖 deb"
  apt-rdepends python3-venv bluez 2>/dev/null | grep -v "^ " | while read -r dep; do
    apt-get download "$dep" 2>/dev/null || true
  done
fi

log "完成。"
log "wheels: $(find "$WHEELS_DIR" -name '*.whl' | wc -l) 个"
log "debs:   $(find "$DEBS_DIR" -name '*.deb' | wc -l) 个"
log "将整个 server 目录复制到 U 盘后，现场执行: sudo ./一键部署_Ubuntu.sh"
