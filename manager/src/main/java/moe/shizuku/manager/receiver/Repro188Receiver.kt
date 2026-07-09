package moe.shizuku.manager.receiver

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import moe.shizuku.manager.ShizukuSettings
import moe.shizuku.manager.worker.AdbStartWorker

// [repro] #188 harness-only trigger. Sets the launch mode to ADB and enqueues the
// REAL AdbStartWorker so CI can drive the production start path headlessly, without
// the auth-token / notification / UI flow. This is repro scaffolding: it lives only
// on the claude/code-session-review-vp9clq* harness branches and is NEVER merged
// into the #188 fix PR (same discipline as the #201 env-gated hooks).
class Repro188Receiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        ShizukuSettings.initialize(context)
        ShizukuSettings.setLastLaunchMode(ShizukuSettings.LaunchMethod.ADB)
        Log.i("REPRO188", "[repro] trigger received; launch mode=ADB; enqueuing AdbStartWorker")
        AdbStartWorker.enqueue(context)
    }
}
