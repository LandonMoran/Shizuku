package moe.shizuku.manager.receiver

import android.Manifest.permission.WRITE_SECURE_SETTINGS
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import android.util.Log
import moe.shizuku.manager.ShizukuSettings

/**
 * #221: When "Auto-disable USB debugging" is on, a reboot leaves USB debugging
 * enabled -- the disable only ran from [ShizukuStateMachine.setDead] on an explicit
 * STOPPING transition, which a reboot never reaches. Reconcile at boot: if the
 * setting is on and start-on-boot is off (nothing will (re)start Shizuku and need
 * USB debugging), disable it now.
 *
 * NOTE: this file carries [repro] harness instrumentation (the REPRO221 logs and the
 * "repro_no_disable" pref gate that logs instead of actually disabling adb). The
 * clean fix on fix/221-auto-disable-usb-debugging has none of that.
 */
class AutoDisableUsbDebuggingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        ShizukuSettings.initialize(context)
        val autoDisable = ShizukuSettings.getAutoDisableUsbDebugging()
        val startOnBoot = ShizukuSettings.getStartOnBoot(context)
        val hasPerm = context.checkSelfPermission(WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED
        val shouldDisable = autoDisable && !startOnBoot && hasPerm

        Log.i(
            "REPRO221",
            "[repro] boot reconcile: autoDisable=$autoDisable startOnBoot=$startOnBoot hasPerm=$hasPerm shouldDisable=$shouldDisable"
        )
        if (!shouldDisable) return

        // [repro] harness: log instead of actually disabling, so adb stays alive in CI.
        if (ShizukuSettings.getPreferences().getBoolean("repro_no_disable", false)) {
            Log.i("REPRO221", "[repro] repro mode: skipping actual Settings.Global.ADB_ENABLED=0")
            return
        }
        Settings.Global.putInt(context.contentResolver, Settings.Global.ADB_ENABLED, 0)
    }
}
