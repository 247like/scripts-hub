#!/bin/bash
set -e

ZRAM_CONF="/etc/systemd/zram-generator.conf"
SWAPFILE="/swapfile"

RED() { echo -e "\033[31m$1\033[0m"; }
GREEN() { echo -e "\033[32m$1\033[0m"; }
YELLOW() { echo -e "\033[33m$1\033[0m"; }

usage() {
    echo "memctl.sh 使用方法："
    echo "  bash memctl.sh install   # 安装 ZRAM + swapfile + 优化"
    echo "  bash memctl.sh uninstall # 卸载并还原为纯物理内存"
    echo "  bash memctl.sh status    # 查看状态"
    exit 1
}


#############################################
# 功能 1：卸载所有 ZRAM、swapfile、配置
#############################################
uninstall_all() {
    YELLOW "[1/4] 清理 swap..."

    swapoff -a || true
    [ -f "$SWAPFILE" ] && rm -f "$SWAPFILE"

    sed -i '/\/swapfile/d' /etc/fstab

    YELLOW "[2/4] 清理 zram-generator..."

    systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
    systemctl disable systemd-zram-setup@zram0.service 2>/dev/null || true

    rm -f "$ZRAM_CONF"

    YELLOW "[3/4] 清理 zramswap（如存在）..."
    systemctl stop zramswap 2>/dev/null || true
    systemctl disable zramswap 2>/dev/null || true
    rm -f /etc/default/zramswap

    YELLOW "[4/4] 还原 sysctl 参数..."
    rm -f /etc/sysctl.d/99-memctl.conf
    sysctl --system > /dev/null

    GREEN "卸载完成（系统现在只使用物理内存）。"
}


#############################################
# 功能 2：安装优化方案
#############################################
install_all() {
    uninstall_all   # 安装前先清理，确保幂等

    GREEN "[1/4] 创建 2GB swapfile（pri=50）..."
    dd if=/dev/zero of=$SWAPFILE bs=1M count=2048 status=progress
    chmod 600 $SWAPFILE
    mkswap $SWAPFILE
    swapon --priority 50 $SWAPFILE

    echo "/swapfile none swap sw,pri=50 0 0" >> /etc/fstab

    GREEN "[2/4] 配置 8G 单片 ZRAM（zstd, pri=100）..."
    cat > $ZRAM_CONF <<EOF
[zram0]
zram-size = 8G
compression-algorithm = zstd
swap-priority = 100
EOF

    systemctl daemon-reload
    systemctl enable systemd-zram-setup@zram0.service
    systemctl start systemd-zram-setup@zram0.service

    GREEN "[3/4] 写入安全稳定的 sysctl 优化..."
    cat > /etc/sysctl.d/99-memctl.conf <<EOF
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOF
    sysctl --system >/dev/null

    GREEN "[4/4] 完成。当前状态："
    swapon --show
}


#############################################
# 功能 3：状态显示
#############################################
status_all() {
    echo "---- SWAP 状态 ----"
    swapon --show

    echo -e "\n---- ZRAM 状态 ----"
    lsblk | grep zram || echo "无 zram 设备"

    echo -e "\n---- sysctl ----"
    sysctl vm.swappiness vm.vfs_cache_pressure vm.dirty_ratio vm.dirty_background_ratio
}


#############################################
# 主入口
#############################################
case "$1" in
    install)
        install_all
        ;;
    uninstall)
        uninstall_all
        ;;
    status)
        status_all
        ;;
    *)
        usage
        ;;
esac
