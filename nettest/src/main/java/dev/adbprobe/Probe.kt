package dev.adbprobe

import android.content.Context

/**
 * [probe] One self-contained observation about how wireless ADB behaves on this
 * device/version. Each probe answers a question we otherwise had to guess at
 * (loopback vs LAN binding, service vs persist port liveness, which mDNS types
 * adbd advertises, Local Network Protection gating, ...).
 */
data class ProbeResult(
    val id: String,
    val title: String,
    val status: String,
    val detail: String,
) {
    fun pretty() = "[$status] $title\n    $detail"
    // Single parseable line for the CI matrix (tag ADBLAB in logcat).
    fun logLine() = "RESULT|$id|$status|$detail"
}

interface Probe {
    val id: String
    val title: String
    /** True if it needs no user input and can run headlessly in CI on an emulator. */
    val headlessCapable: Boolean
    /** [port] is the Wireless-debugging port when the user supplied one, else null. */
    fun run(ctx: Context, port: Int?): ProbeResult
}

/** Read a system property via `getprop` (no hidden-API dependency). */
object Sys {
    fun getprop(key: String): String = try {
        val p = ProcessBuilder("getprop", key).redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText().trim()
        p.waitFor()
        out
    } catch (e: Exception) {
        "<err:${e.javaClass.simpleName}>"
    }
}
