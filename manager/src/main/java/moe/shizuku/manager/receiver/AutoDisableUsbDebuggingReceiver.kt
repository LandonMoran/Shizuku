package moe.shizuku.manager.receiver

import android.Manifest.permission.WRITE_SECURE_SETTINGS
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import android.util.Log
import moe.shizuku.manager.R
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
 *
 * TEST-BUILD INSTRUMENTATION (remove before shipping): this build posts a one-shot
 * notification at boot showing the exact decision -- each guard value plus
 * ADB_ENABLED before/after -- so the invisible boot-time branch can be read
 * directly on-device without logcat. Behaviour is otherwise unchanged: USB
 * debugging is still disabled only when all three guards pass.
 */
class AutoDisableUsbDebuggingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        ShizukuSettings.initialize(context)

        val autoDisable = ShizukuSettings.getAutoDisableUsbDebugging()
        val startOnBoot = ShizukuSettings.getStartOnBoot(context)
        val watchdog = ShizukuSettings.getWatchdog()
        val wss = context.checkSelfPermission(WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED
        val cr = context.contentResolver
        val before = Settings.Global.getInt(cr, Settings.Global.ADB_ENABLED, -1)

        val action = when {
            !autoDisable -> "skip: setting off"
            // start-on-boot on -> Shizuku will restart and needs USB debugging; leave it.
            startOnBoot -> "skip: start-on-boot on"
            !wss -> "skip: no WRITE_SECURE_SETTINGS"
            else -> {
                Settings.Global.putInt(cr, Settings.Global.ADB_ENABLED, 0)
                "DISABLED usb debugging"
            }
        }
        val after = Settings.Global.getInt(cr, Settings.Global.ADB_ENABLED, -1)

        val msg = "autoDisable=$autoDisable startOnBoot=$startOnBoot watchdog=$watchdog " +
                "wss=$wss  ADB_ENABLED $before->$after  [$action]"
        Log.i("AutoDisableUsbDbg", "#221 boot: $msg")
        postDiag(context, msg)
    }

    // TEST-BUILD only: surface the boot decision as a readable notification.
    private fun postDiag(context: Context, msg: String) {
        try {
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            val channelId = "adb221_diag"
            nm.createNotificationChannel(
                NotificationChannel(channelId, "#221 boot diagnostic", NotificationManager.IMPORTANCE_HIGH)
            )
            val n = Notification.Builder(context, channelId)
                .setSmallIcon(R.drawable.ic_system_icon)
                .setContentTitle("#221 boot: auto-disable USB debugging")
                .setContentText(msg)
                .setStyle(Notification.BigTextStyle().bigText(msg))
                .setAutoCancel(true)
                .build()
            nm.notify(2210, n)
        } catch (e: Exception) {
            Log.w("AutoDisableUsbDbg", "diag notification failed", e)
        }
    }
}
