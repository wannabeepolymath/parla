package dev.parla.android

import android.content.Context
import java.io.File
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject

/**
 * Safe Start: opt-in and off by default, as on desktop (NativePreparationView.swift). Every native load and
 * recognition is bracketed by a durable, model-bound marker. A marker that a later process still finds means
 * the earlier one died inside native work. Two such exits for one model pause that model. Nothing retries on its
 * own: only the user's explicit "Try loading once" (one load, no audio) or "Reset" lifts a pause.
 * The journal's existence is the on/off switch, so the setting and its records cannot disagree.
 */
internal class SafeStart(private val journal: DurableFile, private val launch: String = UUID.randomUUID().toString()) {
    /** [crashes]: model key to unresolved native exits. [detected]: this launch found an earlier one. */
    data class State(val enabled: Boolean = false, val crashes: Map<String,Int> = emptyMap(), val fault: Boolean = false, val detected: Boolean = false)
    class Refusal(message: String) : IllegalStateException(message)
    private val value = MutableStateFlow(State())
    val state = value.asStateFlow()
    private var pending: String? = null // The one native attempt in flight; NativeTasks is serial.

    init { open() }
    @Synchronized private fun open() {
        val bytes = try { journal.read(MAX_BYTES) ?: return } catch(_: Exception) { value.value = State(enabled = true,fault = true); return }
        value.value = try {
            val j = JSONObject(bytes.toString(Charsets.UTF_8))
            require(j.getInt("version") == 1)
            val c = j.getJSONObject("crashes")
            val crashes = c.keys().asSequence().associateWith { c.getInt(it).also { n -> require(n in 1..PAUSE_AFTER) } }
            require(crashes.size <= MAX_MODELS)
            val p = j.optJSONObject("pending")
            if(p != null && p.getString("launch") != launch) {
                val key = p.getString("key")
                val next = crashes + (key to minOf(PAUSE_AFTER,(crashes[key] ?: 0)+1))
                write(next,null)
                State(enabled = true,crashes = next,detected = true)
            } else State(enabled = true,crashes = crashes)
        } catch(_: Exception) { State(enabled = true,fault = true) }
    }
    fun crashes(model: SpeechModel) = value.value.crashes[model.key] ?: 0
    fun paused(model: SpeechModel) = value.value.enabled && crashes(model) >= PAUSE_AFTER
    /** On the native executor, immediately before native work. Null when Safe Start is off. */
    @Synchronized fun begin(model: SpeechModel, retry: Boolean = false): String? {
        val s = value.value
        if(!s.enabled) return null
        if(s.fault) throw Refusal(UNAVAILABLE)
        if(!retry && (s.crashes[model.key] ?: 0) >= PAUSE_AFTER) throw Refusal(PAUSED)
        check(pending == null) { "Wait for the speech model to finish loading." }
        try { write(s.crashes,model.key) } catch(_: Exception) { value.value = s.copy(fault = true); throw Refusal(UNAVAILABLE) }
        pending = model.key
        return model.key
    }
    /** Native work returned (completed, failed or canceled): this model did not take the process down. */
    @Synchronized fun end(mark: String?) {
        if(mark == null || pending != mark) return
        pending = null
        val s = value.value
        val next = s.crashes - mark
        value.value = try { write(next,null); s.copy(crashes = next) } catch(_: Exception) { s.copy(fault = true) }
    }
    /** Refused while native work is in flight, like desktop; turning off forgets every record. */
    @Synchronized fun setEnabled(on: Boolean): Boolean {
        if(pending != null) return false
        if(on == value.value.enabled && !value.value.fault) return true
        return try {
            if(on) write(emptyMap(),null) else journal.delete()
            value.value = State(enabled = on); true
        } catch(_: Exception) { false }
    }
    @Synchronized fun reset(): Boolean {
        if(pending != null || !value.value.enabled) return false
        return try { write(emptyMap(),null); value.value = State(enabled = true); true } catch(_: Exception) { false }
    }
    /** True once per launch that found an unfinished native attempt. */
    @Synchronized fun takeNotice(): Boolean = value.value.detected.also { if(it) value.value = value.value.copy(detected = false) }
    /** The user's explicit single load with no audio. A crash here counts like any other; a return clears the record. */
    suspend fun tryOnce(model: SpeechModel, file: File, native: SpeechNative = WhisperJni): Boolean = NativeTasks.run {
        ModelCatalog.verify(file,model)
        val mark = begin(model,retry = true)
        try { native.prepare(file.absolutePath.toByteArray(Charsets.UTF_8)) } finally { end(mark) }
    }
    private fun write(crashes: Map<String,Int>, pendingKey: String?) {
        val j = JSONObject().put("version",1).put("crashes",JSONObject(crashes))
        if(pendingKey != null) j.put("pending",JSONObject().put("key",pendingKey).put("launch",launch))
        journal.write(j.toString().toByteArray())
    }
    companion object {
        const val PAUSE_AFTER = 2
        private const val MAX_BYTES = 16_384
        private const val MAX_MODELS = 16
        const val PAUSED = "The speech model didn’t finish loading twice, so Safe Start paused it. Open Safe Start in Models."
        const val UNAVAILABLE = "Safe Start can’t save its records. Open Safe Start in Models."
        /** Set by the first [get]; MainActivity and ParlaService (the only native entry points) call it in onCreate. */
        @Volatile var current: SafeStart? = null
            private set
        fun get(context: Context): SafeStart = current ?: synchronized(this) {
            current ?: SafeStart(DurableFile(File(context.noBackupFilesDir,"safe-start.json"))).also { current = it }
        }
    }
}
