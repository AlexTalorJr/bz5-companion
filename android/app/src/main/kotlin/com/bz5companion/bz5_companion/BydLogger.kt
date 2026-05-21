package com.bz5companion.bz5_companion

import android.util.Log
import java.util.ArrayDeque

/**
 * Drop-in replacement for [android.util.Log] that also writes every
 * message into an in-process ring buffer.
 *
 * Why: on locked-down BZ5 head units we cannot reliably get ADB access,
 * so logcat is invisible to us. The Native Explorer screen polls this
 * ring buffer to surface what `adb logcat` would have shown.
 *
 * Capacity: 500 entries (~50 KB worst case, ~10 KB typical). When full,
 * oldest entries are dropped. The ring is process-global — survives
 * plugin re-attach (hot restart) so the user can review the last
 * session's logs after a Flutter rebuild.
 *
 * Thread-safety: all mutators are synchronized; reads acquire the same
 * lock and copy out. Calls from main thread, background threads, and
 * binder threads all interleave correctly.
 *
 * Levels: V/D are dropped from the ring at runtime by default to keep
 * it useful (Android verbose channels otherwise drown out the
 * interesting events). I/W/E are always kept. The platform-side
 * `android.util.Log` call still goes through at every level so a
 * future adb session can see the full picture.
 */
object BydLogger {
    private const val CAPACITY = 500
    private val ring = ArrayDeque<Entry>(CAPACITY)
    private val lock = Object()

    data class Entry(
        val ts: Long,        // System.currentTimeMillis()
        val level: Char,     // V D I W E
        val tag: String,
        val message: String,
        val throwableSummary: String?,  // first 6 stack frames if Throwable was passed
    )

    fun v(tag: String, msg: String) { Log.v(tag, msg) }   // intentionally NOT kept in ring
    fun d(tag: String, msg: String) { Log.d(tag, msg) }   // ditto

    fun i(tag: String, msg: String) {
        Log.i(tag, msg)
        push('I', tag, msg, null)
    }

    fun w(tag: String, msg: String) {
        Log.w(tag, msg)
        push('W', tag, msg, null)
    }

    fun w(tag: String, msg: String, t: Throwable) {
        Log.w(tag, msg, t)
        push('W', tag, msg, summarize(t))
    }

    fun e(tag: String, msg: String) {
        Log.e(tag, msg)
        push('E', tag, msg, null)
    }

    fun e(tag: String, msg: String, t: Throwable) {
        Log.e(tag, msg, t)
        push('E', tag, msg, summarize(t))
    }

    private fun push(level: Char, tag: String, message: String, summary: String?) {
        synchronized(lock) {
            if (ring.size == CAPACITY) ring.pollFirst()
            ring.add(Entry(System.currentTimeMillis(), level, tag, message, summary))
        }
    }

    private fun summarize(t: Throwable): String {
        val sb = StringBuilder()
        sb.append(t.javaClass.simpleName)
        t.message?.let { sb.append(": ").append(it) }
        val stack = t.stackTrace
        val limit = minOf(stack.size, 6)
        for (i in 0 until limit) {
            sb.append("\n  at ").append(stack[i])
        }
        if (stack.size > limit) sb.append("\n  ... +${stack.size - limit} more")
        return sb.toString()
    }

    /**
     * Returns up to [count] most-recent entries (newest last).
     * If [sinceTs] is non-null, only entries strictly newer than that
     * millisecond timestamp are returned (useful for incremental pulls).
     */
    fun pull(count: Int, sinceTs: Long?): List<Map<String, Any?>> {
        val snapshot: List<Entry> = synchronized(lock) { ring.toList() }
        val filtered = if (sinceTs == null) snapshot else snapshot.filter { it.ts > sinceTs }
        val tail = if (filtered.size <= count) filtered else filtered.subList(filtered.size - count, filtered.size)
        return tail.map {
            mapOf(
                "ts"      to it.ts,
                "level"   to it.level.toString(),
                "tag"     to it.tag,
                "message" to it.message,
                "throwable" to it.throwableSummary,
            )
        }
    }

    fun clear() {
        synchronized(lock) { ring.clear() }
    }

    fun size(): Int = synchronized(lock) { ring.size }
}
