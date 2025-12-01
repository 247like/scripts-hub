#!/bin/bash
# MemCtl - VPS 内存智能控制器
# 功能：一键安装 ZRAM + swapfile + sysctl 优化，可检查与自动修复
# 作者：247like 专用版本（AI 定制）

set -e

ZRAM_CONF="/etc/systemd/zram-generator.conf"
SWAPFILE="/swapfile"
SYSCTL_CONF="/etc/sysctl.d/99-memctl.conf"
CHECK_SERVICE="/etc/systemd/system/memctl-check.service"
CHECK_TIMER="/etc/systemd/system/memctl-check.timer"

# 彩色输出
RED() { echo -e "\033[31m$1\033[0m"; }
GREEN() { echo -e "\033[32m$1\033[0m"; }
YELLOW() { echo -e "\033[33m$1\033[0m"; }

usage() {
    echo "MemCtl 内存控制器"
    echo "用法："
    echo "  bash memctl.sh install     # 安装内存优化（ZRAM + swap）"
    echo "  bash memctl.sh uninstall   # 卸载还原为纯物理内存"
    echo "  bash memctl.sh status      # 查看当前内存状态"
    echo "  bash memctl.sh check       # 检查是否运行正常"
    echo "  bash memctl.sh fix         # 自动修复异常"
    echo "  bash memctl.sh enable-timer # 开启自动检查"
    echo "  bash memctl.sh disable-timer # 关闭自动检查"
    exit 1
}

#############################################
# 1. 卸载（干净恢复）
#############################################
uninstall_all() {
    YELLOW "[1/5] 清理 swap..."
    swapoff -a || true
    rm -f "$SWAPFILE"
    sed -i '/\/swapfile/d' /etc/fstab

    YELLOW "[2/5] 清理 ZRAM..."
    systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
    systemctl disable systemd-zram-setup@zram0.service 2>/dev/null || true
    rm -f "$ZRAM_CONF"

    for i in /sys/class/zram/zram*; do
        echo 1 > "$i/reset" 2>/dev/null || true
    done

    YELLOW "[3/5] 清理 zramswap（兼容旧系统）..."
    systemctl stop zramswap 2>/dev/null || true
    systemctl disable zramswap 2>/dev/null || true
    rm -f /etc/default/zramswap

    YELLOW "[4/5] 删除 sysctl 优化..."
    rm -f "$SYSCTL_CONF"
    sysctl --system >/dev/null

    YELLOW "[5/5] 删除自动检查服务..."
    rm -f "$CHECK_SERVICE" "$CHECK_TIMER"
    systemctl daemon-reload

    GREEN "卸载完成（系统现为纯物理内存）。"
}


#############################################
# 2. 安装
#############################################
install_all() {
    uninstall_all

    GREEN "[1/4] 创建 2GB swapfile（pri=50）..."
    dd if=/dev/zero of=$SWAPFILE bs=1M count=2048 status=progress
    chmod 600 $SWAPFILE
    mkswap $SWAPFILE
    swapon --priority 50 $SWAPFILE

    echo "/swapfile none swap sw,pri=50 0 0" >> /etc/fstab

    GREEN "[2/4] 设置 ZRAM（8GB）..."
    mkdir -p /etc/systemd
    cat > "$ZRAM_CONF" <<EOF
[zram0]
zram-size = 8G
compression-algorithm = zstd
swap-priority = 100
EOF

    systemctl daemon-reload
    systemctl enable systemd-zram-setup@zram0.service
    systemctl start systemd-zram-setup@zram0.service

    GREEN "[3/4] 写 sysctl 优化..."
    cat > "$SYSCTL_CONF" <<EOF
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOF
    sysctl --system >/dev/null

    GREEN "[4/4] 安装完成"
    status_all
}


#############################################
# 3. 显示状态
#############################################
status_all() {
    echo "===== 内存状态 ====="
    free -h

    echo -e "\n===== SWAP 状态 ====="
    swapon --show

    echo -e "\n===== ZRAM 状态 ====="
    lsblk | grep zram || echo "无 ZRAM"

    echo -e "\n===== sysctl 参数 ====="
    sysctl vm.swappiness vm.vfs_cache_pressure vm.dirty_ratio vm.dirty_background_ratio
}


#############################################
# 4. 自检 check()
#############################################
check_all() {
    local ERR=0

    echo "=== MemCtl 自检 ==="

    #############################
    # 1. 检查 ZRAM
    #############################
    if ! grep -q zram0 /proc/swaps; then
        RED "❌ ZRAM 未加载"
        ERR=1
    else
        GREEN "✔ ZRAM 正常运行"
    fi

    #############################
    # 2. 检查 swapfile 是否启用
    #############################
    if ! grep -q "$SWAPFILE" /proc/swaps; then
        RED "❌ swapfile 未启用"
        ERR=1
    else
        GREEN "✔ swapfile 正常启用"
    fi

    #############################
    # 3. 检查 swapfile 是否大小正确（必须为 2GB）
    #############################
    if [ -f "$SWAPFILE" ]; then
        SIZE=$(stat -c%s "$SWAPFILE")
        if [ "$SIZE" -lt 2147000000 ] || [ "$SIZE" -gt 2149000000 ]; then
            RED "❌ swapfile 大小异常（不是 2GB）"
            ERR=1
        else
            GREEN "✔ swapfile 大小正确（2GB）"
        fi
    else
        RED "❌ swapfile 文件不存在"
        ERR=1
    fi

    #############################
    # 4. 检查 swap 优先级是否正常
    #############################
    if grep -q "$SWAPFILE" /proc/swaps; then
        PRI=$(grep "$SWAPFILE" /proc/swaps | awk '{print $5}')
        if [ "$PRI" -ne 50 ]; then
            RED "❌ swapfile 优先级错误（应为 50，当前 $PRI）"
            ERR=1
        else
            GREEN "✔ swapfile 优先级正确（50）"
        fi
    fi

    #############################
    # 5. 检查 fstab 持久化
    #############################
    if grep -q "/swapfile" /etc/fstab; then
        GREEN "✔ swapfile 已加入 fstab（会随重启自动加载）"
    else
        RED "❌ swapfile 未写入 /etc/fstab（重启后会丢失）"
        ERR=1
    fi

    #############################
    # 6. sysctl 参数检查
    #############################
    if [ ! -f "$SYSCTL_CONF" ]; then
        RED "❌ sysctl 优化文件缺失"
        ERR=1
    else
        GREEN "✔ sysctl 配置存在"
    fi

    #############################
    # 最终结果
    #############################
    if [ $ERR -eq 0 ]; then
        GREEN "🎉 内存系统状态正常（ZRAM + swapfile + sysctl 全部正常）"
        exit 0
    else
        RED "⚠ 发现问题，请执行： bash memctl.sh fix"
        exit 1
    fi
}



#############################################
# 5. 自动修复 fix()
#############################################
fix_all() {
    RED "开始修复..."

    uninstall_all
    install_all

    GREEN "修复完成！"
}


#############################################
# 6. systemd 自动检查
#############################################
enable_timer() {
    YELLOW "创建 memctl-check systemd 服务..."

    cat > "$CHECK_SERVICE" <<EOF
[Unit]
Description=MemCtl Memory Health Check

[Service]
Type=oneshot
ExecStart=/usr/local/bin/memctl.sh check
EOF

    cat > "$CHECK_TIMER" <<EOF
[Unit]
Description=Every 30 minutes check memory health

[Timer]
OnBootSec=5m
OnUnitActiveSec=30m
Unit=memctl-check.service

[Install]
WantedBy=timers.target
EOF

    chmod +x /usr/local/bin/memctl.sh

    systemctl daemon-reload
    systemctl enable memctl-check.timer
    systemctl start memctl-check.timer

    GREEN "已启用自动检查（每 30 分钟执行一次）"
}

disable_timer() {
    systemctl stop memctl-check.timer 2>/dev/null || true
    systemctl disable memctl-check.timer 2>/dev/null || true
    rm -f "$CHECK_SERVICE" "$CHECK_TIMER"
    systemctl daemon-reload
    GREEN "已禁用自动检查服务。"
}


#############################################
# 主入口
#############################################
case "$1" in
    install) install_all ;;
    uninstall) uninstall_all ;;
    status) status_all ;;
    check) check_all ;;
    fix) fix_all ;;
    enable-timer) enable_timer ;;
    disable-timer) disable_timer ;;
    *) usage ;;
esac
