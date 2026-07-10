package moe.shizuku.manager.utils

import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.SystemProperties
import moe.shizuku.manager.ShizukuApplication
import moe.shizuku.manager.ShizukuSettings
import com.topjohnwu.superuser.Shell
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.InetSocketAddress
import java.net.Socket

private val appContext = ShizukuApplication.appContext

object EnvironmentUtils {

    @JvmStatic
    fun isWatch(): Boolean {
        return (appContext.getSystemService(UiModeManager::class.java).currentModeType
                == Configuration.UI_MODE_TYPE_WATCH)
    }

    @JvmStatic
    fun isTelevision(): Boolean {
        return (appContext.getSystemService(UiModeManager::class.java).currentModeType
                == Configuration.UI_MODE_TYPE_TELEVISION ||
                appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK))
    }

    fun isTlsSupported(): Boolean {
        return if (isTelevision())
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
            else Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
    }

    fun isWifiRequired(): Boolean {
        return (getLiveAdbTcpPort() <= 0 || !ShizukuSettings.getTcpMode())
    }

    fun isRooted(): Boolean {
        return Shell.getShell().isRoot
    }

    fun getAdbTcpPort(): Int {
        var port = SystemProperties.getInt("service.adb.tcp.port", -1)
        if (port == -1) port = SystemProperties.getInt("persist.adb.tcp.port", -1)
        if (port == -1 && isTelevision() && !isTlsSupported()) port = ShizukuSettings.getTcpPort()
        return port
    }

    /**
     * The ADB TCP port that is safe to connect to WITHOUT first re-discovering it
     * over mDNS. Unlike [getAdbTcpPort], this deliberately excludes
     * `persist.adb.tcp.port`: that property survives a reboot but adbd does not
     * necessarily relisten on it, so on boot it is frequently a stale/dead port.
     * Trusting it there made the start path skip discovery and connect to a dead
     * port, failing every start until wireless debugging was toggled once (#188).
     *
     * `service.adb.tcp.port` is volatile (set only while adbd is actively listening
     * on TCP), so it is a real liveness signal. Non-TLS TVs cannot use mDNS
     * discovery, so their configured port stays a valid direct target.
     */
    fun getLiveAdbTcpPort(): Int {
        var port = SystemProperties.getInt("service.adb.tcp.port", -1)
        if (port == -1 && isTelevision() && !isTlsSupported()) port = ShizukuSettings.getTcpPort()
        return port
    }

    /**
     * Whether adbd is *actually* listening on [port] right now, verified by a real
     * connect with a short [timeoutMs]. A non-stale property value is still not proof
     * of liveness: on some ROMs `service.adb.tcp.port` itself holds a dead port after
     * boot (#188 -- the reporter's returned 6776 while every connect failed). So knock
     * before trusting it; a refused/dead port returns false and the caller should fall
     * back to mDNS re-discovery. (Approach thedjchi described on #188: connect with a
     * timeout to verify the port is valid before taking it.)
     */
    suspend fun isAdbPortLive(host: String, port: Int, timeoutMs: Int = 1000): Boolean {
        if (port <= 0) return false
        return withContext(Dispatchers.IO) {
            try {
                Socket().use { it.connect(InetSocketAddress(host, port), timeoutMs) }
                true
            } catch (e: Exception) {
                false
            }
        }
    }
}
