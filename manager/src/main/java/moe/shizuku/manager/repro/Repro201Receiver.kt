package moe.shizuku.manager.repro

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import moe.shizuku.manager.BuildConfig

/**
 * Debug-only trigger for the #201 UserService token-race stress test.
 * Deliberately a plain BroadcastReceiver, not AuthenticatedReceiver - this
 * only exists on the throwaway test-harness branch and is meant to be fired by
 * hand from a Shizuku shell (aShell/rish) or adb, so it skips the auth-token
 * extra those receivers require.
 *
 *   am broadcast -a ${'$'}{applicationId}.REPRO_201
 *   am broadcast -a ${'$'}{applicationId}.REPRO_201 --ei count 30 --el interval 100
 */
class Repro201Receiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "Repro201"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "${BuildConfig.APPLICATION_ID}.REPRO_201") return

        val count = intent.getIntExtra("count", 10)
        val interval = intent.getLongExtra("interval", 150L)
        Log.w(TAG, "broadcast received: count=$count interval=${interval}ms")

        Repro201StressTest.run(context.packageName, count, interval)
    }
}
