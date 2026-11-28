package dev.parla.android

/** Port of the desktop SubtitleExport: literal native segments only, never cleaned or history text. */
internal object SubtitleExport {
    enum class Format(val label: String, val extension: String, val mime: String) { webVTT("WebVTT", "vtt", "text/vtt"), srt("SRT", "srt", "application/x-subrip") }
    enum class Refusal { empty, payload, overflow, limit, markup }
    class Refused(val refusal: Refusal) : Exception(refusal.name)
    const val MAXIMUM_BYTES = 8 * 1_048_576
    private val markup = Regex("""[<>{}\\]|&[A-Za-z0-9#]+;""")

    /** 10 ms ticks to HH:MM:SS.mmm (hours keep growing past 99). */
    fun timestamp(tick: Long, separator: String = "."): String {
        if(tick < 0 || tick > Long.MAX_VALUE / 10) throw Refused(Refusal.overflow)
        val ms = tick * 10
        return "%02d:%02d:%02d%s%03d".format(java.util.Locale.ROOT, ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, separator, ms % 1000)
    }

    fun encode(cues: List<Cue>, format: Format, maximumBytes: Int = MAXIMUM_BYTES): String {
        if(cues.isEmpty()) throw Refused(Refusal.empty)
        val out = StringBuilder(); var bytes = 0L
        fun append(text: String) { bytes += utf8Bytes(text); if(bytes > maximumBytes) throw Refused(Refusal.limit); out.append(text) }
        var hasMarkup = false
        if(format == Format.webVTT) append("WEBVTT\n\n")
        val separator = if(format == Format.srt) "," else "."
        for((index, cue) in cues.withIndex()) {
            if(format == Format.srt && cue.end >= 36_000_000) throw Refused(Refusal.overflow)
            append("${index + 1}\n${timestamp(cue.start, separator)} --> ${timestamp(cue.end, separator)}\n")
            val text = cue.text.replace("\r\n", "\n").replace("\r", "\n")
            if(!text.split("\n").all { line -> line.isNotEmpty() && line.any { it != ' ' && it != '\t' } }) throw Refused(Refusal.payload)
            if(format == Format.srt && markup.containsMatchIn(text)) hasMarkup = true
            text.codePoints().forEach { n ->
                // Deliberately stricter product policy than WebVTT's bidi/control grammar.
                if((n < 0x20 && n != 9 && n != 10) || n in 0x7F..0x9F || n == 0x2028 || n == 0x2029 || n == 0x061C || n == 0x200E || n == 0x200F ||
                    n in 0x202A..0x202E || n in 0x2066..0x2069) throw Refused(Refusal.payload)
                append(when { format == Format.srt -> String(Character.toChars(n)); n == '&'.code -> "&amp;"; n == '<'.code -> "&lt;"; n == '>'.code -> "&gt;"; else -> String(Character.toChars(n)) })
            }
            append("\n\n")
        }
        // Shared payload, time and whole-byte checks take precedence.
        if(hasMarkup) throw Refused(Refusal.markup)
        return out.toString()
    }

    fun message(refusal: Refusal, format: Format) = when(refusal) {
        Refusal.empty -> "No timestamps for this file. Copy or save the text instead."
        Refusal.markup -> "This text has characters SRT can’t show. Export WebVTT instead."
        else -> "This text can’t be exported as ${format.label}. Copy or save it instead."
    }
}

/**
 * Desktop RecognitionExport `parla.recognition.v1`: one raw recognition result. Unknown stays null; nothing is
 * synthesized. Never includes the model path, prompts, settings or diagnostics.
 */
internal object RecognitionExport {
    const val SCHEMA = "parla.recognition.v1"
    fun encode(transcript: TimedTranscript, model: SpeechModel, requestedLanguage: String?, maximumBytes: Int = SubtitleExport.MAXIMUM_BYTES): String {
        val json = SortedJson.write(mapOf(
            "schema" to SCHEMA, "rawText" to transcript.text, "cleanedText" to null, "engine" to "whisper",
            "model" to mapOf("kind" to "catalog", "id" to model.id, "expectedSHA256" to model.sha256),
            // ponytail: the bridge does not report its native version, so runtime stays unknown.
            "runtime" to null,
            "language" to mapOf("requested" to requestedLanguage, "detected" to null),
            "source" to mapOf("sampleRate" to 16_000, "sampleCount" to transcript.sampleCount),
            "segments" to transcript.cues?.let { cues -> mapOf("clock" to "whisper-1.9.1-pcm-10ms", "cues" to cues.map { mapOf("text" to it.text, "start" to it.start, "end" to it.end) }) },
            "words" to null,
        ))
        if(utf8Bytes(json) > maximumBytes) throw SubtitleExport.Refused(SubtitleExport.Refusal.limit)
        return json
    }
    fun filename(now: Long) = "parla-recognition-${java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd").withZone(java.time.ZoneOffset.UTC).format(java.time.Instant.ofEpochMilli(now))}.json"
}

/** JSONSerialization with sortedKeys and withoutEscapingSlashes; values are String, Int/Long, Map, List or null. */
internal object SortedJson {
    fun write(value: Any?): String = StringBuilder().also { append(it, value) }.toString()
    private fun append(out: StringBuilder, value: Any?) {
        when(value) {
            null -> out.append("null")
            is String -> { out.append('"'); value.forEach { c -> when(c) {
                '"' -> out.append("\\\""); '\\' -> out.append("\\\\"); '\n' -> out.append("\\n"); '\r' -> out.append("\\r"); '\t' -> out.append("\\t")
                '\b' -> out.append("\\b"); '\u000C' -> out.append("\\f")
                else -> if(c < ' ') out.append("\\u%04x".format(c.code)) else out.append(c)
            } }; out.append('"') }
            is Int, is Long -> out.append(value.toString())
            is Map<*, *> -> { out.append('{'); value.entries.sortedBy { it.key as String }.forEachIndexed { i, (k, v) -> if(i > 0) out.append(','); append(out, k); out.append(':'); append(out, v) }; out.append('}') }
            is List<*> -> { out.append('['); value.forEachIndexed { i, v -> if(i > 0) out.append(','); append(out, v) }; out.append(']') }
            else -> error("Unsupported JSON value")
        }
    }
}
