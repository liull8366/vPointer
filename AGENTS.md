# AGENTS.md —— vPointer 项目交接说明（给其他 agent 读）

> 目标读者：接手本仓库的 AI agent / 人类工程师。
> 读完本文你应该知道：**这套东西由哪几块组成、协议长什么样、哪些约束绝对不能破、以及怎么验证改动**。
> 项目语言：Kotlin（Android）+ C（root 帮助程序）+ POSIX shell（内嵌脚本）。文档与注释均为中文。

---

## 1. 这是什么

`vPointer`（包名 `com.gtm.vpointer`）是一个 Android 应用：

1. **虚拟光标** —— 手机/外接屏上叠加一个光标，通过 UDP/TCP 接收坐标控制；
2. **TCP 端口转发** —— 8000 → `192.168.73.1:80`，让浏览器能访问板子的 WebUI；
3. **Lua 日志** —— 连板子的 `ws://192.168.73.1/ws`，把 Lua 日志悬浮显示；
4. **Root 权限** —— root 自检 + 一键授权（悬浮窗 appops / Doze 白名单）；
5. **屏幕触摸转发（融合）** —— 用 root 独占手机触摸屏，把触摸帧直连板子 6532，**绕过端口转发**。

板子是 **pico-hid-mapper**（RP2350 定制板，把键鼠映射成触屏操作）。两者通过 USB 网卡直连，板子固定 IP `192.168.73.1`、手机 `192.168.73.2`。

> 注意：本仓库早期还有一个 Magisk 模块（`touch_forwarder_v1.8_magisk.zip`）实现过同样的融合能力。**现在的能力已内嵌进 app**，模块仅作为“行为参照”保留在会话资料里，不在本仓库内。

---

## 2. 目录与文件职责

```
app/src/main/java/com/gtm/vpointer/
  MainActivity.kt              Compose 主界面、4 个 Tab、各服务状态回传
  PointerService.kt            虚拟光标：绑定 6533/6534/6535，渲染 Overlay / Presentation
  PortForwarder.kt             端口转发的实现（网卡识别 + Network.bindSocket + 泵）
  PortForwardService.kt        端口转发前台服务
  DisplayManagerHelper.kt      显示器枚举（内置屏 / FLAG_PRESENTATION）
  NicInfo.kt                   网卡信息模型
  lua/MiniWebSocket.kt         零依赖 WebSocket 客户端
  lua/LuaLogService.kt         Lua 日志：WS 客户端 + 前台服务
  lua/LuaOverlay.kt            日志悬浮窗（两个窗口：穿透层 + 可拖动的按钮条）
  lua/LuaLogStore.kt            日志配置持久化（筛选/字号/透明度/坐标）
  lua/NetBinder.kt             按子网找网卡 + Network.bindSocket / 源地址回退
  root/RootShell.kt            su 执行层（多候选路径探测、退出码判成功）
  fusion/FusionScript.kt       融合脚本的落盘与 start/stop/status
  ui/screen/*.kt               各 Tab 页面
app/src/main/assets/fusion.sh  融合的内嵌脚本（root 执行，等价原模块的 service.sh + guard.sh）
app/src/main/cpp/touch_fwd_main.cpp  root 帮助程序（编译成 libtouchgrabfwd.so）
app/src/main/cpp/CMakeLists.txt
```

关键构建参数：AGP 8.12.2 / Gradle 8.13 / Kotlin 2.0.21 / compileSdk=targetSdk=36 / minSdk 24 /
`ndkVersion 26.1.10909125` / cmake 3.22.1 / 只打 `arm64-v8a`。

---

## 3. 协议速查

### 3.1 手机 ← 板子（光标，原有功能）

| 通道 | 格式 |
|---|---|
| UDP 6533 | 文本 `x,y,show,down,0\n` |
| UDP 6534 | 9 字节小端 `vmouse_t`：`i32 x, i32 y, u8 state`（bit0=show, bit1=down） |
| TCP 6535 | 11 字节：header `0x55 0xAA` + 9 字节 `vmouse_t`；连接建立后手机回 1 字节屏幕方向，旋转时主动推送 |

### 3.2 端口转发（原有功能）

`8000 → 192.168.73.1:80`。按“子网包含 192.168.73.1”识别网卡 → 找同名 `Network` → `Network.bindSocket()`；
无 Network 时回退绑定该网卡源地址；两者都拿不到就**拒绝建链**。网卡热插拔靠 `NetworkCallback` + 2s 轮询。

### 3.3 融合：板子 ← 手机（6532，本仓库新增）

板子是 **TCP 客户端**，主动连手机的 6532；手机是服务端。

```
板子 → 手机:  "CFG1" + u32 LE 长度 + KMCF 配置载荷     （实测 1256 字节载荷）
手机 → 板子:  55 AA 03 FC F7 01                        （订阅/确认帧，6 字节，必须立刻回）
手机 → 板子:  55 AA 0B FF action id x:i32LE y:i32LE    （14 字节触摸帧）
              action: 1=DOWN 2=MOVE 3=UP
              x,y   : ABS_MT_POSITION 线性缩放到 0..0x7FFFFFFE
```

板子固件里这些 55 AA 控制帧的类型（来自官方 API 文档）：

| CMD | 含义 | 载荷 |
|---|---|---|
| `0xFF` | 直接触屏输出（绕过映射引擎） | 10B：action u8 / id u8 / x i32 / y i32 |
| `0xFE` | HID 鼠标报文 | 8B：report_id / buttons(bit0 左键) / x i16 / y i16 / wheel i8 / rsv |
| `0xFD` | HID 键盘报文 | 8B：modifiers / rsv / keys[6] |
| `0xFC` | core_input 调度 | subcmd：0xFF 移动 / 0xFE 鼠标键 / 0xFC 键盘 / 0xFB 方向 / 0xF9 手柄 |
| `0xFB` | vmouse 状态转发到网络 | 9B：x i32 / y i32 / state u8 |
| `0xFA` | 自定义事件（→ Lua） | UTF-8 文本 ≤60B |
| `0xF8` | DS5 裸报文直通 | 40B |

`55 AA 03 FC F7 01` 是固件在 Core0 特别消费的**订阅帧**（subcmd 0xF7，未公开），收到它之后才发 TFS1。

---

## 4. 融合子系统架构

```
Root 页「启动转发」
      │  (su)
      ▼
assets/fusion.sh  ──探测网卡(192.168.73.x) → 推板子 IP
      │            ──探测 :80 健康度（curl --interface eth0），失败拒绝启动
      │            ──按量程/名字/INPUT_PROP_DIRECT 选真触摸屏
      │            ──清理历史遗留 getevent（读已删节点会 100% CPU）
      │
      ├─ nohup sh fusion.sh run …  （监督循环：helper 退出→写 FALLBACK→2s 后重启）
      │        │
      │        ▼
      │   libtouchgrabfwd.so <dev> <maxX> <maxY> <port>   ← root 运行
      │        listen 6532 → accept → 读 CFG1 → 回订阅帧
      │        → 等所有手指抬起 → ioctl(EVIOCGRAB,1)
      │        → 每帧 write 14B → 板子
      │        → 断线/写失败 → ioctl(EVIOCGRAB,0) + close → 回到 accept
      │
      └─ 状态文件 /data/local/tmp/vfusion/state（helper 写 UP/FALLBACK）
```

两种模式（环境变量 `VF_GRAB`）：

| 值 | 行为 |
|---|---|
| `1`（默认，与原模块一致） | `EVIOCGRAB` 独占：转发期间**屏幕自身不响应** |
| `0` | 被动读取：屏幕照常可用，同时旁听一份发给板子 |

---

## 5. 板子固件的硬约束（决定了一切设计）

来自官方文档与模块证据链，**这些数字是设计依据，不要凭感觉改**：

| 资源 | 值 | 影响 |
|---|---|---|
| `MEMP_NUM_TCP_PCB` | **10（全局共享）** | HTTP:80 / WS-IPC / 6535 / 6532 / 并发 HTTP 共用；我们只能占 1 |
| `PBUF_POOL_SIZE` | 16 | 全部 TCP/UDP 共享 |
| `TCP_SND_BUF` | 1072 B | 单连接在途 ≤1KB |
| 6532 RX 环 | **4096 B** | 满则**静默丢字节**（仍 ACK），靠 parser 重新找 0x55 |
| Core1 控制帧队列 | **16 槽 × 64 B** | 满了 Core0 停止消费，帧挂 pending |
| keepalive | 空闲 15s / 间隔 5s / 3 次 | 只挂在 6532 的 CONNECTED 态 |
| 重连计时 | `TCP6532_RECONNECT_MS=2000`，**按主循环圈数计** | 循环快时重连比 2s 更密 |

**推论（必须遵守）**：
- 绝不能制造连接风暴（历史事故：**112 次/秒** 重连，累计 3663 条 TIME_WAIT）；
- 绝不能往 6532 灌超过它消费能力的数据（否则静默丢帧）；
- 握手是**毫秒级**的：板子连上→推 CFG1→等回帧，慢一点它就断开重连。

---

## 6. 不变量（改动时禁止破坏）

### 融合（C 帮助程序）

1. **订阅帧必须毫秒级回**。用 shell（`nc` + 每秒轮询 `netstat`）做不到，实测会引发重连风暴。
2. **一帧必须原子写出**。`send()` 可能只写出一部分；半帧会让板子组帧器报错并主动断链。
   现实现：`MSG_DONTWAIT` + 最多 2ms 有界等待，写不出就结束会话（让板子干净重连）。
3. **读触摸的线程永不被网络阻塞**。历史 bug：`poll(POLLOUT,5s)` 阻塞 → evdev 64 事件内核缓冲溢出 → 手机动作丢失再跳。
4. **`TCP_NODELAY` 必须开**。Go 版二进制默认开，C 版之前漏了 → 帧被内核攒批（间隔中位 0ms、偶发 4s 空档）→ 体感"响应很慢"。
5. **等所有手指抬起再 `EVIOCGRAB`**。否则正在按着的那根手指永远等不到抬起，屏幕卡死。
6. **触摸设备必须严格筛选**：量程像真实屏幕（x 200..20000、y 200..40000）+ 名字含 `touch/synaptics/goodix/focaltech/panel` 或有 `INPUT_PROP_DIRECT`。
   历史事故：`getevent -pl` 里 DualSense（板子的 HID 接口）排在前面、量程 `0..0x7FFFFFFE`，抓错它 → **板子的键鼠操作全被我们读走**。
7. **绝不主动 close 连接**；只在 `recv()==0 / POLLHUP / POLLERR / 写失败` 时结束。
8. **`SIGTERM` 必须干净释放**：显式 `EVIOCGRAB(0)` + 写 `FALLBACK` 再退出。
9. **清理进程用 `pkill -x libtouchgrabfwd`，不要 `pkill -f`**。
   监督进程的 cmdline 里含 `libtouchgrabfwd.so` 路径，`-f` 会把监督自己一起杀掉 → 板子断线后再没人重连（症状：state 卡在 `UP`）。

### 脚本（fusion.sh）

10. **启动前探测 `:80`**（`curl --interface eth0`），失败拒绝启动并写 `BOARD_DOWN`。
11. **必须按接口名绑定**（`--interface eth0`，即 `SO_BINDTODEVICE`）。按源 IP 绑（`--interface 192.168.73.2`）**无效**：
    Android 策略路由下 `ip route get 192.168.73.1` 会命中 wlan0 表的默认路由（`via 192.168.168.1 dev wlan0`），SYN 根本出不了 eth0 → 表现为"板子无响应"的假故障。
12. **启动时清理孤儿 `getevent`**：读已删除的 `/dev/input/event*` 节点会返回 0/错误，`getevent` 死循环空转 **100% CPU**（86% 在内核态），整机卡顿。只杀带 `-l` 的读取器，不碰一次性的 `-pl`。

### 端口转发（PortForwarder）

13. **上游并发上限 `MAX_UPSTREAM=4`**：板子只有 10 个 PCB，每条下游都会新建一条上游。
14. **下游空闲 30s 回收**（`soTimeout`），及时把 PCB 还给板子。
15. **上游失败退避 1→2→4→8s**，板子异常时不再被持续重连打。

---

## 7. 构建 / 部署 / 调试

```powershell
# 构建（release 需要签名环境变量；lintVital 在本工程上有问题，按下面排除）
$env:KEYSTORE_PASSWORD="..."; $env:KEY_ALIAS="vpointer"; $env:KEY_PASSWORD="..."
.\gradlew.bat assembleRelease -x lintVitalRelease -x lintVitalAnalyzeRelease -x lintVitalReportRelease

# native 改动后如果 Gradle 说 “BUILD SUCCESSFUL in 1s” 却没重新编译，先删 app/.cxx 再构建
Remove-Item -Recurse -Force app\.cxx

# 安装（签名与 1.0/1.1 相同，可直接覆盖）
adb install -r app/build/outputs/apk/release/app-release.apk
```

### 融合的运行期位置

| 内容 | 路径 |
|---|---|
| 内嵌脚本落盘 | `/data/data/com.gtm.vpointer/files/fusion.sh`（由 `FusionScript.ensureScript()` 从 assets 覆盖） |
| 帮助程序 | `applicationInfo.nativeLibraryDir/libtouchgrabfwd.so`（需 `android:extractNativeLibs="true"`） |
| 日志 | `/data/local/tmp/vfusion/fusion.log` |
| 状态 | `/data/local/tmp/vfusion/state`（`UP` / `FALLBACK` / `STOPPED` / `BOARD_DOWN`） |
| 监督 pid | `/data/local/tmp/vfusion/daemon.pid` |

```bash
# 状态 / 启停（root）
su -c 'sh /data/data/com.gtm.vpointer/files/fusion.sh status'
su -c 'sh /data/data/com.gtm.vpointer/files/fusion.sh start'
su -c 'sh /data/data/com.gtm.vpointer/files/fusion.sh stop'
```

### 验证手段（都很实用）

```bash
# 1) 我们发出的触摸帧（抓 6532）
su -c 'tcpdump -i eth0 -s 0 -U -w /data/local/tmp/x.pcap port 6532'

# 2) 板子把触摸注进手机（event9 = DualSense 复合设备，触摸走它）
su -c 'getevent -lt /dev/input/event9'      # 只能抓一个设备；必须在我们 grab 之后再打开

# 3) 板子健康度（必须按接口名绑！）
su -c 'curl -s -m 3 --interface eth0 -o /dev/null -w "%{http_code}\n" http://192.168.73.1/'

# 4) 连接数与 PCB 压力
su -c 'netstat -tn | grep 192.168.73.1'

# 5) 界面掉帧（不受 grab 影响，用 input swipe 驱动）
dumpsys gfxinfo <包名> reset; input swipe 750 1800 750 600 250; dumpsys gfxinfo <包名>
```

**帧节奏基线（原模块实测，用来判断是否劣化）**：164 fps，帧间隔中位 5.6ms、p90 5.9ms。
我们曾经掉到 61.6 fps / 中位 11.2ms / p90 22.3ms —— 那就是"响应慢"的量化形态。

---

## 8. 已知限制

1. 板子是**按需连接**的客户端，它什么时候重连由固件决定；我们只能保证"连上就秒回、全程不主动断、不阻塞"。
2. 独占模式下**屏幕本身不响应**是设计行为（原模块语义），不是 bug；需要屏幕可用就设 `VF_GRAB=0`。
3. `0xFF` 触摸帧与板子自身的“视角映射”同时注入时，Android 会看到两路触点交错，点击可能被判为手势取消。
   需要"边动视角边点击"时应改用 `0xFE` 鼠标键（尚未实现）。
4. 板子对**相同坐标**的触摸帧会去重（注入流里看不到 POSITION 变化），做协议测试时务必让坐标变化。
5. 本工程的 `lintVital*` 任务会失败，正式包构建需按第 7 节排除；未深入排查原因。

---

## 9. 相关外部资源

- 板子文档：`https://doc.rd5isto.top/api/`（`hid-api.html` = 55 AA 控制帧全表；`touch-forwarder.html` = 原模块安装说明）
- 板子固件：pico-hid-mapper（RP2350），TCP 6532 是“触屏转发”通道
