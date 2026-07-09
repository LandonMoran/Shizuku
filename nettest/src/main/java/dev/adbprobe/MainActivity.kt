package dev.adbprobe

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.util.Log
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import java.util.concurrent.Executors

/**
 * [probe] Wireless-ADB behavior bench. Runs a registry of probes (see [Probes]) and
 * shows a shareable report stamped with device / Android version.
 *
 * Interactive: launch normally, optionally type the Wireless-debugging port, tap
 * "Run all probes".
 * Headless (CI): `am start -n dev.adbprobe/.MainActivity --ez auto true [--ei port N]`
 * runs every probe and logs each result under the "ADBLAB" tag for the matrix job.
 */
class MainActivity : Activity() {

    private lateinit var header: TextView
    private lateinit var portInput: EditText
    private lateinit var results: TextView
    private val exec = Executors.newSingleThreadExecutor()

    companion object {
        const val TAG = "ADBLAB"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(16), dp(16), dp(16))
        }

        header = TextView(this).apply { setTextIsSelectable(true) }
        portInput = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_NUMBER
            hint = "Wireless-debugging port (optional; for loopback probe)"
        }
        val runBtn = Button(this).apply {
            text = "Run all probes"
            setOnClickListener { runAll(currentPort()) }
        }
        val permBtn = Button(this).apply {
            text = "Request local-network permission"
            setOnClickListener { requestLnp() }
        }
        val copyBtn = Button(this).apply {
            text = "Copy report"
            setOnClickListener {
                val report = header.text.toString() + "\n\n" + results.text.toString()
                getSystemService(ClipboardManager::class.java)
                    .setPrimaryClip(ClipData.newPlainText("adb-probe report", report))
                Toast.makeText(this@MainActivity, "Report copied", Toast.LENGTH_SHORT).show()
            }
        }
        val clearBtn = Button(this).apply {
            text = "Clear"
            setOnClickListener { results.text = ""; refreshHeader() }
        }
        results = TextView(this).apply {
            setTextIsSelectable(true)
            typeface = Typeface.MONOSPACE
            textSize = 12f
        }

        root.addView(header, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        root.addView(portInput, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        root.addView(runBtn, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        root.addView(permBtn, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        root.addView(copyBtn, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        root.addView(clearBtn, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        root.addView(ScrollView(this).apply { addView(results) }, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))

        setContentView(root)
        refreshHeader()

        if (intent?.getBooleanExtra("auto", false) == true) {
            val p = intent.getIntExtra("port", -1).takeIf { it in 1..65535 }
            runAll(p, headlessLog = true)
        }
    }

    private fun currentPort(): Int? = portInput.text.toString().trim().toIntOrNull()?.takeIf { it in 1..65535 }

    private fun lnpPermission(): String? = when {
        Build.VERSION.SDK_INT >= 37 -> "android.permission.ACCESS_LOCAL_NETWORK"
        Build.VERSION.SDK_INT >= 36 -> "android.permission.NEARBY_WIFI_DEVICES"
        else -> null
    }

    private fun refreshHeader() {
        val perm = lnpPermission()
        val granted = perm?.let { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
        header.text = buildString {
            appendLine("Wireless-ADB behavior bench")
            appendLine("Android ${Build.VERSION.RELEASE}  SDK ${Build.VERSION.SDK_INT}  (targetSdk 37)")
            appendLine("local-network perm: ${perm ?: "n/a"} granted=${granted ?: "n/a"}")
            if (perm != null && granted != true) {
                appendLine(">> On Android 16+: tap 'Request local-network permission' FIRST,")
                appendLine("   else mDNS/LAN probes are skipped (avoids the connect-a-device picker).")
            }
            appendLine()
            appendLine("Port (for loopback probe) = Settings > Developer options >")
            append("  Wireless debugging > \"IP address & Port\" (after the colon)")
        }
    }

    private fun runAll(port: Int?, headlessLog: Boolean = false) {
        append("\n==== run @ perm-granted=${lnpPermission()?.let { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED } ?: "n/a"}  port=${port ?: "none"} ====")
        exec.execute {
            for (p in Probes.all) {
                val r = try {
                    p.run(this, port)
                } catch (e: Exception) {
                    ProbeResult(p.id, p.title, "ERROR", "${e.javaClass.simpleName}: ${e.message}")
                }
                if (headlessLog) Log.i(TAG, r.logLine())
                appendUi(r.pretty())
            }
            if (headlessLog) Log.i(TAG, "DONE")
            appendUi("---- done ----")
        }
    }

    private fun requestLnp() {
        val p = lnpPermission()
        if (p == null) {
            Toast.makeText(this, "No local-network permission on this version", Toast.LENGTH_SHORT).show()
            return
        }
        requestPermissions(arrayOf(p), 1)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val ok = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        append("\npermission ${permissions.firstOrNull()} -> ${if (ok) "GRANTED" else "DENIED"}")
        refreshHeader()
    }

    private fun append(line: String) { results.append(line + "\n") }
    private fun appendUi(line: String) { runOnUiThread { append(line) } }
}
