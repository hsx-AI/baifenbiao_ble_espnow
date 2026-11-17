#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SERIAL_PORT_VALUE=""
SIMULATE_VALUE="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      SERIAL_PORT_VALUE="${2:?--port 后需要串口路径}"
      shift 2
      ;;
    --simulate)
      SIMULATE_VALUE="1"
      shift
      ;;
    *)
      echo "用法: $0 [--port /dev/ttyACM0] [--simulate]" >&2
      exit 2
      ;;
  esac
done

if [[ -n "$SERIAL_PORT_VALUE" ]]; then
  export SERIAL_PORT="$SERIAL_PORT_VALUE"
else
  unset SERIAL_PORT 2>/dev/null || true
fi
export SIMULATE="$SIMULATE_VALUE"

exec python3 -m uvicorn app:app --host 0.0.0.0 --port 8000
