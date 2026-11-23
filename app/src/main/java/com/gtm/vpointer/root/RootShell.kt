package com.gtm.vpointer.root

import java.io.File
import java.util.concurrent.TimeUnit

/**
 * root 命令执行层。
 *
 * 为什么要试多个路径：不同 root 方案把 `su` 放在不同位置，而且是否对普通应用可见
 * 取决于 mount namespace —— 在本机（KernelSU）实测：
 *
 * ```
 * sh -c id              → uid=10511（应用自身，说明能起进程）
 * su / /system/bin/su   → ENOENT（应用命名空间里看不到）
 * /data/adb/ksu/bin/su  → EACCES（/data/adb 是 700 root）
 * ```
 *
 * 所以这里按候选列表逐个尝试，第一个能返回 `uid=0` 的路径会被缓存；
 * 全部失败时把每个候选的错误一起返回，便于在 UI 上直接看到原因
 * （通常是「还没在 root 管理器里给本应用授权」）。
 */
object RootShell {

    data class Result(val ok: Boolean, val output: String, val suPath: String?)

    private val CANDIDATES = listOf(
        "su",
        "/system/bin/su",
        "/system/xbin/su",
        "/sbin/su",
        "/debug_ramdisk/su",
        "/data/adb/ksu/bin/su",
        "/data/adb/magisk/su"
    )

    @Volatile
    private var cachedSu: String? = null

    /** 执行一条 root 命令；成功返回 (true, 输出)。失败时 output 里是各候选的失败原因。 */
    fun exec(command: String, timeoutMs: Long = 10_000): Result {
        val tried = StringBuilder()

        val preferred = cachedSu
        val order = if (preferred != null) listOf(preferred) + CANDIDATES.filter { it != preferred } else CANDIDATES

        for (candidate in order) {
            val attempt = runCatching {
                val process = ProcessBuilder(candidate, "-c", command)
                    .redirectErrorStream(true)
                    .start()
                val out = process.inputStream.bufferedReader().use { it.readText() }
                val finished = process.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
                if (!finished) {
                    process.destroyForcibly()
                    return@runCatching "超时（${timeoutMs}ms）" to -1
                }
                out.trim() to process.exitValue()
            }.getOrElse { e ->
                "无法执行（${e.javaClass.simpleName}: ${e.message}）" to -1
            }

            val (out, code) = attempt
            // 成功判据：**优先看退出码**。appops/dumpsys 这类命令本身有输出但不含 uid=0，
            // 早先要求「输出含 uid=0」会把成功误判成失败，并且会继续尝试后面的候选路径、
            // 把同一组命令重复执行多次（实测确实重复跑了 6 遍）。
            if (code == 0) {
                cachedSu = candidate
                return Result(true, out.ifEmpty { "(命令无输出)" }, candidate)
            }
            tried.append(candidate).append(" → ").append(out.ifEmpty { "退出码 $code" }).append('\n')
        }
        cachedSu = null
        return Result(false, tried.toString().trim(), null)
    }

    /** 简单探针：能不能拿到 root（供 UI 自检用）。 */
    fun hasRoot(): Boolean = exec("id").ok

    /** 把脚本写到应用私有目录，返回绝对路径（root 一定读得到 app 私有目录）。 */
    fun writeScript(dir: File, name: String, content: String): File {
        val f = File(dir, name)
        f.writeText(content, Charsets.UTF_8)
        // root 执行，权限给 700 即可；应用自己也能覆盖重写
        f.setReadable(true, true)
        f.setExecutable(true, true)
        return f
    }
}
