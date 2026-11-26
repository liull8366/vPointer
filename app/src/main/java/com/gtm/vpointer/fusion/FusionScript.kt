package com.gtm.vpointer.fusion

import android.content.Context
import com.gtm.vpointer.root.RootShell
import java.io.File

/**
 * 内嵌脚本「屏幕触摸转发」的运行器。
 *
 * 设计照搬 Magisk 模块（touch_forwarder）：
 *   · 探测网卡 → 由子网推出板子 IP（不再硬编码）
 *   · 找真正的触摸屏（按量程过滤虚拟设备）
 *   · 用 nc 在 6532 监听，板子连入后回确认帧
 *   · 帮助程序 libtouchgrabfwd.so 以 root 独占触摸（EVIOCGRAB）并把 14 字节帧写进 fifo
 *
 * app 只负责：把 assets 里的脚本落盘、以 root 执行 start/stop、读状态文件。
 * 脚本是常驻守护，app 被杀也不影响转发（和模块一样）。
 */
object FusionScript {

    private const val ASSET = "fusion.sh"
    private const val NAME = "fusion.sh"
    private const val BIN_ASSET = "touch_forwarder_arm64"
    private const val BIN_NAME = "touch_forwarder_arm64"
    private const val STATE_DIR = "/data/local/tmp/vfusion"

    /** 脚本落盘（每次都覆盖，保证与 APK 内版本一致） */
    fun ensureScript(context: Context): File {
        val f = File(context.filesDir, NAME)
        context.assets.open(ASSET).use { input ->
            f.outputStream().use { output -> input.copyTo(output) }
        }
        f.setReadable(true, false)
        f.setExecutable(true, false)
        return f
    }

    /** 把内嵌的模块二进制释放到 app 私有目录（root 可读，脚本会再拷到 /data/local/tmp） */
    fun ensureBinary(context: Context): File {
        val f = File(context.filesDir, BIN_NAME)
        val needsCopy = !f.exists() || f.length() == 0L
        if (needsCopy) {
            context.assets.open(BIN_ASSET).use { input ->
                f.outputStream().use { output -> input.copyTo(output) }
            }
        }
        f.setReadable(true, false)
        f.setExecutable(true, false)
        return f
    }

    /** 帮助程序路径（安装时解压到 nativeLibraryDir） */
    fun helperPath(context: Context): String =
        File(context.applicationInfo.nativeLibraryDir, "libtouchgrabfwd.so").absolutePath

    fun start(context: Context): String {
        val script = ensureScript(context)
        val bin = ensureBinary(context)
        val cmd = "VF_MASTER=${bin.absolutePath} sh ${script.absolutePath} start 2>&1"
        val r = RootShell.exec(cmd, 20_000)
        return r.output.ifEmpty { if (r.ok) "started" else "start 失败" }
    }

    fun stop(context: Context): String {
        val script = ensureScript(context)
        val r = RootShell.exec("sh ${script.absolutePath} stop 2>&1", 20_000)
        return r.output.ifEmpty { if (r.ok) "stopped" else "stop 失败" }
    }

    /** 读脚本写的状态文件 + 最近日志，供 UI 展示 */
    fun status(context: Context): Status {
        val state = readFile("$STATE_DIR/state").trim().ifEmpty { "unknown" }
        val log = RootShell.exec("tail -n 6 $STATE_DIR/fusion.log 2>/dev/null", 6_000)
        val running = RootShell.exec(
            "test -f $STATE_DIR/daemon.pid && kill -0 \$(cat $STATE_DIR/daemon.pid) 2>/dev/null && echo alive || echo dead",
            6_000
        ).output.trim() == "alive"
        return Status(state = state, running = running, log = log.output.trim())
    }

    private fun readFile(path: String): String =
        runCatching { RootShell.exec("cat $path 2>/dev/null", 5_000).output }.getOrDefault("")

    data class Status(val state: String, val running: Boolean, val log: String)
}
