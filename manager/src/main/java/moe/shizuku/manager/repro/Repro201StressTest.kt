package moe.shizuku.manager.repro

import android.content.ComponentName
import android.content.ServiceConnection
import android.os.IBinder
import android.util.Log
import rikka.shizuku.Shizuku

/**
 * Spams bind/unbind of a throwaway UserService to drive issue #201.
 *
 * Each iteration: bind (server spawns a process, delayed by
 * ShizukuUserServiceManager's REPRO_SPAWN_DELAY_MS) then immediately
 * unbind(remove=true), which acts on the service record well before the
 * delayed spawn on the server's single-threaded executor has attached.
 * On an UNFIXED build the delayed attach then hits
 * "[repro] REPRODUCED #201: unable to find token"; on a FIXED build the
 * attach is absorbed gracefully ([repro] attach OK / no wedge).
 *
 * Not gated behind any permission/auth check - this only exists on the
 * throwaway test-harness branch, for local/CI testing via Repro201Receiver.
 */
object Repro201StressTest {

    private const val TAG = "Repro201"

    private val noopConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, service: IBinder) {}
        override fun onServiceDisconnected(name: ComponentName) {}
    }

    @JvmStatic
    fun run(packageName: String, iterations: Int = 10, intervalMillis: Long = 150L) {
        Thread({
            Log.w(TAG, "starting stress loop: $iterations bind/unbind cycles, interval=${intervalMillis}ms")

            val args = Shizuku.UserServiceArgs(ComponentName(packageName, Repro201Service::class.java.name))
                .daemon(false)
                .processNameSuffix("repro201")
                .tag("repro201")

            for (i in 0 until iterations) {
                try {
                    Log.w(TAG, "iteration $i: bind")
                    Shizuku.bindUserService(args, noopConnection)
                    Thread.sleep(intervalMillis)
                    Log.w(TAG, "iteration $i: unbind(remove=true)")
                    Shizuku.unbindUserService(args, noopConnection, true)
                } catch (t: Throwable) {
                    Log.w(TAG, "iteration $i failed", t)
                }
            }

            Log.w(TAG, "stress loop finished (spawns still queued on the server for a few seconds) - check logcat for '[repro]'")
        }, "Repro201StressTest").start()
    }
}
