// touch_fwd_main.cpp —— 屏幕触摸转发（等价 touch_forwarder 模块的二进制）
//
// 以 root 运行，自己当服务器：
//   listen 6532 → 板子连入 → 读 CFG1 配置帧 → **立刻**回 6 字节确认
//   → 等所有手指抬起 → EVIOCGRAB 独占触摸屏 → 持续发 14 字节触摸帧
//   → 板子断开/写失败 → ungrab + close，回到 accept
//
// 为什么必须在 native 里做监听：握手是毫秒级的。用 shell（nc + 每秒轮询 netstat）
// 根本来不及回 ACK，板子会"连上→推配置→等不到回应→断开重连"，形成每秒一次的重连风暴。
//
// 帧格式（v1.8 抓包实证）：
//   板子 → 手机: "CFG1" + u32 长度 + 载荷
//   手机 → 板子: 55 AA 03 FC F7 01（确认）
//                55 AA 0B FF | phase | 02 | X u32 LE | Y u32 LE（phase 1/2/3 = 下/移/抬）

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <signal.h>
#include <unistd.h>

#include <cstdint>

namespace {

constexpr int kMaxSlots = 10;
constexpr uint32_t kNormMax = 0x7FFFFFFEUL;
constexpr int kPhaseDown = 1;
constexpr int kPhaseMove = 2;
constexpr int kPhaseUp = 3;
constexpr int kMinIntervalMs = 0;     // 0 = 每个 SYN_REPORT 都发（与原模块 164fps 节奏一致）
constexpr int kWriteTimeoutMs = 5000; // 板子不读 → 退出释放触摸

int g_maxX = 1;
int g_maxY = 1;
int g_cli = -1;
void writeState(const char* value);   // 前置声明（定义在下面）

int g_devFdForSignal = -1;
volatile sig_atomic_t g_stopRequested = 0;

void onTerminate(int) {
    g_stopRequested = 1;
    if (g_devFdForSignal >= 0) ioctl(g_devFdForSignal, EVIOCGRAB, 0);   // 显式释放触摸
    writeState("FALLBACK");
    _exit(0);
}

void logErr(const char* msg) {
    if (msg) fprintf(stderr, "[touchfwd] %s\n", msg);
}

uint32_t scale(int raw, int max) {
    if (raw < 0) raw = 0;
    if (max <= 0) max = 1;
    return static_cast<uint32_t>((static_cast<uint64_t>(raw) * kNormMax) /
                                 static_cast<uint64_t>(max));
}

// 丢掉多少帧（网络写不动时的背压结果，用于日志）
// 状态文件：供 UI 读取（UP / FALLBACK），由 helper 自己维护，省掉脚本里每 2s 的 netstat 轮询
void writeState(const char* value) {
    const char* path = getenv("VF_STATE_FILE");
    if (path == nullptr) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    size_t len = strlen(value);
    ssize_t ignored = write(fd, value, len);
    (void) ignored;
    close(fd);
}

long g_dropped = 0;

// 返回 false 表示对端已断开（调用方应结束会话）。
// 关键：**绝不阻塞**。板子读得慢时直接丢帧，保证读触摸的循环永不停摆
//（否则 evdev 的 64 事件内核缓冲会溢出 → 手指动作丢失 → 体感卡顿）。
bool sendAll(const void* data, size_t len) {
    if (g_cli < 0) return false;
    const uint8_t* b = static_cast<const uint8_t*>(data);
    size_t off = 0;
    int waits = 0;
    while (off < len) {
        ssize_t n = send(g_cli, b + off, len - off, MSG_NOSIGNAL | MSG_DONTWAIT);
        if (n > 0) {
            off += static_cast<size_t>(n);
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            // 关键：一帧必须**完整**发出。半帧留在流里会让板子的组帧器报错并主动断开。
            // 这里最多等 2ms（远低于体感阈值），等不到就结束会话，让板子干净重连。
            if (++waits > 2) return false;
            struct pollfd p {};
            p.fd = g_cli;
            p.events = POLLOUT;
            if (poll(&p, 1, 1) <= 0) return false;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        return false;                          // EPIPE / ECONNRESET → 断开
    }
    return true;
}

bool emit(int phase, int x, int y) {
    uint8_t f[14] = {0x55, 0xAA, 0x0B, 0xFF, static_cast<uint8_t>(phase), 0x02,
                     0, 0, 0, 0, 0, 0, 0, 0};
    uint32_t nx = scale(x, g_maxX);
    uint32_t ny = scale(y, g_maxY);
    memcpy(f + 6, &nx, 4);
    memcpy(f + 10, &ny, 4);
    return sendAll(f, sizeof(f));
}

int64_t nowMs() {
    struct timespec ts {};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

struct State {
    int curSlot = 0;
    int sx[kMaxSlots] = {0};
    int sy[kMaxSlots] = {0};
    bool active[kMaxSlots] = {false};
    bool btnDown = false;
    int lastX = -1;
    int lastY = -1;
    int lastPhase = 0;
    int64_t lastSendMs = 0;

    void reset() {
        for (int i = 0; i < kMaxSlots; ++i) {
            sx[i] = sy[i] = 0;
            active[i] = false;
        }
        btnDown = false;
    }

    bool anyActive() const {
        if (btnDown) return true;
        for (int i = 0; i < kMaxSlots; ++i) {
            if (active[i]) return true;
        }
        return false;
    }

    int px() const {
        if (active[0]) return sx[0];
        for (int i = 0; i < kMaxSlots; ++i) {
            if (active[i]) return sx[i];
        }
        return lastX;
    }

    int py() const {
        if (active[0]) return sy[0];
        for (int i = 0; i < kMaxSlots; ++i) {
            if (active[i]) return sy[i];
        }
        return lastY;
    }
};

// 返回 false = 会话应结束
bool onSyn(State& st) {
    const bool touching = st.anyActive();
    int x = st.px();
    int y = st.py();
    if (x < 0 || y < 0) return true;

    int phase;
    if (touching && st.lastPhase == 0) {
        phase = kPhaseDown;
    } else if (touching) {
        phase = kPhaseMove;
    } else if (st.lastPhase == kPhaseDown || st.lastPhase == kPhaseMove) {
        phase = kPhaseUp;
    } else {
        return true;
    }

    int64_t now = nowMs();
    if (phase == kPhaseMove) {
        if (x == st.lastX && y == st.lastY) return true;
        if (now - st.lastSendMs < kMinIntervalMs) return true;
    }
    if (!emit(phase, x, y)) return false;
    st.lastX = x;
    st.lastY = y;
    st.lastSendMs = now;
    // 抬起 = 手势结束，归零；否则下一根手指永远补不出 DOWN
    st.lastPhase = (phase == kPhaseUp) ? 0 : phase;
    return true;
}

// 读板子的 CFG1 配置帧（'CFG1' + u32 长度 + 载荷），读完立刻回确认
bool readConfig(int fd) {
    uint8_t head[8];
    size_t got = 0;
    while (got < sizeof(head)) {
        ssize_t n = recv(fd, head + got, sizeof(head) - got, 0);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            return false;
        }
        got += static_cast<size_t>(n);
    }
    if (memcmp(head, "CFG1", 4) != 0) {
        // 不是配置帧就当作普通数据，直接进入转发
        return true;
    }
    uint32_t len = static_cast<uint32_t>(head[4]) | (static_cast<uint32_t>(head[5]) << 8) |
                   (static_cast<uint32_t>(head[6]) << 16) | (static_cast<uint32_t>(head[7]) << 24);
    if (len > 65536) len = 65536;
    uint8_t buf[1024];
    uint32_t left = len;
    while (left > 0) {
        size_t want = left < sizeof(buf) ? left : sizeof(buf);
        ssize_t n = recv(fd, buf, want, 0);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            return false;
        }
        left -= static_cast<uint32_t>(n);
    }
    fprintf(stderr, "[touchfwd] 收到板子配置帧 %u 字节\n", len);
    return true;
}

// 一个板子会话：读 CFG1 → 回 ACK → 等抬手 → grab → 转发
void serveClient(int cli, int devFd) {
    g_cli = cli;
    State st;
    bool grabbed = false;
    // 默认独占（EVIOCGRAB），与原模块 touch_forwarder 一致；
    // 显式设置 VF_GRAB=0 才走被动读取（系统照常收触摸，我们只旁听转发）。
    const bool wantGrab = []() {
        const char* v = getenv("VF_GRAB");
        return v == nullptr || v[0] != '0';
    }();

    if (!readConfig(cli)) {
        fprintf(stderr, "[touchfwd] 会话结束原因: 读 CFG1 失败\n");
        close(cli);
        g_cli = -1;
        return;
    }
    const uint8_t ack[6] = {0x55, 0xAA, 0x03, 0xFC, 0xF7, 0x01};
    if (!sendAll(ack, sizeof(ack))) {
        fprintf(stderr, "[touchfwd] 会话结束原因: 回确认帧失败\n");
        close(cli);
        g_cli = -1;
        return;
    }
    writeState("UP");
    fprintf(stderr, "[touchfwd] 已回确认帧，等待抬手后独占\n");

    // 自检模式：不发真实触摸，定时在屏幕中心注入一次点击，用于验证板子注入链路
    // VF_SELFTEST=1: 不发真实触摸，只定时发中心点击（不 grab）
    // VF_SELFTEST=2: 先 grab 再定时发中心点击（验证 grab 是否影响注入）
    const char* selftest = getenv("VF_SELFTEST");
    const bool selftestGrab = selftest != nullptr && selftest[0] == '2';
    if (selftestGrab) {
        if (ioctl(devFd, EVIOCGRAB, 1) == 0) {
            fprintf(stderr, "[touchfwd] 自检2：已 grabs\n");
        } else {
            fprintf(stderr, "[touchfwd] 自检2：grab 失败\n");
        }
        fflush(stderr);
    }
    if (selftest != nullptr) {
        fprintf(stderr, "[touchfwd] 自检模式：每 3s 往屏幕中心点一次\n");
        fflush(stderr);
        while (g_cli == cli) {
            // 带位移的序列：25% → 50% → 75%，确保坐标有变化（判断板子是否转发坐标）
            const int x1 = g_maxX / 4,      y1 = g_maxY / 4;
            const int x2 = g_maxX / 2,      y2 = g_maxY / 2;
            const int x3 = g_maxX * 3 / 4,  y3 = g_maxY * 3 / 4;
            if (!emit(kPhaseDown, x1, y1)) break;
            usleep(120 * 1000);
            if (!emit(kPhaseMove, x2, y2)) break;
            usleep(120 * 1000);
            if (!emit(kPhaseMove, x3, y3)) break;
            usleep(120 * 1000);
            if (!emit(kPhaseUp, x3, y3)) break;
            fprintf(stderr, "[touchfwd] selftest: 25%%->50%%->75%% 已发\n");
            fflush(stderr);
            sleep(3);
        }
        close(cli);
        g_cli = -1;
        return;
    }

    long lastLoggedDrop = 0;
    int64_t lastLogMs = nowMs();

    while (true) {
        struct pollfd fds[2];
        fds[0].fd = devFd;
        fds[0].events = POLLIN;
        fds[1].fd = cli;
        fds[1].events = POLLIN;
        int pr = poll(fds, 2, 200);
        if (pr < 0) {
            if (errno == EINTR) continue;
            break;
        }
        // 板子断开？
        if (pr > 0 && (fds[1].revents & (POLLHUP | POLLERR | POLLNVAL))) {
            fprintf(stderr, "[touchfwd] 会话结束原因: 客户端 revents=0x%x (HUP/ERR)\n", fds[1].revents);
            break;
        }
        if (pr > 0 && (fds[1].revents & POLLIN)) {
            char tmp[64];
            ssize_t n = recv(cli, tmp, sizeof(tmp), MSG_DONTWAIT);
            if (n == 0) {
                fprintf(stderr, "[touchfwd] 会话结束原因: 板子关闭连接 (recv=0)\n");
                break;
            }
        }
        int64_t t = nowMs();
        if (t - lastLogMs > 5000 && g_dropped != lastLoggedDrop) {
            lastLoggedDrop = g_dropped;
            lastLogMs = t;
            fprintf(stderr, "[touchfwd] 背压丢帧累计 %ld（板子读得慢，保实时不阻塞）\n", g_dropped);
            fflush(stderr);
        }
        if (pr == 0) continue;
        if ((fds[0].revents & POLLIN) == 0) continue;

        struct input_event ev {};
        ssize_t n = read(devFd, &ev, sizeof(ev));
        if (n != static_cast<ssize_t>(sizeof(ev))) continue;

        switch (ev.type) {
            case EV_ABS:
                if (ev.code == ABS_MT_SLOT) {
                    if (ev.value >= 0 && ev.value < kMaxSlots) st.curSlot = ev.value;
                } else if (ev.code == ABS_MT_POSITION_X) {
                    st.sx[st.curSlot] = ev.value;
                } else if (ev.code == ABS_MT_POSITION_Y) {
                    st.sy[st.curSlot] = ev.value;
                } else if (ev.code == ABS_MT_TRACKING_ID) {
                    st.active[st.curSlot] = ev.value >= 0;
                }
                break;
            case EV_KEY:
                if (ev.code == BTN_TOUCH) {
                    st.btnDown = ev.value != 0;
                    if (!st.btnDown) st.reset();
                }
                break;
            case EV_SYN:
                if (ev.code == SYN_REPORT) {
                    if (!wantGrab) {
                        // 被动模式：系统照常收到触摸，我们只旁听转发
                        if (!onSyn(st)) goto done;
                    } else if (!grabbed) {
                        // 独占模式：等所有手指抬起再抢，避免"正按着的那根"永远等不到抬起
                        if (!st.anyActive() && ioctl(devFd, EVIOCGRAB, 1) == 0) {
                            grabbed = true;
                            fprintf(stderr, "[touchfwd] EVIOCGRAB ok\n");
                        }
        
                    }
                }
                break;
            default:
                break;
        }
    }

done:
    if (grabbed) ioctl(devFd, EVIOCGRAB, 0);
    writeState("FALLBACK");
    fprintf(stderr, "[touchfwd] 会话结束，触摸已释放\n");
    close(cli);
    g_cli = -1;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: %s <event-path> <maxX> <maxY> <port>\n", argv[0]);
        return 2;
    }
    const char* devPath = argv[1];
    g_maxX = atoi(argv[2]);
    g_maxY = atoi(argv[3]);
    int port = atoi(argv[4]);
    if (port <= 0) port = 6532;

    int devFd = open(devPath, O_RDONLY | O_CLOEXEC);
    if (devFd < 0) {
        fprintf(stderr, "[touchfwd] open %s 失败: %s\n", devPath, strerror(errno));
        return 3;
    }

    int lfd = socket(AF_INET6, SOCK_STREAM, 0);
    if (lfd < 0) {
        logErr("socket 失败");
        return 4;
    }
    int one = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    int v6only = 0;
    setsockopt(lfd, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, sizeof(v6only));

    struct sockaddr_in6 addr {};
    addr.sin6_family = AF_INET6;
    addr.sin6_addr = in6addr_any;
    addr.sin6_port = htons(static_cast<uint16_t>(port));
    if (bind(lfd, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) < 0) {
        fprintf(stderr, "[touchfwd] bind :%d 失败: %s\n", port, strerror(errno));
        return 5;
    }
    if (listen(lfd, 4) < 0) {
        logErr("listen 失败");
        return 6;
    }
    g_devFdForSignal = devFd;
    signal(SIGTERM, onTerminate);
    signal(SIGINT, onTerminate);
    fprintf(stderr, "[touchfwd] 监听 :%d，等待板子…\n", port);
    fflush(stderr);

    while (true) {
        int cli = accept(lfd, nullptr, nullptr);
        if (cli < 0) {
            if (errno == EINTR) continue;
            break;
        }
        {
        int one = 1;
        // 关掉 Nagle：否则小包会被内核攒批（实测间隔中位数 0ms、偶发几百 ms 空档），
        // 板子收到就是一顿一顿的。Go 版 touch_forwarder 默认就是 NODELAY。
        setsockopt(cli, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        int sndbuf = 64 * 1024;
        setsockopt(cli, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
    }
    fprintf(stderr, "[touchfwd] 板子已连接 fd=%d\n", cli);
        serveClient(cli, devFd);
    }

    close(lfd);
    close(devFd);
    return 0;
}
