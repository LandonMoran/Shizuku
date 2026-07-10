package moe.shizuku.manager.receiver

import android.Manifest.permission.WRITE_SECURE_SETTINGS
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import moe.shizuku.manager.ShizukuSettings

/**
 * #221: When "Auto-disable USB debugging" is on, a reboot leaves USB debugging
 * enabled. The disable only runs from [ShizukuStateMachine.setDead] on an explicit
 * STOPPING transition; a reboot instead kills the process (no orderly stop, no
 * STOPPING state), so it never fires and USB debugging stays on after boot.
 *
 * Reconcile at boot: if the setting is on and Shizuku is NOT going to be
 * (re)started on boot -- i.e. start-on-boot is off, so nothing needs USB debugging
 * -- disable it now. When start-on-boot is on, [BootCompleteReceiver] restarts
 * Shizuku (which needs USB debugging), so we leave it alone.
 *
 * This receiver is always enabled (unlike [BootCompleteReceiver], whose enabled
 * state is start-on-boot's source of truth via [ShizukuSettings.getStartOnBoot]);
 * it no-ops cheaply when the setting is off.
 */
class AutoDisableUsbDebuggingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        ShizukuSettings.initialize(context)
        if (!ShizukuSettings.getAutoDisableUsbDebugging()) return
        // start-on-boot on -> Shizuku will restart and needs USB debugging; leave it.
        if (ShizukuSettings.getStartOnBoot(context)) return
        if (context.checkSelfPermission(WRITE_SECURE_SETTINGS) != PackageManager.PERMISSION_GRANTED) return
        Settings.Global.putInt(context.contentResolver, Settings.Global.ADB_ENABLED, 0)
    }
}
