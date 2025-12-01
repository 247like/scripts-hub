#!/bin/bash
set -e

ZRAM_CONF="/etc/systemd/zram-generator.conf"
SYSCTL_CONF="/etc/sysctl.d/99-memctl.conf"
SWAPFILE="/swapfile"

###########################################################
# 完整清理（install/uninstall 前必须调用）
###########################################################
cleanup_all() {
    echo "[MemCtl] 清理旧 swap / zram / zramswap / 配置..."

    # 1. 停所有 zram swap
    for dev in /dev/zram*; do
        [ -e "$dev" ] || continue
        echo "[MemCtl] swapoff $dev"
        swapoff "$dev" 2>/dev/null || true
    done

    # 2. 停 systemd zram 服务
    for svc in $(systemctl list-units --all 'systemd-zram-setup@*' --no-legend | awk '{print $1}'); do
        echo "[MemCtl] 停止并禁用 $svc"
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done

    # 3. 删除 zramswap（旧系统组件）
    if systemctl status zramswap.service >/dev/null 2>&1; then
        echo "[MemCtl] 禁用 zramswap"
        systemctl stop zramswap || true
        systemctl disable zramswap || true
    fi

    # 4. 删除 zram-generator 配置
    if [ -f "$ZRAM_CONF" ]; then
        echo "[MemCtl] 删除 $ZRAM_CONF"
        rm -f "$ZRAM_CONF"
    fi

    # 5. 删除 memctl sysctl
    if [ -f "$SYSCTL_CONF" ]; then
        echo "[MemCtl] 删除 sysctl 配置"
        rm -f "$SYSCTL_CONF"
    fi

    # 6. 删除 swapfile
    if [ -f "$SWAPFILE" ]; then
        echo "[MemCtl] 删除 swapfile"
        swapoff "$SWAPFILE" 2>/dev/null || true
        rm -f "$SWAPFILE"
    fi

    # 7. fstab 清理 swapfile
    sed -i '/\/swapfile/d' /etc/fstab

    echo "[MemCtl] systemd reload"
    systemctl daemon-reload || true

    echo "[MemCtl] sysctl reload"
    sysctl --system >/dev/null 2>&1 || true

    echo "[MemCtl] 清理完成"
}

###########################################################
# 安装：8G ZRAM + 2G swapfile
###########################################################
do_install() {
    echo "[MemCtl] 开始安装：ZRAM + 2GB swapfile + sysctl 优化"

    cleanup_all

    ###########################################################
    # 1. 创建 2G swapfile
    ###########################################################
    echo "[MemCtl] 创建 2GB swapfile..."
    dd if=/dev/zero of=$SWAPFILE bs=1G count=2 status=progress
    chmod 600 $SWAPFILE
    mkswap $SWAPFILE
    swapon --priority 50 $SWAPFILE

    ###########################################################
    # 2. 配置 ZRAM（8GB）
    ###########################################################
    echo "[MemCtl] 配置 ZRAM（8G）"

    cat >"$ZRAM_CONF" <<EOF
[zram0]
zram-size = 8G
compression-algorithm = zstd
swap-priority = 100
EOF

    systemctl daemon-reload
    systemctl restart systemd-zram-setup@zram0.service

    ###########################################################
    # 3. sysctl 优化
    ###########################################################
    echo "[MemCtl] 写入 sysctl"

    cat >"$SYSCTL_CONF" <<EOF
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOF

    sysctl --system

    echo ""
    echo "[MemCtl] 安装完成"
    swapon --show
}

###########################################################
# 卸载：恢复只有物理内存
###########################################################
do_uninstall() {
    echo "[MemCtl] 卸载：恢复到纯物理内存"
    cleanup_all

    echo "[MemCtl] 卸载完成，当前 swap 状态："
    swapon --show || true
}

###########################################################
# 主入口
###########################################################
case "$1" in
    install)
        do_install
        ;;
    uninstall)
        do_uninstall
        ;;
    cleanup)
        cleanup_all
        ;;
    *)
        echo "使用方法:"
        echo "  bash memctl.sh install     # 安装"
        echo "  bash memctl.sh uninstall   # 卸载"
        echo "  bash memctl.sh cleanup     # 仅清理"
        exit 1
        ;;
esac
