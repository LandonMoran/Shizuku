package moe.shizuku.manager.receiver

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import moe.shizuku.manager.ShizukuSettings
import moe.shizuku.manager.utils.EnvironmentUtils
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

        // [repro] #188: log the PRODUCTION port decision at trigger time. This calls
        // the same functions AdbStartWorker.enqueue() uses, so it reflects whichever
        // variant's logic is compiled in. It fires regardless of whether the worker
        // later runs -- which matters because the fixed variant flips isWifiRequired()
        // to true, attaching an UNMETERED WorkManager constraint the CI emulator can't
        // satisfy (no unmetered network), so the fixed worker never executes. The
        // decision itself is what proves the fix, and we capture it here.
        val staleAdbPort = EnvironmentUtils.getAdbTcpPort()
        val wifiRequired = EnvironmentUtils.isWifiRequired()
        Log.i(
            "REPRO188",
            "[repro] decision: getAdbTcpPort()=$staleAdbPort isWifiRequired=$wifiRequired useStaleDirect=${!wifiRequired}"
        )

        // [repro] #188 manual Start-button path. The home "Start wireless ADB" button
        // (StartWirelessAdbViewHolder.start) direct-connects to its tcpPort in the
        // tcpMode branch. Replicate that branch selection here with BOTH port getters
        // to prove the fix flips it: the stale getAdbTcpPort() would DIRECT_DIAL the
        // dead persisted port; the fixed getLiveAdbTcpPort() yields <=0 so the button
        // routes to mDNS rediscovery instead. tls/tcpMode forced true to exercise the
        // dangerous direct-dial branch. This getLiveAdbTcpPort() call only compiles on
        // the fixed variant (the symbol the fix added), so it runs on the fixed leg.
        val liveAdbPort = EnvironmentUtils.getLiveAdbTcpPort()
        fun manualRoute(tcpPort: Int): String = when {
            tcpPort <= 0 -> "MDNS_DISCOVERY"
            else -> "DIRECT_DIAL:$tcpPort" // tcpMode=true assumed (the risky branch)
        }
        Log.i(
            "REPRO188",
            "[repro] manualRoute: staleTcpPort=$staleAdbPort liveTcpPort=$liveAdbPort " +
                "staleRoute=${manualRoute(staleAdbPort)} liveRoute=${manualRoute(liveAdbPort)}"
        )

        AdbStartWorker.enqueue(context)
    }
}
