#!/system/bin/sh
# fusion.sh —— 屏幕触摸转发（app 内嵌版，等价 touch_forwarder Magisk 模块）
#
# 用法（由 app 以 root 动态执行）:
#   sh fusion.sh start     # 探测网卡/板子 IP/触摸设备 → 起守护
#   sh fusion.sh stop      # 停止并释放触摸
#   sh fusion.sh status    # 打印状态
#
# 与模块的对应：
#   service.sh 铺配置/等网卡 → detect() / do_start()
#   touch_forwarder_arm64    → libtouchgrabfwd.so（随 APK 打包，root 运行）
#                              它自己 listen 6532 / 读 CFG1 / 回 ACK / grab / 出帧
#   guard.sh 的看护          → run_loop()（helper 退出就重拉）；状态由 helper 自己写
#
# 为什么监听不放 shell：握手是毫秒级的（连上→推 1264 字节配置→等回应），
# 用 nc + 每秒轮询 netstat 回 ACK 来不及，板子会"连上就断"，形成每秒一次的重连风暴。

VF_DIR=/data/local/tmp/vfusion
LOG=$VF_DIR/fusion.log
STATE=$VF_DIR/state
PIDF=$VF_DIR/daemon.pid
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

find_touch() {
    getevent -pl 2>/dev/null | awk '
        function flush() {
            if (path == "") return 0
            good = (mx >= 200 && mx <= 20000 && my >= 200 && my <= 40000) &&
                   (name ~ /touch|synaptics|goodix|focaltech|panel|tp_/ || direct)
            if (good && !done) { print path, mx, my; done = 1 }
            return good
        }
        /^add device/ {
            if (flush()) exit
            path = $4; sub(":", "", path)
            mx = 0; my = 0; name = ""; direct = 0
            next
        }
        /^  name:/ {
            name = $0
            sub(/^  name:[ \t]*"?/, "", name)
            sub(/"?[ \t]*$/, "", name)
            next
        }
        /ABS_MT_POSITION_X/ { if (match($0, /max [0-9]+/)) mx = substr($0, RSTART + 4, RLENGTH - 4) + 0 }
        /ABS_MT_POSITION_Y/ { if (match($0, /max [0-9]+/)) my = substr($0, RSTART + 4, RLENGTH - 4) + 0 }
        /INPUT_PROP_DIRECT/ { direct = 1 }
        END { flush() }
    ' | head -1
}

find_helper() {
    if [ -n "$VF_HELPER" ] && [ -x "$VF_HELPER" ]; then echo "$VF_HELPER"; return 0; fi
    h=$(ls /data/app/*/com.gtm.vpointer*/lib/arm64/libtouchgrabfwd.so 2>/dev/null | head -1)
    [ -x "$h" ] && echo "$h"
}

has_link() { netstat -tn 2>/dev/null | grep ":$PORT " | grep -q ESTABLISHED; }

# 健康探测：板子 :80 是否还能建连。
# 必须按 **接口名** 绑（--interface eth0 = SO_BINDTODEVICE）：
#   Android 策略路由下 ip route get 192.168.73.1 会命中 wlan0 表的默认路由
#   （via 192.168.168.1 dev wlan0），按源 IP 绑定不改变选表，SYN 根本出不了 eth0。
probe_board() {
    code=$(curl -s -m 3 --interface "$IFACE" -o /dev/null -w '%{http_code}' "http://$BOARD/" 2>/dev/null)
    [ "$code" = "200" ]
}

# 清理孤儿 getevent 读循环：历史版本（Kotlin 服务跑 su -c "getevent -lt <dev>"）留下的进程，
# 设备节点被删除后（拔插/重枚举）read 立即返回，getevent 会死循环空转 100% CPU（实测 86% 内核态）。
# 只杀长跑读取器（带 -l），不碰一次性的 getevent -pl。
cleanup_orphan_getevent() {
    for p in $(pgrep -f 'getevent' 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
        case "$cmd" in
            *getevent*) ;;
            *) continue ;;
        esac
        case "$cmd" in
            *-pl*) continue ;;
        esac
        case "$cmd" in
            *" -l"*|*" -lt"*)
                kill -9 "$p" 2>/dev/null && log "清理孤儿 getevent: pid=$p"
                ;;
        esac
    done
}

do_start() {
    cleanup_orphan_getevent
    if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
        echo "already: pid=$(cat "$PIDF")"; return 0
    fi
    n=0
    until detect; do
        n=$((n + 1))
        if [ "$n" -ge 30 ]; then
            echo "error: 30 秒内没等到网卡（板子插了吗）"; echo ERROR > "$STATE"; return 1
        fi
        [ "$n" -eq 1 ] && { echo "waiting: 等网卡 …"; echo WAITING > "$STATE"; }
        sleep 1
    done

    if ! probe_board; then
        echo "error: 板子 TCP:80 无响应（PCB 可能已被打满）→ 请给板子断电复位后再试"
        echo BOARD_DOWN > "$STATE"
        log "健康探测失败：$BOARD :80 无响应，拒绝启动（避免继续占 PCB）"
        return 1
    fi
    log "健康探测通过：$BOARD :80 = 200"

    touchinfo=$(find_touch)
    [ -n "$touchinfo" ] || { echo "error: 没找到触摸屏"; echo ERROR > "$STATE"; return 1; }
    DEV=$(echo "$touchinfo" | awk '{print $1}')
    MAXX=$(echo "$touchinfo" | awk '{print $2}')
    MAXY=$(echo "$touchinfo" | awk '{print $3}')

    helper=$(find_helper)
    [ -x "$helper" ] || { echo "error: 找不到 libtouchgrabfwd.so"; echo ERROR > "$STATE"; return 1; }

    log "=== start: iface=$IFACE ip=$IP board=$BOARD dev=$DEV ${MAXX}x${MAXY} port=$PORT ==="
    echo STARTING > "$STATE"
    nohup sh "$0" run "$DEV" "$MAXX" "$MAXY" "$helper" >> "$LOG" 2>&1 &
    echo $! > "$PIDF"
    echo "started: pid=$(cat "$PIDF") board=$BOARD dev=$DEV"
}

do_stop() {
    [ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null
    rm -f "$PIDF"
    pkill -x libtouchgrabfwd 2>/dev/null
    pkill -f '[f]usion.sh run' 2>/dev/null
    echo STOPPED > "$STATE"
    log "=== stop ==="
    echo "stopped"
}

do_status() {
    st=$(cat "$STATE" 2>/dev/null)
    pid=$(cat "$PIDF" 2>/dev/null)
    alive=no
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=yes
    hl=$([ -n "$(pgrep -f '[l]ibtouchgrabfwd' 2>/dev/null)" ] && echo yes || echo no)
    link=$(netstat -tn 2>/dev/null | grep ":$PORT " | grep ESTABLISHED | head -1)
    echo "state=${st:-unknown} daemon=$alive helper=$hl port=$PORT board=$(cat "$VF_DIR/board" 2>/dev/null)"
    [ -n "$link" ] && echo "link: $(echo "$link" | awk '{print $5}') <- 板子"
    tail -n 6 "$LOG" 2>/dev/null | sed 's/^/  /'
}

run_loop() {
    DEV=$1; MAXX=$2; MAXY=$3; HELPER=$4
    log "守护启动：dev=$DEV ${MAXX}x${MAXY} port=$PORT"
    while :; do
        VF_STATE_FILE="$STATE" VF_GRAB="${VF_GRAB:-1}" "$HELPER" "$DEV" "$MAXX" "$MAXY" "$PORT" >> "$LOG" 2>&1
        rc=$?
        echo FALLBACK > "$STATE"        # helper 任何方式退出（正常/被杀/崩溃）都把状态落成 FALLBACK
        log "helper 退出 rc=$rc，2s 后重启"
        sleep 2
    done
}
case "$1" in
    start)  do_start ;;
    stop)   do_stop ;;
    status) do_status ;;
    run)    shift; run_loop "$@" ;;
    *)      echo "usage: $0 start|stop|status" ;;
esac