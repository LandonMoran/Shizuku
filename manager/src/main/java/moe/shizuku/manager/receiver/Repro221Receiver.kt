package moe.shizuku.manager.receiver

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import moe.shizuku.manager.ShizukuSettings

// [repro] #221 harness-only trigger. Sets the reproduction precondition:
//   auto_disable_usb_debugging = true  (the feature is on)
//   repro_no_disable          = true  (boot receiver logs instead of disabling adb)
// start-on-boot stays off (default), so the boot receiver should decide shouldDisable.
// Never merged into the fix PR.
class Repro221Receiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        ShizukuSettings.initialize(context)
        ShizukuSettings.getPreferences().edit()
            .putBoolean("auto_disable_usb_debugging", true)
            .putBoolean("repro_no_disable", true)
            .apply()
        Log.i(
            "REPRO221",
            "[repro] precondition set: autoDisable=${ShizukuSettings.getAutoDisableUsbDebugging()} " +
                "startOnBoot=${ShizukuSettings.getStartOnBoot(context)}"
        )
    }
}
