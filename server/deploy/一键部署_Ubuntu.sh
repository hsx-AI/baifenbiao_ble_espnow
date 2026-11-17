#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$SCRIPT_DIR/install_ubuntu.sh" "$SCRIPT_DIR/uninstall_ubuntu.sh" 2>/dev/null || true

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "需要 root 权限，正在使用 sudo 重新执行..."
  exec sudo -E bash "$SCRIPT_DIR/install_ubuntu.sh" "$@"
fi

exec bash "$SCRIPT_DIR/install_ubuntu.sh" "$@"
