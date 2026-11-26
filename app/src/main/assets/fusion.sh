#!/system/bin/sh
# fusion.sh —— 屏幕触摸转发（app 内嵌版，双实现可选）
#
# 跑模块官方 Go 二进制（绝对坐标、位置准；固定独占触摸）
#
# 脚本统一负责：探测网卡/板子 IP、健康探测、落地二进制、root 拉起与监督、状态写盘。
#
# 用法（app 以 root 执行）：
#   VF_MASTER=<官方二进制副本> [VF_SCREEN_W=1260 VF_SCREEN_H=2800] sh fusion.sh start|stop|status

VF_DIR=/data/local/tmp/vfusion
LOG=$VF_DIR/fusion.log
STATE=$VF_DIR/state
PIDF=$VF_DIR/daemon.pid

TF_NAME=touch_forwarder_arm64
TF_BIN=/data/local/tmp/$TF_NAME
TF_LOG=/data/local/touch_forwarder.log
TFNG_LOG=/data/local/tmp/touch_forwarder.log
PORT=${VF_PORT:-6532}
BOARD_SUFFIX=${VF_BOARD_SUFFIX:-1}


mkdir -p "$VF_DIR" 2>/dev/null

# 设备分辨率：app 传入优先（VF_SCREEN_W/H），否则自己读 wm size（Override 优先于 Physical）
detect_screen() {
    if [ -n "${VF_SCREEN_W:-}" ] && [ -n "${VF_SCREEN_H:-}" ]; then
        SCREEN_W=$VF_SCREEN_W; SCREEN_H=$VF_SCREEN_H; SCREEN_SRC=app
        return 0
    fi
    line=$(wm size 2>/dev/null | awk '/Override size/{o=$3} /Physical size/{p=$3} END{print (o!=""?o:p)}')
    [ -n "$line" ] || return 1
    SCREEN_W=${line%x*}
    SCREEN_H=${line#*x}
    SCREEN_SRC=wm
    return 0
}
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

# 必须按接口名绑（SO_BINDTODEVICE）；按源 IP 绑会被策略路由发去 wlan0
probe_board() {
    code=$(curl -s -m 3 --interface "$IFACE" -o /dev/null -w '%{http_code}' "http://$BOARD/" 2>/dev/null)
    [ "$code" = "200" ]
}

has_link() { netstat -tn 2>/dev/null | grep ":$PORT " | grep -q ESTABLISHED; }

# BUG 修复：清理孤儿 getevent（读已删除节点会 100% CPU 空转）
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
    log "官方二进制已落地 $TF_BIN ($(wc -c < "$TF_BIN") 字节)"
    return 0
}

tf_pid()   { pgrep -f "$TF_BIN" 2>/dev/null | head -1; }

# BUG 修复：daemon.pid 可能是陈旧 pid（pid 复用），要校验 cmdline
pid_alive() {
    [ -f "$PIDF" ] || return 1
    p=$(cat "$PIDF" 2>/dev/null)
    [ -n "$p" ] && [ -d "/proc/$p" ] || return 1
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'fusion\.sh' || return 1
    return 0
}

do_start() {
    if pid_alive; then
        echo "already: pid=$(cat "$PIDF")"
        return 0
    fi
    rm -f "$PIDF"

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

    if detect_screen; then
        echo "${SCREEN_W}x${SCREEN_H}" > "$VF_DIR/screen" 2>/dev/null
        log "设备分辨率：${SCREEN_W}x${SCREEN_H}（来源 $SCREEN_SRC）"
    else
        log "设备分辨率：读取失败（不影响转发，二进制按触摸量程自适应）"
    fi

    install_bin || { echo "error: 官方二进制落地失败"; echo ERROR > "$STATE"; return 1; }
    log "=== start: iface=$IFACE ip=$IP board=$BOARD port=$PORT ==="

    echo STARTING > "$STATE"
    nohup sh "$0" run >> "$LOG" 2>&1 &
    echo $! > "$PIDF"
    echo "started: pid=$(cat "$PIDF") board=$BOARD"
}

run_loop() {
    log "守护启动"
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
    p=$(tf_pid); [ -n "$p" ] && kill -9 "$p" 2>/dev/null
    pkill -f '[f]usion.sh run' 2>/dev/null
    rm -f "$PIDF"
    echo STOPPED > "$STATE"
    log "=== stop ==="
    echo "stopped"
}

do_status() {
    st=$(cat "$STATE" 2>/dev/null)
    alive=no; pid_alive && alive=yes
    echo "state=${st:-unknown} daemon=$alive tf=$(tf_pid) port=$PORT board=$(cat "$VF_DIR/board" 2>/dev/null)"
    link=$(netstat -tn 2>/dev/null | grep ":$PORT " | grep ESTABLISHED | head -1)
    [ -n "$link" ] && echo "link: $(echo "$link" | awk '{print $5}') <- 板子"
    tail -n 5 "$LOG" 2>/dev/null | sed 's/^/  /'
}

case "$1" in
    start)  do_start ;;
    stop)   do_stop ;;
    status) do_status ;;
    run)    run_loop ;;
    *)      echo "usage: VF_MASTER=<bin> $0 start|stop|status" ;;
esac
