package dev.adbprobe

import android.app.Activity
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.util.concurrent.Executors

/**
 * [probe] Answers one question on a real device: when Wireless debugging is on,
 * does adbd accept a connection on LOOPBACK (127.0.0.1 / ::1), only on the LAN
 * interface, or both -- and does the LAN path trip Android 17 Local Network
 * Protection while loopback does not?
 *
 * You supply the port shown in Settings > Developer options > Wireless debugging
 * ("IP address & Port", the number after the colon). The app then tries a TCP
 * connect to 127.0.0.1, ::1, and every non-loopback local address on that port and
 * reports which one adbd accepts. Loopback needs no permission; the LAN targets do
 * on SDK 37+, so run once before granting and once after to see the gate.
 */
class MainActivity : Activity() {

    private lateinit var header: TextView
    private lateinit var portInput: EditText
    private lateinit var results: TextView
    private val exec = Executors.newSingleThreadExecutor()

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
            hint = "port from Wireless debugging"
        }

        val runBtn = Button(this).apply {
            text = "Run probe"
            setOnClickListener { runProbe() }
        }
        val permBtn = Button(this).apply {
            text = "Request local-network permission"
            setOnClickListener { requestLnp() }
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
        val scroll = ScrollView(this).apply { addView(results) }

        root.addView(header, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        root.addView(portInput, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        root.addView(runBtn, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        root.addView(permBtn, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        root.addView(clearBtn, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        root.addView(scroll, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))

        setContentView(root)
        refreshHeader()
    }

    private fun lnpPermission(): String? = when {
        Build.VERSION.SDK_INT >= 37 -> "android.permission.ACCESS_LOCAL_NETWORK"
        Build.VERSION.SDK_INT >= 36 -> "android.permission.NEARBY_WIFI_DEVICES"
        else -> null
    }

    private fun lnpGranted(): Boolean {
        val p = lnpPermission() ?: return true
        return checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED
    }

    private fun refreshHeader() {
        val perm = lnpPermission()
        val ifaces = try {
            targets().joinToString("\n") { "   ${it.first} -> ${it.second}" }
        } catch (e: Exception) {
            "   (interface enum error: ${e.message})"
        }
        header.text = buildString {
            appendLine("ADB Loopback Probe")
            appendLine("Android ${Build.VERSION.RELEASE}  SDK ${Build.VERSION.SDK_INT}  (targetSdk 37)")
            appendLine("local-network perm: ${perm ?: "n/a (<SDK 36)"} = ${if (perm == null) "n/a" else lnpGranted()}")
            appendLine()
            appendLine("Port = Settings > Developer options > Wireless debugging >")
            appendLine("       \"IP address & Port\" (number after the colon)")
            appendLine()
            appendLine("Targets:")
            append(ifaces)
        }
    }

    private fun targets(): List<Pair<String, String>> {
        val list = mutableListOf(
            "loopback IPv4" to "127.0.0.1",
            "loopback IPv6" to "::1",
        )
        NetworkInterface.getNetworkInterfaces().asSequence().forEach { ni ->
            ni.inetAddresses.asSequence().forEach { a ->
                val addr = a.hostAddress ?: return@forEach
                if (!a.isLoopbackAddress) {
                    val v = if (a is Inet6Address) "IPv6" else "IPv4"
                    // strip scope id (e.g. %wlan0) for a clean connect target
                    list += "LAN ${ni.name} $v" to addr.substringBefore('%')
                }
            }
        }
        return list.filter { it.second.isNotEmpty() }
    }

    private fun runProbe() {
        val port = portInput.text.toString().trim().toIntOrNull()
        if (port == null || port !in 1..65535) {
            Toast.makeText(this, "Enter a valid port (1-65535)", Toast.LENGTH_SHORT).show()
            return
        }
        append("\n==== probe :$port   perm-granted=${lnpGranted()} ====")
        val ts = targets()
        exec.execute {
            for ((label, host) in ts) {
                val r = tryConnect(host, port)
                appendUi("$label\n   $host:$port  ->  $r")
            }
            appendUi("---- done ----")
        }
    }

    private fun tryConnect(host: String, port: Int): String = try {
        Socket().use { s ->
            s.connect(InetSocketAddress(host, port), 2500)
            "CONNECTED  (adbd is listening on this address)"
        }
    } catch (e: SecurityException) {
        "BLOCKED by Local Network Protection (needs local-network permission)"
    } catch (e: java.net.ConnectException) {
        "refused: ${e.message}  (nothing bound on this address)"
    } catch (e: java.net.SocketTimeoutException) {
        "timeout (filtered / unreachable)"
    } catch (e: Exception) {
        "${e.javaClass.simpleName}: ${e.message}"
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

    private fun append(line: String) {
        results.append(line + "\n")
    }

    private fun appendUi(line: String) {
        runOnUiThread { append(line) }
    }
}
