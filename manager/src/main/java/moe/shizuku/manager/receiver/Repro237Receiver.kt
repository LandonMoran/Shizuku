package moe.shizuku.manager.receiver

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import moe.shizuku.manager.ShizukuSettings
import moe.shizuku.manager.utils.EnvironmentUtils
import moe.shizuku.manager.worker.AdbStartWorker

// [repro] #237 harness-only trigger. Sets up the #237 precondition -- TCP mode OFF
// with a configured ADB TCP port present -- then enqueues the REAL AdbStartWorker.
// On baseline the worker's `if (tcpPort > 0 && !getTcpMode()) stopTcp()` fires on
// this background start (the over-control lisonge reported); the fix removes it.
// Never merged into the fix PR.
class Repro237Receiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        ShizukuSettings.initialize(context)
        ShizukuSettings.setLastLaunchMode(ShizukuSettings.LaunchMethod.ADB)
        ShizukuSettings.setTcpMode(false) // #237 precondition: user does NOT want TCP mode

        val tcpPort = EnvironmentUtils.getAdbTcpPort()
        Log.i(
            "REPRO237",
            "[repro] decision: getAdbTcpPort()=$tcpPort tcpMode=${ShizukuSettings.getTcpMode()} " +
                "wouldStopTcp=${tcpPort > 0 && !ShizukuSettings.getTcpMode()}"
        )
        AdbStartWorker.enqueue(context)
    }
}
