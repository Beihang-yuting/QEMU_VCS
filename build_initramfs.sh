#!/bin/bash
# ============================================================
# CoSim Platform - Guest Initramfs 构建脚本
# 构建包含 BusyBox、内核模块、guest init 脚本的自包含 initramfs
# ============================================================
set -e

# === 脚本所在目录 ===
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# === 加载配置 ===
if [ -f "$SCRIPT_DIR/config.env" ]; then
    source "$SCRIPT_DIR/config.env"
else
    echo "警告: config.env 未找到，使用默认值"
    INCLUDE_IPERF3=0
    INCLUDE_NETCAT=0
fi

# === 默认参数 ===
KVER="$(uname -r)"
OUTPUT_DIR="$SCRIPT_DIR/images"
BUILD_ALL=0
BUILD_PHASE=""
BUSYBOX_URL="https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"

# === 临时目录（退出时清理）===
WORK_DIR=""
cleanup() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        echo "[清理] 删除临时目录: $WORK_DIR"
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

# === 帮助信息 ===
usage() {
    cat <<EOF
用法: $0 [选项]
  -k <kernel_version>   指定内核版本 (默认: $(uname -r))
  -o <output_dir>       输出目录 (默认: images/)
  -a                    构建所有变体 (phase4, phase5, tap)
  -p <phase>            构建指定变体: phase4, phase5, tap
  -h                    显示帮助

示例:
  $0 -a                        # 构建所有变体
  $0 -p tap                    # 只构建 TAP 变体
  $0 -k 6.1.0-20-generic -a   # 使用指定内核版本
EOF
    exit 0
}

# === 解析命令行参数 ===
while getopts "k:o:ap:h" opt; do
    case "$opt" in
        k) KVER="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        a) BUILD_ALL=1 ;;
        p) BUILD_PHASE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# 检查是否指定了构建目标
if [ "$BUILD_ALL" -eq 0 ] && [ -z "$BUILD_PHASE" ]; then
    echo "错误: 请指定 -a (全部构建) 或 -p <phase> (指定变体)"
    usage
fi

# 验证 phase 参数
if [ -n "$BUILD_PHASE" ]; then
    case "$BUILD_PHASE" in
        phase4|phase5|tap) ;;
        *) echo "错误: 未知变体 '$BUILD_PHASE'，支持: phase4, phase5, tap"; exit 1 ;;
    esac
fi

# === 确定要构建的变体列表 ===
if [ "$BUILD_ALL" -eq 1 ]; then
    VARIANTS="phase4 phase5 tap"
else
    VARIANTS="$BUILD_PHASE"
fi

echo "============================================================"
echo " CoSim Platform - Initramfs 构建"
echo "============================================================"
echo "  内核版本:   $KVER"
echo "  输出目录:   $OUTPUT_DIR"
echo "  构建变体:   $VARIANTS"
echo "  IPERF3:     ${INCLUDE_IPERF3:-0}"
echo "  NETCAT:     ${INCLUDE_NETCAT:-0}"
echo "============================================================"
echo ""

# === 创建输出目录 ===
mkdir -p "$OUTPUT_DIR"

# === 创建工作目录 ===
WORK_DIR="/tmp/cosim_initramfs_build_$$"
mkdir -p "$WORK_DIR"
echo "[1/7] 工作目录: $WORK_DIR"

# === 构建基础 rootfs 结构 ===
BASE_DIR="$WORK_DIR/base"
mkdir -p "$BASE_DIR"/{bin,sbin,usr/bin,lib/modules,dev,proc,sys,tmp,etc}

# ============================================================
# 步骤 2: 获取 BusyBox 静态二进制
# ============================================================
echo ""
echo "[2/7] 获取 BusyBox 静态二进制..."

BUSYBOX_BIN=""

# 方法 1: 检查系统是否已安装 busybox-static
if command -v busybox >/dev/null 2>&1; then
    SYSTEM_BB="$(command -v busybox)"
    if file "$SYSTEM_BB" | grep -q "static"; then
        echo "  找到系统静态 busybox: $SYSTEM_BB"
        BUSYBOX_BIN="$SYSTEM_BB"
    else
        echo "  系统 busybox 不是静态链接，尝试其他方式"
    fi
fi

# 方法 1b: 检查 dpkg 安装的 busybox-static
if [ -z "$BUSYBOX_BIN" ] && command -v dpkg >/dev/null 2>&1; then
    BB_STATIC="$(dpkg -L busybox-static 2>/dev/null | grep '/bin/busybox$' | head -1)"
    if [ -n "$BB_STATIC" ] && [ -x "$BB_STATIC" ]; then
        echo "  找到 busybox-static 包: $BB_STATIC"
        BUSYBOX_BIN="$BB_STATIC"
    fi
fi

# 方法 2: 从网络下载
if [ -z "$BUSYBOX_BIN" ]; then
    echo "  系统未找到静态 busybox，从网络下载..."
    BUSYBOX_DL="$WORK_DIR/busybox_download"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$BUSYBOX_DL" "$BUSYBOX_URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$BUSYBOX_DL" "$BUSYBOX_URL"
    else
        echo "错误: 无法下载 busybox (curl/wget 均不可用)"
        exit 1
    fi

    if [ ! -f "$BUSYBOX_DL" ]; then
        echo "错误: busybox 下载失败"
        exit 1
    fi
    chmod +x "$BUSYBOX_DL"

    # 验证静态链接
    if ! file "$BUSYBOX_DL" | grep -q "static"; then
        echo "警告: 下载的 busybox 可能不是静态链接"
    fi
    BUSYBOX_BIN="$BUSYBOX_DL"
fi

# 复制 busybox 到 base
cp "$BUSYBOX_BIN" "$BASE_DIR/bin/busybox"
chmod +x "$BASE_DIR/bin/busybox"
echo "  BusyBox 已安装到 base/bin/busybox"

# 创建 busybox 符号链接
# bin/ 下的常用命令
BB_BIN_LINKS="sh ash ls cat cp mv rm mkdir rmdir ln chmod chown
    mount umount ip ping arp ifconfig route
    dd wc od head tail grep sed awk
    echo printf sleep kill ps
    dmesg hostname uname date
    vi less more sort uniq tr cut tee
    find xargs dirname basename
    true false test [ expr seq
    tar gzip gunzip zcat
    free top df du"

# sbin/ 下的命令
BB_SBIN_LINKS="insmod modprobe rmmod lsmod
    ifconfig route halt poweroff reboot
    sysctl mdev"

echo "  创建 BusyBox 符号链接..."
for cmd in $BB_BIN_LINKS; do
    ln -sf busybox "$BASE_DIR/bin/$cmd"
done

for cmd in $BB_SBIN_LINKS; do
    ln -sf ../bin/busybox "$BASE_DIR/sbin/$cmd"
done

# 统计链接数量
LINK_COUNT=$(find "$BASE_DIR/bin" "$BASE_DIR/sbin" -type l | wc -l)
echo "  已创建 $LINK_COUNT 个符号链接"

# ============================================================
# 步骤 3: 提取内核模块
# ============================================================
echo ""
echo "[3/7] 提取内核模块 (kernel $KVER)..."

KMOD_SRC="/lib/modules/$KVER/kernel"
KMOD_DST="$BASE_DIR/lib/modules/$KVER/kernel"
mkdir -p "$KMOD_DST"

# 辅助函数: 复制模块（处理 .ko, .ko.xz, .ko.zst 压缩格式）
copy_module() {
    local src_path="$1"
    local dst_dir="$2"
    local mod_name="$3"

    mkdir -p "$dst_dir"

    if [ -f "$src_path" ]; then
        cp "$src_path" "$dst_dir/"
        echo "    已复制: $mod_name"
        return 0
    elif [ -f "${src_path}.xz" ]; then
        cp "${src_path}.xz" "$dst_dir/"
        xz -d "$dst_dir/$(basename ${src_path}.xz)" 2>/dev/null || true
        echo "    已复制并解压 (xz): $mod_name"
        return 0
    elif [ -f "${src_path}.zst" ]; then
        cp "${src_path}.zst" "$dst_dir/"
        zstd -d "$dst_dir/$(basename ${src_path}.zst)" --rm 2>/dev/null || true
        echo "    已复制并解压 (zst): $mod_name"
        return 0
    fi
    return 1
}

# 需要的模块列表
VIRTIO_NET_FOUND=0

# failover.ko (可选)
copy_module "$KMOD_SRC/net/core/failover.ko" \
    "$KMOD_DST/net/core" "failover.ko" || \
    echo "    跳过: failover.ko (不存在)"

# net_failover.ko (可选)
copy_module "$KMOD_SRC/drivers/net/net_failover.ko" \
    "$KMOD_DST/drivers/net" "net_failover.ko" || \
    echo "    跳过: net_failover.ko (不存在)"

# virtio_net.ko (必需)
if copy_module "$KMOD_SRC/drivers/net/virtio_net.ko" \
    "$KMOD_DST/drivers/net" "virtio_net.ko"; then
    VIRTIO_NET_FOUND=1
fi

# virtio 核心模块 (可能是内建的)
copy_module "$KMOD_SRC/drivers/virtio/virtio.ko" \
    "$KMOD_DST/drivers/virtio" "virtio.ko" || \
    echo "    跳过: virtio.ko (可能是内建模块)"

copy_module "$KMOD_SRC/drivers/virtio/virtio_ring.ko" \
    "$KMOD_DST/drivers/virtio" "virtio_ring.ko" || \
    echo "    跳过: virtio_ring.ko (可能是内建模块)"

copy_module "$KMOD_SRC/drivers/virtio/virtio_pci.ko" \
    "$KMOD_DST/drivers/virtio" "virtio_pci.ko" || \
    echo "    跳过: virtio_pci.ko (可能是内建模块)"

# 检查 virtio_net 是否找到
if [ "$VIRTIO_NET_FOUND" -eq 0 ]; then
    # 检查是否为内建模块
    KCONFIG="/boot/config-$KVER"
    if [ -f "$KCONFIG" ] && grep -q "CONFIG_VIRTIO_NET=y" "$KCONFIG"; then
        echo "  提示: virtio_net 是内建模块 (CONFIG_VIRTIO_NET=y)"
        echo "  guest init 脚本已处理 'may be built-in' 情况"
    else
        echo "错误: virtio_net.ko 未找到，且无法确认是否为内建模块"
        echo "  已检查: $KMOD_SRC/drivers/net/virtio_net.ko{,.xz,.zst}"
        if [ -f "$KCONFIG" ]; then
            echo "  内核配置: CONFIG_VIRTIO_NET=$(grep 'CONFIG_VIRTIO_NET' "$KCONFIG" 2>/dev/null || echo '未设置')"
        else
            echo "  内核配置文件不存在: $KCONFIG"
        fi
        exit 1
    fi
fi

# 生成简易 modules.dep
MODULES_DEP="$BASE_DIR/lib/modules/$KVER/modules.dep"
echo "  生成 modules.dep..."

# 收集已复制的模块，生成依赖关系
{
    # virtio_net 依赖 net_failover 和 failover
    DEPS=""
    [ -f "$KMOD_DST/net/core/failover.ko" ] && DEPS="kernel/net/core/failover.ko"
    [ -f "$KMOD_DST/drivers/net/net_failover.ko" ] && DEPS="$DEPS kernel/drivers/net/net_failover.ko"
    if [ -f "$KMOD_DST/drivers/net/virtio_net.ko" ]; then
        echo "kernel/drivers/net/virtio_net.ko: $DEPS"
    fi
    [ -f "$KMOD_DST/drivers/net/net_failover.ko" ] && \
        echo "kernel/drivers/net/net_failover.ko: $([ -f "$KMOD_DST/net/core/failover.ko" ] && echo 'kernel/net/core/failover.ko')"
    [ -f "$KMOD_DST/net/core/failover.ko" ] && echo "kernel/net/core/failover.ko:"
    [ -f "$KMOD_DST/drivers/virtio/virtio.ko" ] && echo "kernel/drivers/virtio/virtio.ko:"
    [ -f "$KMOD_DST/drivers/virtio/virtio_ring.ko" ] && echo "kernel/drivers/virtio/virtio_ring.ko: $([ -f "$KMOD_DST/drivers/virtio/virtio.ko" ] && echo 'kernel/drivers/virtio/virtio.ko')"
    [ -f "$KMOD_DST/drivers/virtio/virtio_pci.ko" ] && echo "kernel/drivers/virtio/virtio_pci.ko: $([ -f "$KMOD_DST/drivers/virtio/virtio_ring.ko" ] && echo 'kernel/drivers/virtio/virtio_ring.ko') $([ -f "$KMOD_DST/drivers/virtio/virtio.ko" ] && echo 'kernel/drivers/virtio/virtio.ko')"
} > "$MODULES_DEP"

echo "  modules.dep 已生成"

# ============================================================
# 步骤 4: 复制可选工具
# ============================================================
echo ""
echo "[4/7] 复制可选工具..."

# iperf3
if [ "${INCLUDE_IPERF3:-0}" -eq 1 ]; then
    echo "  查找 iperf3..."
    IPERF3_BIN=""
    if command -v iperf3 >/dev/null 2>&1; then
        IPERF3_SYS="$(command -v iperf3)"
        # 检查是否静态链接
        if file "$IPERF3_SYS" | grep -q "static"; then
            IPERF3_BIN="$IPERF3_SYS"
            echo "    找到静态 iperf3: $IPERF3_BIN"
        else
            # 非静态链接也先复制，可能在 guest 中依赖库已存在
            IPERF3_BIN="$IPERF3_SYS"
            echo "    找到 iperf3 (非静态): $IPERF3_BIN"
            echo "    警告: 非静态 iperf3 在 initramfs 中可能无法运行"
        fi
    fi

    if [ -n "$IPERF3_BIN" ]; then
        cp "$IPERF3_BIN" "$BASE_DIR/usr/bin/iperf3"
        chmod +x "$BASE_DIR/usr/bin/iperf3"
        echo "    iperf3 已安装到 usr/bin/iperf3"
    else
        echo "    警告: iperf3 未找到，跳过"
    fi
else
    echo "  INCLUDE_IPERF3=0，跳过 iperf3"
fi

# netcat
if [ "${INCLUDE_NETCAT:-0}" -eq 1 ]; then
    echo "  查找 netcat..."
    NC_BIN=""

    # busybox 通常自带 nc
    if "$BASE_DIR/bin/busybox" nc --help >/dev/null 2>&1; then
        echo "    BusyBox 自带 nc，创建符号链接"
        ln -sf ../bin/busybox "$BASE_DIR/usr/bin/nc"
        NC_BIN="busybox"
    fi

    # 如果 busybox nc 不可用，查找系统 nc
    if [ -z "$NC_BIN" ]; then
        if command -v nc >/dev/null 2>&1; then
            cp "$(command -v nc)" "$BASE_DIR/usr/bin/nc"
            chmod +x "$BASE_DIR/usr/bin/nc"
            echo "    系统 nc 已复制到 usr/bin/nc"
        elif command -v ncat >/dev/null 2>&1; then
            cp "$(command -v ncat)" "$BASE_DIR/usr/bin/nc"
            chmod +x "$BASE_DIR/usr/bin/nc"
            echo "    ncat 已复制为 usr/bin/nc"
        else
            echo "    警告: netcat 未找到，跳过"
        fi
    fi
else
    echo "  INCLUDE_NETCAT=0，跳过 netcat"
fi

# ============================================================
# 步骤 5: 复制 guest init 脚本
# ============================================================
echo ""
echo "[5/7] 复制 guest init 脚本..."

SCRIPTS_DIR="$SCRIPT_DIR/scripts"
INIT_SCRIPTS_DST="$BASE_DIR/scripts"
mkdir -p "$INIT_SCRIPTS_DST"

# 复制所有 guest_init 脚本
for script in "$SCRIPTS_DIR"/guest_init*.sh; do
    if [ -f "$script" ]; then
        cp "$script" "$INIT_SCRIPTS_DST/"
        chmod +x "$INIT_SCRIPTS_DST/$(basename "$script")"
        echo "    已复制: $(basename "$script")"
    fi
done

# ============================================================
# 步骤 6: 构建各变体 initramfs
# ============================================================
echo ""
echo "[6/7] 构建 initramfs 变体..."

# 变体名到 init 脚本的映射
get_init_script() {
    local variant="$1"
    case "$variant" in
        phase4) echo "guest_init_phase4.sh" ;;
        phase5) echo "guest_init_phase5.sh" ;;
        tap)    echo "guest_init_tap.sh" ;;
    esac
}

for variant in $VARIANTS; do
    echo ""
    echo "  --- 构建变体: $variant ---"

    INIT_SCRIPT="$(get_init_script "$variant")"
    VARIANT_DIR="$WORK_DIR/variant_$variant"

    # 复制 base 结构
    cp -a "$BASE_DIR" "$VARIANT_DIR"

    # 检查对应的 init 脚本是否存在
    if [ ! -f "$VARIANT_DIR/scripts/$INIT_SCRIPT" ]; then
        echo "  错误: init 脚本不存在: scripts/$INIT_SCRIPT"
        echo "  跳过变体: $variant"
        continue
    fi

    # 设置 init 符号链接 (指向 guest init 脚本)
    ln -sf "/scripts/$INIT_SCRIPT" "$VARIANT_DIR/init"
    echo "    init -> /scripts/$INIT_SCRIPT"

    # 打包为 cpio + gzip
    OUTFILE="$OUTPUT_DIR/initramfs-${variant}.gz"
    echo "    打包: $OUTFILE"

    (cd "$VARIANT_DIR" && find . | cpio -H newc -o --quiet 2>/dev/null | gzip > "$OUTFILE")

    if [ -f "$OUTFILE" ]; then
        SIZE=$(du -h "$OUTFILE" | cut -f1)
        echo "    完成: $OUTFILE ($SIZE)"
    else
        echo "    错误: 打包失败"
    fi
done

# ============================================================
# 步骤 6.5: 复制内核镜像
# ============================================================
echo ""
echo "[6.5/7] 复制内核镜像..."

VMLINUZ_SRC=""

# 检查可能的内核镜像路径
if [ -f "/boot/vmlinuz-$KVER" ]; then
    VMLINUZ_SRC="/boot/vmlinuz-$KVER"
elif [ -f "/boot/vmlinuz" ]; then
    VMLINUZ_SRC="/boot/vmlinuz"
fi

if [ -n "$VMLINUZ_SRC" ]; then
    cp "$VMLINUZ_SRC" "$OUTPUT_DIR/vmlinuz"
    echo "  已复制: $VMLINUZ_SRC -> $OUTPUT_DIR/vmlinuz"
else
    echo "  警告: 未找到内核镜像 /boot/vmlinuz-$KVER 或 /boot/vmlinuz"
    echo "  请手动复制内核镜像到 $OUTPUT_DIR/vmlinuz"
fi

# ============================================================
# 步骤 7: 验证输出
# ============================================================
echo ""
echo "[7/7] 验证输出..."
echo ""
echo "============================================================"
echo " 构建结果"
echo "============================================================"

for variant in $VARIANTS; do
    OUTFILE="$OUTPUT_DIR/initramfs-${variant}.gz"
    if [ -f "$OUTFILE" ]; then
        SIZE=$(du -h "$OUTFILE" | cut -f1)
        # 列出内容摘要
        ENTRY_COUNT=$(gzip -dc "$OUTFILE" | cpio -t --quiet 2>/dev/null | wc -l)
        echo "  [OK] initramfs-${variant}.gz  大小=$SIZE  文件数=$ENTRY_COUNT"
    else
        echo "  [失败] initramfs-${variant}.gz  未生成"
    fi
done

if [ -f "$OUTPUT_DIR/vmlinuz" ]; then
    KSIZE=$(du -h "$OUTPUT_DIR/vmlinuz" | cut -f1)
    echo "  [OK] vmlinuz  大小=$KSIZE"
else
    echo "  [缺失] vmlinuz"
fi

echo ""
echo "============================================================"
echo " 构建完成"
echo " 输出目录: $OUTPUT_DIR"
echo "============================================================"
