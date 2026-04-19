#!/bin/bash
# Rebuild bridge library and VCS simulation on remote server
# Files modified:
#   - build/CMakeCache.txt (deleted to clear stale cache)
#   - build/ directory (cmake regenerates)
#   - vcs-tb/sim_build/simv (VCS recompiled)
set -e
export PATH=/home/ryan/.local/bin:/home/ryan/miniconda3/bin:$PATH
export SNPSLMD_LICENSE_FILE=/opt/synopsys/license/license.dat
export LM_LICENSE_FILE=/opt/synopsys/license/license.dat

cd /home/ryan/workspace/cosim-platform

# Step 1: Rebuild bridge library
echo "=== Rebuilding bridge library ==="
rm -f build/CMakeCache.txt
cmake -B build -DCMAKE_BUILD_TYPE=Debug 2>&1 | tail -5
cmake --build build -j$(nproc) 2>&1 | tail -10
echo "Bridge library rebuilt"

# Step 2: Rebuild VCS simulation
echo ""
echo "=== Rebuilding VCS simulation ==="
mkdir -p vcs-tb/sim_build
cd vcs-tb/sim_build

# Find VCS
VCS_BIN=$(which vcs 2>/dev/null || echo "")
if [ -z "$VCS_BIN" ]; then
    # Try common VCS paths
    for p in /opt/synopsys/vcs/*/bin/vcs /eda/synopsys/vcs/*/bin/vcs; do
        if [ -x "$p" ]; then VCS_BIN="$p"; break; fi
    done
fi
if [ -z "$VCS_BIN" ]; then
    echo "ERROR: VCS not found"
    exit 1
fi
echo "Using VCS: $VCS_BIN"

$VCS_BIN -full64 -sverilog \
    -CFLAGS "-I ../../bridge/common -I ../../bridge/qemu -I ../../bridge/vcs -I ../../bridge/eth" \
    ../../bridge/vcs/bridge_vcs.c \
    ../../bridge/vcs/virtqueue_dma.c \
    ../../bridge/common/ring_buffer.c \
    ../../bridge/common/shm_layout.c \
    ../../bridge/qemu/sock_sync.c \
    ../../bridge/eth/eth_mac_dpi.c \
    ../../bridge/vcs/bridge_vcs.sv \
    ../*.sv \
    -LDFLAGS "-lrt -lpthread" \
    -o simv 2>&1 | tail -20

echo ""
echo "=== Build complete ==="
ls -la simv
