package dev.adbprobe

import android.content.Context
import android.content.pm.PackageManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.provider.Settings
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.util.Collections

/** The local-network permission that applies on this SDK (null below SDK 36). */
internal fun lnpPermission(): String? = when {
    Build.VERSION.SDK_INT >= 37 -> "android.permission.ACCESS_LOCAL_NETWORK"
    Build.VERSION.SDK_INT >= 36 -> "android.permission.NEARBY_WIFI_DEVICES"
    else -> null
}

/**
 * True when we may safely touch the LAN / run mDNS discovery. Below SDK 36 there is
 * no gate; on 36/37 we must hold the permission, otherwise the OS intercepts the
 * call with an endless "choose a device" picker (confirmed on a real Android 17
 * device). Gated probes must check this and SKIP rather than trigger that storm.
 */
internal fun lnpSatisfied(ctx: Context): Boolean {
    val p = lnpPermission() ?: return true
    return ctx.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED
}

/** Android release / SDK / form factor. Frames every other result. */
object DeviceInfoProbe : Probe {
    override val id = "device"
    override val title = "Device / OS"
    override val headlessCapable = true
    override fun run(ctx: Context, port: Int?): ProbeResult {
        val tv = ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
        return ProbeResult(
            id, title, "INFO",
            "model=${Build.MODEL} android=${Build.VERSION.RELEASE} sdk=${Build.VERSION.SDK_INT} tv=$tv",
        )
    }
}

/** service.adb.tcp.port (volatile liveness) vs persist.adb.tcp.port (survives reboot). */
object AdbPortsProbe : Probe {
    override val id = "ports"
    override val title = "ADB TCP port props"
    override val headlessCapable = true
    override fun run(ctx: Context, port: Int?): ProbeResult {
        val service = Sys.getprop("service.adb.tcp.port")
        val persist = Sys.getprop("persist.adb.tcp.port")
        val live = service.toIntOrNull()?.let { it > 0 } ?: false
        return ProbeResult(
            id, title, if (live) "LIVE" else "NO-LIVE-PORT",
            "service.adb.tcp.port=[$service] persist.adb.tcp.port=[$persist] liveSignal=$live",
        )
    }
}

/** Global adb settings (readable without WRITE_SECURE_SETTINGS). */
object AdbSettingsProbe : Probe {
    override val id = "settings"
    override val title = "ADB global settings"
    override val headlessCapable = true
    override fun run(ctx: Context, port: Int?): ProbeResult {
        val cr = ctx.contentResolver
        val enabled = Settings.Global.getInt(cr, Settings.Global.ADB_ENABLED, -1)
        val wifi = Settings.Global.getInt(cr, "adb_wifi_enabled", -1)
        return ProbeResult(id, title, "INFO", "adb_enabled=$enabled adb_wifi_enabled=$wifi")
    }
}

/** Which local-network permission applies on this SDK, and is it granted? */
object LnpPermissionProbe : Probe {
    override val id = "lnp"
    override val title = "Local-network permission"
    override val headlessCapable = true
    override fun run(ctx: Context, port: Int?): ProbeResult {
        val perm = when {
            Build.VERSION.SDK_INT >= 37 -> "android.permission.ACCESS_LOCAL_NETWORK"
            Build.VERSION.SDK_INT >= 36 -> "android.permission.NEARBY_WIFI_DEVICES"
            else -> null
        }
        val granted = perm?.let { ctx.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
        return ProbeResult(
            id, title, if (perm == null) "N/A" else if (granted == true) "GRANTED" else "NOT-GRANTED",
            "applies=${perm ?: "none (<SDK 36)"} granted=${granted ?: "n/a"}",
        )
    }
}

/** Which mDNS service types adbd advertises, and whether discovery is gated. */
object MdnsTypesProbe : Probe {
    override val id = "mdns"
    override val title = "mDNS adb service types"
    override val headlessCapable = true

    private val types = listOf("_adb._tcp", "_adb-tls-connect._tcp", "_adb-tls-pairing._tcp")

    override fun run(ctx: Context, port: Int?): ProbeResult {
        if (!lnpSatisfied(ctx)) {
            return ProbeResult(
                id, title, "SKIP-NEEDS-PERM",
                "local-network permission not granted; skipping mDNS discovery to avoid the " +
                    "Android 17 endless connect-a-device picker. Grant it and re-run.",
            )
        }
        val nsd = ctx.getSystemService(NsdManager::class.java)
            ?: return ProbeResult(id, title, "ERROR", "no NsdManager")
        val counts = LinkedHashMap<String, Int>()
        val failures = mutableListOf<String>()
        for (t in types) {
            val names = Collections.synchronizedSet(HashSet<String>())
            var failCode = Int.MIN_VALUE
            val listener = object : NsdManager.DiscoveryListener {
                override fun onStartDiscoveryFailed(s: String, e: Int) { failCode = e }
                override fun onStopDiscoveryFailed(s: String, e: Int) {}
                override fun onDiscoveryStarted(s: String) {}
                override fun onDiscoveryStopped(s: String) {}
                override fun onServiceFound(info: NsdServiceInfo) { names.add(info.serviceName) }
                override fun onServiceLost(info: NsdServiceInfo) {}
            }
            try {
                nsd.discoverServices(t, NsdManager.PROTOCOL_DNS_SD, listener)
                Thread.sleep(4000)
            } catch (e: Exception) {
                failures.add("$t(${e.javaClass.simpleName})")
            } finally {
                try { nsd.stopServiceDiscovery(listener) } catch (_: Exception) {}
            }
            counts[t] = names.size
            if (failCode != Int.MIN_VALUE) failures.add("$t(startFail=$failCode)")
        }
        val anyFound = counts.values.any { it > 0 }
        val detail = counts.entries.joinToString(" ") { "${it.key}=${it.value}" } +
            (if (failures.isEmpty()) "" else "  failures=[${failures.joinToString(",")}]")
        return ProbeResult(id, title, if (anyFound) "FOUND" else "NONE", detail)
    }
}

/** The key question: does adbd accept a connection on loopback vs only the LAN? */
object LoopbackConnectProbe : Probe {
    override val id = "loopback"
    override val title = "Loopback vs LAN connect"
    override val headlessCapable = false
    override fun run(ctx: Context, port: Int?): ProbeResult {
        if (port == null || port !in 1..65535) {
            return ProbeResult(id, title, "SKIP", "no valid port supplied")
        }
        val sb = StringBuilder()
        var loopbackOk = false
        // Loopback is never LAN, so it is safe to attempt without the permission --
        // this is the key A17 question (does adbd accept 127.0.0.1 with no grant?).
        for ((label, host) in loopbackTargets()) {
            val r = tryConnect(host, port)
            if (r.startsWith("CONNECTED")) loopbackOk = true
            sb.append("\n    $label $host:$port -> $r")
        }
        // LAN targets would trip Local Network Protection on A17 (endless device
        // picker) unless the permission is held, so only probe them when it is.
        if (lnpSatisfied(ctx)) {
            for ((label, host) in lanTargets()) {
                sb.append("\n    $label $host:$port -> ${tryConnect(host, port)}")
            }
        } else {
            sb.append("\n    LAN targets skipped (need local-network permission; would trigger the A17 device picker)")
        }
        return ProbeResult(id, title, if (loopbackOk) "LOOPBACK-OK" else "LOOPBACK-FAIL", sb.toString().trim())
    }

    private fun loopbackTargets() = listOf("loopback IPv4" to "127.0.0.1", "loopback IPv6" to "::1")

    private fun lanTargets(): List<Pair<String, String>> {
        val list = mutableListOf<Pair<String, String>>()
        try {
            NetworkInterface.getNetworkInterfaces().asSequence().forEach { ni ->
                ni.inetAddresses.asSequence().forEach { a ->
                    val addr = a.hostAddress ?: return@forEach
                    if (!a.isLoopbackAddress) {
                        val v = if (a is Inet6Address) "IPv6" else "IPv4"
                        list += "LAN ${ni.name} $v" to addr.substringBefore('%')
                    }
                }
            }
        } catch (_: Exception) {}
        return list.filter { it.second.isNotEmpty() }
    }

    fun tryConnect(host: String, port: Int): String = try {
        Socket().use { s ->
            s.connect(InetSocketAddress(host, port), 2500)
            "CONNECTED (adbd listening here)"
        }
    } catch (e: SecurityException) {
        "BLOCKED by Local Network Protection (needs permission)"
    } catch (e: java.net.ConnectException) {
        "refused (${e.message})"
    } catch (e: java.net.SocketTimeoutException) {
        "timeout"
    } catch (e: Exception) {
        "${e.javaClass.simpleName}: ${e.message}"
    }
}

object Probes {
    val all: List<Probe> = listOf(
        DeviceInfoProbe,
        AdbPortsProbe,
        AdbSettingsProbe,
        LnpPermissionProbe,
        LoopbackConnectProbe,
        MdnsTypesProbe,
    )
    val headless: List<Probe> = all.filter { it.headlessCapable }
}
