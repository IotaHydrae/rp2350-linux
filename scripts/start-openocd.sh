#!/usr/bin/env bash
#
# start-openocd.sh —— 启动 OpenOCD 连接 RP2350（CMSIS-DAP / DAPLink）
#
# 用法：
#   scripts/start-openocd.sh [速度] [核]
#     速度默认 10000 kHz（可在 2000~10000 间调，越慢越稳）
#     核默认 rv0（RP2350 双核：rv0 / rv1）
#
# 说明：
#   - 等价于你一直用的命令，只是参数化了速度/核，并加了防重复启动
#   - 装了仓库 udev/99-rp2350.rules 后可以把下面的 sudo 去掉
#   - 启动后 GDB 连 localhost:3333（配合 scripts/gdb-dump.sh）

set -euo pipefail

SPEED="${1:-10000}"
CORE="${2:-rv0}"

# 防重复启动：已经有一个连 rp2350 的 openocd 在跑就直接用
if pgrep -f "openocd.*rp2350" >/dev/null; then
	echo "OpenOCD already running (pid $(pgrep -f 'openocd.*rp2350' | tr '\n' ' '))."
	echo "If GDB cannot connect, 'sudo pkill openocd' and retry."
	exit 0
fi

# 权限提示：有 udev 规则就不需要 sudo
if [ "$(id -u)" != "0" ]; then
	echo "Note: on permission errors, install the udev rules (see udev/) or run with sudo."
fi

echo "Starting OpenOCD: speed=${SPEED}kHz core=${CORE} (Ctrl+C to stop)"
sudo openocd \
	-f interface/cmsis-dap.cfg \
	-c "set USE_CORE ${CORE}" \
	-f target/rp2350.cfg \
	-c "adapter speed ${SPEED}" \
	"$@"
