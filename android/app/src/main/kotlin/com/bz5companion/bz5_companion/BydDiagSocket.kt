package com.bz5companion.bz5_companion

import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.util.Log
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import kotlin.system.measureTimeMillis

/**
 * Client for the system's `diag_socket_channel` Unix abstract socket,
 * reverse-engineered from `com.byd.diagnosticinfo`.
 *
 * Connection is a single request/response on a Linux abstract-namespace
 * socket — there is no AIDL, no permission, no Android framework gate.
 * SELinux on locked-down builds may refuse the connect; this client
 * surfaces that as an IOException to the caller.
 *
 * Protocol (single request, single multi-row response, then EOF):
 *
 *   Client → "latest_diag_data"   (or "all_diag_data")
 *   Server → row1@row2@row3@...
 *
 * Each row is 10 fields separated by '#':
 *
 *   0: numeric id
 *   1: module type (numeric)
 *   2: module name (string)
 *   3: dtc code (string, e.g. "P1234" or hex)
 *   4: state (int; 0 = active fault, others = historic / cleared)
 *   5: destination bitfield (bits encode which app should receive it;
 *      diagnosticinfo filters with `(dest >> 8) & 0xF == 1`)
 *   6: diag type (int)
 *   7: description / human-readable text
 *   8: data payload as JSON: {"data":[{"key":"...","value":"..."}, ...]}
 *   9: record timestamp (epoch seconds, possibly with millis)
 *
 * SNAPSHOT only — there is no streaming variant. For live DTC monitoring
 * subscribe to the corresponding `BYDAutoDtcDevice` features through the
 * property client.
 */
object BydDiagSocket {

    private const val TAG = "BydDiagSocket"
    private const val SOCKET_NAME = "diag_socket_channel"

    /** Allowed command verbs the framework recognizes. */
    val VALID_COMMANDS = setOf("latest_diag_data", "all_diag_data")

    /**
     * Read a snapshot from the diag socket.
     *
     * @param command One of `latest_diag_data` (active faults only) or
     *                `all_diag_data` (active + historic).
     * @param timeoutMs Socket read/connect timeout in ms.
     * @return A list of decoded rows. Empty list = no faults (still a
     *         successful round-trip); a thrown exception = transport
     *         failure or unparseable response.
     */
    @Throws(Exception::class)
    fun readSnapshot(command: String, timeoutMs: Int): List<Map<String, Any?>> {
        require(command in VALID_COMMANDS) {
            "command must be one of $VALID_COMMANDS, got '$command'"
        }

        val raw: String
        val elapsedMs = measureTimeMillis {
            raw = sendAndReceive(command, timeoutMs)
        }
        Log.d(TAG, "diag '$command' returned ${raw.length} bytes in ${elapsedMs}ms")

        // Empty response is valid → no rows.
        if (raw.isEmpty()) return emptyList()

        return parseResponse(raw)
    }

    /**
     * Open the socket, send the command, drain the response. The
     * framework closes after one round trip; the read loop terminates
     * on EOF, not on a sentinel byte, so we just read until close.
     */
    private fun sendAndReceive(command: String, timeoutMs: Int): String {
        val socket = LocalSocket()
        try {
            socket.connect(
                LocalSocketAddress(SOCKET_NAME, LocalSocketAddress.Namespace.ABSTRACT)
            )
            socket.soTimeout = timeoutMs

            socket.outputStream.use { out ->
                out.write(command.toByteArray(Charsets.UTF_8))
                out.flush()
                // Important: do NOT shutdownOutput — the framework expects
                // the socket to remain bidirectional. Closing the write
                // half on some implementations triggers an early EPIPE.
            }

            // Drain everything until server closes its end. Use a buffered
            // reader so we can let the OS handle small reads efficiently.
            // A single response is usually a few KB on a healthy car,
            // but factory-default loads may exceed 100 KB.
            val sb = StringBuilder()
            BufferedReader(InputStreamReader(socket.inputStream, Charsets.UTF_8)).use { r ->
                val buf = CharArray(4096)
                while (true) {
                    val n = r.read(buf)
                    if (n <= 0) break
                    sb.append(buf, 0, n)
                }
            }
            return sb.toString()
        } finally {
            try { socket.close() } catch (_: Throwable) {}
        }
    }

    /**
     * Parse the @-separated row stream into a typed list of maps. We
     * deliberately *don't* filter by destination here — the caller may
     * want to see all rows for debugging. The Dart side applies any
     * UI-relevant filtering.
     */
    private fun parseResponse(raw: String): List<Map<String, Any?>> {
        // The server may or may not put a trailing '@'; tolerate either.
        val rows = raw.split('@').filter { it.isNotEmpty() }
        val out = ArrayList<Map<String, Any?>>(rows.size)

        for (row in rows) {
            val cols = row.split('#')
            // We expect 10 columns. Real firmware sometimes emits 9 or
            // 11 due to format drift; we degrade gracefully rather than
            // dropping the row entirely.
            if (cols.size < 4) {
                BydLogger.w(TAG, "skipping malformed row (cols=${cols.size}): $row")
                continue
            }

            val parsed = HashMap<String, Any?>(12)
            parsed["id"]          = cols.getOrNull(0)?.toLongOrNull()
            parsed["moduleType"]  = cols.getOrNull(1)?.toIntOrNull()
            parsed["moduleName"]  = cols.getOrNull(2)
            parsed["dtc"]         = cols.getOrNull(3)
            parsed["state"]       = cols.getOrNull(4)?.toIntOrNull()
            parsed["dest"]        = cols.getOrNull(5)?.toLongOrNull()
            parsed["diagType"]    = cols.getOrNull(6)?.toIntOrNull()
            parsed["describe"]    = cols.getOrNull(7)
            parsed["jsonData"]    = decodeJsonColumn(cols.getOrNull(8))
            parsed["recordTime"]  = cols.getOrNull(9)

            // Derived: is this row "active" (state == 0) AND addressed
            // to the head-unit consumer ((dest >> 8) & 0xF == 1)?
            val state = parsed["state"] as? Int
            val dest = parsed["dest"] as? Long
            parsed["isActiveFault"] = (state == 0)
            parsed["isForHeadUnit"] =
                dest != null && (((dest shr 8) and 0xFL) == 1L)

            out.add(parsed)
        }
        return out
    }

    /**
     * Decode the JSON-encoded column 8 into a clean list of {key,value}
     * pairs that Dart can consume directly. Returns an empty list on
     * any parse failure rather than propagating the exception — DTC
     * rows with weird JSON are common and shouldn't kill a snapshot.
     */
    private fun decodeJsonColumn(rawJson: String?): List<Map<String, String>> {
        if (rawJson.isNullOrBlank() || rawJson == "null") return emptyList()
        return try {
            val obj = JSONObject(rawJson)
            val arr = obj.optJSONArray("data") ?: return emptyList()
            val list = ArrayList<Map<String, String>>(arr.length())
            for (i in 0 until arr.length()) {
                val e = arr.optJSONObject(i) ?: continue
                list.add(mapOf(
                    "key"   to (e.optString("key", "")),
                    "value" to (e.optString("value", "")),
                ))
            }
            list
        } catch (t: Throwable) {
            BydLogger.w(TAG, "jsonData parse failed (${t.message}); raw='${rawJson.take(80)}…'")
            emptyList()
        }
    }
}
