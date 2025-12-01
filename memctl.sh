#!/bin/bash
set -e

ACTION="$1"

log() { echo -e "\033[36m[MemCtl]\033[0m $1"; }

CPU_CORES=$(nproc)
TOTAL_RAM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)

###########################################
# Install 内存优化
###########################################
install_mem() {
    log "开始安装：ZRAM + 2GB swapfile + sysctl 优化"

    # ---- 1. swapfile 2GB
    SWAPFILE="/swapfile"

    if [ ! -f $SWAPFILE ]; then
        log "创建 2GB swapfile..."
        dd if=/dev/zero of=$SWAPFILE bs=1G count=2 status=progress
        chmod 600 $SWAPFILE
        mkswap $SWAPFILE
        echo "/swapfile none swap sw,pri=50 0 0" >> /etc/fstab
    fi

    log "启用 swapfile pri=50"
    swapon --priority 50 $SWAPFILE || true

    # ---- 2. ZRAM 多分片（总内存的 50%）
    ZRAM_TOTAL=$(( TOTAL_RAM_GB / 2 ))
    [ "$ZRAM_TOTAL" -lt 1 ] && ZRAM_TOTAL=1

    PER=$(( ZRAM_TOTAL / 4 ))
    [ "$PER" -lt 1 ] && PER=1

    log "配置 ZRAM：总 ${ZRAM_TOTAL}G，每片 ${PER}G"

    cat >/etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ${PER}G
compression-algorithm = zstd
swap-priority = 100
[zram1]
zram-size = ${PER}G
compression-algorithm = zstd
swap-priority = 100
[zram2]
zram-size = ${PER}G
compression-algorithm = zstd
swap-priority = 100
[zram3]
zram-size = ${PER}G
compression-algorithm = zstd
swap-priority = 100
EOF

    systemctl daemon-reload
    for i in 0 1 2 3; do
        systemctl restart systemd-zram-setup@zram$i.service || true
    done

    # ---- 3. sysctl
    log "写入 sysctl 优化参数"
    cat >/etc/sysctl.d/99-memctl.conf <<EOF
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOF
    sysctl --system

    # ---- 4. systemd 定时检查
    log "创建定时检查任务"

cat >/etc/systemd/system/memctl-check.service <<EOF
[Unit]
Description=MemCtl Memory Auto Check

[Service]
Type=oneshot
ExecStart=/usr/bin/bash /usr/local/bin/memctl.sh check
EOF

cat >/etc/systemd/system/memctl-check.timer <<EOF
[Unit]
Description=Run MemCtl Check Every 10 Minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now memctl-check.timer

    # ---- 5. 主脚本自身复制到系统目录
    cp -f "$0" /usr/local/bin/memctl.sh
    chmod +x /usr/local/bin/memctl.sh

    log "安装完成！"
    swapon --show
}

###########################################
# Uninstall 卸载所有 ZRAM/SWAP
###########################################
uninstall_mem() {
    log "卸载：恢复纯物理内存"

    # ---- 停止 timer
    systemctl disable --now memctl-check.timer 2>/dev/null || true
    rm -f /etc/systemd/system/memctl-check.service
    rm -f /etc/systemd/system/memctl-check.timer

    # ---- swapfile
    swapoff -a || true
    sed -i '\|/swapfile|d' /etc/fstab
    rm -f /swapfile || true

    # ---- ZRAM
    rm -f /etc/systemd/zram-generator.conf
    for dev in /dev/zram*; do
        swapoff $dev 2>/dev/null || true
        echo 1 > /sys/block/$(basename $dev)/reset 2>/dev/null || true
    done

    # ---- sysctl
    rm -f /etc/sysctl.d/99-memctl.conf
    sysctl --system || true

    log "卸载完成！"
}

###########################################
# Check 自动检查
###########################################
check_mem() {
    log "执行内存系统检查..."

    # ---- 禁止系统 swap 分区被意外开启
    if swapon --show | grep -q "partition"; then
        log "⚠ 检测到系统 swap 分区，已关闭"
        swapoff -a || true
    fi

    # ---- ZRAM 状态检查
    for i in 0 1 2 3; do
        if ! swapon --show | grep -q "zram$i"; then
            log "⚠ zram$i 未启用，自动重启"
            systemctl restart systemd-zram-setup@zram$i.service || true
        fi
    done

    log "检查完成"
}

###########################################
# 主控制逻辑
###########################################
case "$ACTION" in
    install|"")
        install_mem ;;
    uninstall)
        uninstall_mem ;;
    check)
        check_mem ;;
    *)
        echo "用法：bash memctl.sh [install|uninstall|check]"
        exit 1 ;;
esac
