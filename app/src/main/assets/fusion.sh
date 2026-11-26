#!/system/bin/sh
# fusion.sh —— 屏幕触摸转发（app 内嵌版，直接跑模块官方 Go 二进制）
#
# 不安装 Magisk 模块：脚本负责探测网卡/板子 IP、健康探测、把二进制落地到 /data/local/tmp、
# 用 root 拉起并监督它（退出就重拉），并把状态写盘给 UI。
#
# 二进制自带能力（已实测）：
#   - 自己 listen 6532，板子连入后读 CFG1 并毫秒级回订阅帧 55 AA 03 FC F7 01
#   - 等所有手指抬起后 EVIOCGRAB 独占触摸屏
#   - 发 14 字节**绝对坐标**帧：55 AA 0B FF action id x:i32 y:i32（0..0x7FFFFFFE）
#   - 断线自动 ungrab 并继续等重连
#
# 用法（app 以 root 执行）：
#   VF_MASTER=<app 内副本路径> sh fusion.sh start|stop|status

VF_DIR=/data/local/tmp/vfusion
LOG=$VF_DIR/fusion.log
STATE=$VF_DIR/state
PIDF=$VF_DIR/daemon.pid

TF_NAME=touch_forwarder_arm64
TF_BIN=/data/local/tmp/$TF_NAME
TF_LOG=/data/local/tmp/touch_forwarder.log
PORT=${VF_PORT:-6532}
BOARD_SUFFIX=${VF_BOARD_SUFFIX:-1}

mkdir -p "$VF_DIR" 2>/dev/null
log() { echo "[fusion] $(date '+%F %T') $*" >> "$LOG"; }

detect() {
    line=$(ip -o -4 addr 2>/dev/null | awk '$4 ~ /^192\.168\.73\./' | head -1)
    [ -n "$line" ] || line=$(ip -o -4 addr 2>/dev/null | awk '$4 !~ /^127\./ && $4 !~ /^192\.168\.168\./' | head -1)
    [ -n "$line" ] || return 1
    IFACE=$(echo "$line" | awk '{print $2}')
    CIDR=$(echo "$line" | awk '{print $4}')
    IP=${CIDR%/*}
    NET=$(echo "$IP" | awk -F. '{print $1"."$2"."$3}')
    BOARD=${VF_BOARD_IP:-$NET.$BOARD_SUFFIX}
    echo "$BOARD" > "$VF_DIR/board" 2>/dev/null
    return 0
}

# 必须按接口名绑（SO_BINDTODEVICE）；按源 IP 绑会被 Android 策略路由发去 wlan0
probe_board() {
    code=$(curl -s -m 3 --interface "$IFACE" -o /dev/null -w '%{http_code}' "http://$BOARD/" 2>/dev/null)
    [ "$code" = "200" ]
}

has_link() { netstat -tn 2>/dev/null | grep ":$PORT " | grep -q ESTABLISHED; }

# 清理孤儿 getevent（读已删除节点会 100% CPU 空转）
cleanup_orphan_getevent() {
    for p in $(pgrep -f 'getevent' 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
        case "$cmd" in *getevent*) ;; *) continue ;; esac
        case "$cmd" in *-pl*) continue ;; esac
        case "$cmd" in
            *" -l"*|*" -lt"*) kill -9 "$p" 2>/dev/null && log "清理孤儿 getevent: pid=$p" ;;
        esac
    done
}

install_bin() {
    MASTER=${VF_MASTER:-}
    [ -n "$MASTER" ] && [ -f "$MASTER" ] || { log "master 缺失: ${MASTER:-未传入}"; return 1; }
    cp -f "$MASTER" "$TF_BIN" || return 1
    chmod 755 "$TF_BIN" || return 1
    chcon u:object_r:system_file:s0 "$TF_BIN" 2>/dev/null
    log "二进制已落地 $TF_BIN ($(wc -c < "$TF_BIN") 字节)"
    return 0
}

tf_pid() { pgrep -f "$TF_BIN" 2>/dev/null | head -1; }

do_start() {
    if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
        echo "already: pid=$(cat "$PIDF")"
        return 0
    fi

    cleanup_orphan_getevent

    n=0
    until detect; do
        n=$((n + 1))
        if [ "$n" -ge 30 ]; then
            echo "error: 30 秒内没等到网卡（板子插了吗）"
            echo ERROR > "$STATE"
            return 1
        fi
        [ "$n" -eq 1 ] && { echo "waiting: 等网卡 …"; echo WAITING > "$STATE"; }
        sleep 1
    done

    if ! probe_board; then
        echo "error: 板子 TCP:80 无响应 → 请给板子断电复位后再试"
        echo BOARD_DOWN > "$STATE"
        log "健康探测失败：$BOARD :80 无响应，拒绝启动"
        return 1
    fi
    log "健康探测通过：$BOARD :80 = 200"

    install_bin || { echo "error: 二进制落地失败"; echo ERROR > "$STATE"; return 1; }

    log "=== start: iface=$IFACE ip=$IP board=$BOARD port=$PORT ==="
    echo STARTING > "$STATE"
    rm -f "$PIDF"
    nohup sh "$0" run >> "$LOG" 2>&1 &
    echo $! > "$PIDF"
    echo "started: pid=$(cat "$PIDF") board=$BOARD bin=$TF_BIN"
}

run_loop() {
    log "守护启动（监督 $TF_BIN）"
    while :; do
        if [ -z "$(tf_pid)" ]; then
            "$TF_BIN" start >> "$LOG" 2>&1
            log "已下发 start（pid=$(tf_pid)）"
        fi
        if has_link; then
            [ "$(cat "$STATE" 2>/dev/null)" = "UP" ] || echo UP > "$STATE"
        else
            [ "$(cat "$STATE" 2>/dev/null)" = "UP" ] && echo FALLBACK > "$STATE"
        fi
        sleep 3
    done
}

do_stop() {
    [ -x "$TF_BIN" ] && "$TF_BIN" stop >/dev/null 2>&1
    sleep 1
    pid=$(tf_pid)
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
    pkill -f '[f]usion.sh run' 2>/dev/null
    rm -f "$PIDF"
    echo STOPPED > "$STATE"
    log "=== stop ==="
    echo "stopped"
}

do_status() {
    st=$(cat "$STATE" 2>/dev/null)
    pid=$(cat "$PIDF" 2>/dev/null)
    alive=no
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=yes
    tpid=$(tf_pid)
    link=$(netstat -tn 2>/dev/null | grep ":$PORT " | grep ESTABLISHED | head -1)
    echo "state=${st:-unknown} daemon=$alive tf=${tpid:-none} port=$PORT board=$(cat "$VF_DIR/board" 2>/dev/null)"
    [ -n "$link" ] && echo "link: $(echo "$link" | awk '{print $5}') <- 板子"
    [ -x "$TF_BIN" ] && echo "bin: $TF_BIN ($(wc -c < "$TF_BIN" 2>/dev/null) 字节)"
    tail -n 5 "$TF_LOG" 2>/dev/null | sed 's/^/  [tf] /'
}

case "$1" in
    start)  do_start ;;
    stop)   do_stop ;;
    status) do_status ;;
    run)    run_loop ;;
    *)      echo "usage: VF_MASTER=<bin> $0 start|stop|status" ;;
esac
