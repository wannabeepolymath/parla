package dev.parla.android

import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** Mac SegmentedRetryFailure. Only fixed copy reaches the UI; a provider reason comes from Pipeline's safe set. */
internal class SegmentedFailure(val reason: Reason, detail: String? = null) : Exception(detail ?: reason.message) {
    enum class Reason(val message: String) {
        source("Cleanup didn’t finish. Try again."), previous("Cleanup didn’t finish. Try again."), rules("Cleanup didn’t finish. Try again."),
        plan("Cleanup didn’t finish. Try again."), request("Cleanup didn’t finish. Try again."), output("Cleanup didn’t finish. Try again."),
        provider("Cleanup didn’t finish. Try again."),
        singleSegment("This text is short enough. Use Clean up original instead."),
        snippets("Text with snippets can’t be cleaned up in sections. Use Clean up original instead."),
        configuration("Choose an exact text cleanup model in API connection first."),
        deadline("Cleanup took too long. Try again."),
    }
}

private const val SEGMENT_BYTES = 4096
private fun fail(reason: SegmentedFailure.Reason): Nothing = throw SegmentedFailure(reason)
internal fun utf8Bytes(text: String) = text.toByteArray(Charsets.UTF_8).size
/** Unicode White_Space, as Swift's Character.isWhitespace uses. */
private fun whitespace(c: Int) = c in 9..13 || c == 32 || c == 0x85 || c == 0xA0 || c == 0x1680 || c in 0x2000..0x200A || c in 0x2028..0x2029 || c == 0x202F || c == 0x205F || c == 0x3000
private fun newline(c: Int) = c in 10..13 || c == 0x85 || c == 0x2028 || c == 0x2029
private fun utf8Size(c: Int) = when { c < 0x80 -> 1; c < 0x800 -> 2; c < 0x10000 -> 3; else -> 4 }

/**
 * Port of HistoryRetrySegmentPlan v1. Offsets belong to this exact immutable [original]; whitespace separators
 * are never sent and never normalized. Content is at most 4096 UTF-8 bytes; at most 16 sections; at least 2.
 * ponytail: scans code points, not grapheme clusters; splits only happen at whitespace, so content never splits a cluster.
 */
internal class SegmentPlan(val original: String) {
    /** content is [start, end); its separator is [end, separatorEnd). */
    data class Segment(val start: Int, val end: Int, val separatorEnd: Int)
    val leading: Int
    val segments: List<Segment>
    init {
        if(original.isEmpty() || utf8Bytes(original) > 64 * 1024) fail(SegmentedFailure.Reason.source)
        val n = original.length
        fun at(i: Int) = original.codePointAt(i)
        var cursor = 0
        while(cursor < n && whitespace(at(cursor))) cursor += Character.charCount(at(cursor))
        leading = cursor
        val planned = mutableListOf<Segment>()
        while(cursor < n) {
            if(planned.size >= 16) fail(SegmentedFailure.Reason.plan)
            val start = cursor
            var bytes = 0; var scan = start; var finalContent = start
            var paragraph: IntRange? = null; var punctuation: IntRange? = null; var space: IntRange? = null
            while(scan < n) {
                val c = at(scan)
                if(whitespace(c)) {
                    val begin = scan; var end = scan; var runBytes = 0; var newlines = 0
                    while(end < n && whitespace(at(end))) {
                        val w = at(end)
                        runBytes += utf8Size(w)
                        // Swift counts "\r\n" as one newline Character.
                        if(newline(w) && !(w == 13 && end + 1 < n && original[end + 1] == '\n')) newlines++
                        end += Character.charCount(w)
                    }
                    // A complete run can be an exact separator even if large.
                    if(bytes <= SEGMENT_BYTES) {
                        val range = begin until end
                        space = range
                        if(bytes >= SEGMENT_BYTES / 2) {
                            if(newlines >= 2) paragraph = range
                            if(begin > start && original.codePointBefore(begin) in setOf('.'.code, '!'.code, '?'.code)) punctuation = range
                        }
                    }
                    if(end == n) { finalContent = begin; scan = end; break }
                    if(runBytes > SEGMENT_BYTES - bytes) break
                    bytes += runBytes; scan = end
                } else {
                    val size = utf8Size(c)
                    if(size > SEGMENT_BYTES - bytes) break
                    bytes += size; scan += Character.charCount(c); finalContent = scan
                }
            }
            val segment = if(scan == n) Segment(start, finalContent, n) else {
                val split = paragraph ?: punctuation ?: space
                if(split == null || split.first <= start) fail(SegmentedFailure.Reason.plan)
                Segment(start, split.first, split.last + 1)
            }
            if(segment.end <= segment.start || utf8Bytes(original.substring(segment.start, segment.end)) > SEGMENT_BYTES) fail(SegmentedFailure.Reason.plan)
            planned += segment; cursor = segment.separatorEnd
        }
        if(planned.isEmpty()) fail(SegmentedFailure.Reason.source)
        if(planned.size < 2) fail(SegmentedFailure.Reason.singleSegment)
        segments = planned
    }
    fun content(s: Segment) = original.substring(s.start, s.end)
    fun separator(s: Segment) = original.substring(s.end, s.separatorEnd)
    fun reconstructed() = original.substring(0, leading) + segments.joinToString("") { content(it) + separator(it) }
}

/**
 * Mac SegmentedOriginalReview + run: frozen settings, one 60-second budget, sequential bounded requests,
 * no failover, and a single all-or-nothing result. Any failed section discards every section.
 */
internal class SegmentedRetry(val source: HistoryEntry, data: LocalData) {
    val frozen: LocalData = data.copy(settings = data.settings.copy(outputMode = "cleanup"))
    private val locked = TextRules.snippetExpansion(source.raw, frozen.snippets)
    /** Local rules only: a locked snippet or AI cleanup off. Nothing is sent. */
    val deterministic = locked != null || !frozen.settings.cleanupEnabled
    val plan: SegmentPlan?
    init {
        val raw = source.raw
        if(raw.isEmpty() || utf8Bytes(raw) > 64 * 1024 || raw.all { it.isWhitespace() }) fail(SegmentedFailure.Reason.source)
        if(utf8Bytes(source.text) > 128 * 1024) fail(SegmentedFailure.Reason.previous)
        if(frozen.dictionary.size > 256 || frozen.snippets.size > 256 || frozen.replacements.size > 256) fail(SegmentedFailure.Reason.rules)
        val ruleBytes = frozen.dictionary.sumOf(::utf8Bytes) + frozen.snippets.sumOf { utf8Bytes(it.trigger) + utf8Bytes(it.expansion) } +
            frozen.replacements.sumOf { utf8Bytes(it.source) + utf8Bytes(it.replacement) }
        if(ruleBytes > 64 * 1024) fail(SegmentedFailure.Reason.rules)
        if(locked != null && utf8Bytes(locked) > 128 * 1024) fail(SegmentedFailure.Reason.output)
        if(!deterministic) {
            if(frozen.snippets.isNotEmpty()) fail(SegmentedFailure.Reason.snippets)
            val e = runCatching { frozen.settings.endpoint() }.getOrNull() ?: fail(SegmentedFailure.Reason.configuration)
            // An empty model would make an extra model-list request; segmented cleanup needs an exact model.
            if(e.baseUrl.length > 4096 || e.model.isBlank() || utf8Bytes(e.model) > 160) fail(SegmentedFailure.Reason.configuration)
        }
        plan = if(deterministic) null else SegmentPlan(raw)
    }
    val planned get() = plan?.segments?.size ?: 0
    val disclosure: String get() {
        val scope = if(deterministic) "Uses local rules only; nothing is sent online." else frozen.settings.endpoint().let { e ->
            "At most $planned requests to ${e.label} (${e.baseUrl.toHttpUrlOrNull()?.host ?: "unconfigured address"}, model ${e.model}). This may incur charges."
        }
        return "Long text is cleaned up one section at a time. $scope Check the result before saving."
    }

    data class Outcome(val text: String, val usage: CleanupUsage?, val summary: String)

    suspend fun run(key: (String) -> String, pipeline: Pipeline = Pipeline()): Outcome =
        withTimeoutOrNull(BUDGET_MS) { execute(key, pipeline) } ?: fail(SegmentedFailure.Reason.deadline)

    private suspend fun execute(key: (String) -> String, pipeline: Pipeline): Outcome {
        val raw = source.raw
        fun bounded(text: String) = text.also { if(utf8Bytes(it) > 128 * 1024) fail(SegmentedFailure.Reason.output) }
        if(locked != null) return Outcome(locked, null, "Uses an exact snippet. Nothing was sent online.")
        if(deterministic) return Outcome(bounded(TextRules.replace(raw, frozen.replacements)), null, "Uses local rules only. Nothing was sent online.")
        val plan = plan ?: fail(SegmentedFailure.Reason.plan)
        // Sections never rematch snippets (none are allowed) and literal rules run once over the assembled text.
        val sectionData = frozen.copy(snippets = emptyList(), replacements = emptyList())
        val system = utf8Bytes(PromptBuilder.system(sectionData, AppCategory.unknown, false))
        // Every request's framing is checked before the first one is sent.
        if(plan.segments.any { system + utf8Bytes(PromptBuilder.user(plan.content(it))) > 16 * 1024 }) fail(SegmentedFailure.Reason.request)
        val assembled = StringBuilder(raw.substring(0, plan.leading))
        val usages = mutableListOf<CleanupUsage?>()
        for((index, segment) in plan.segments.withIndex()) {
            val content = plan.content(segment)
            val result = pipeline.clean(content, sectionData, failover = null, key = key)
            result.warning?.let { throw SegmentedFailure(SegmentedFailure.Reason.provider, "Section ${index + 1} of $planned: " + it.removeSuffix(" · original preserved").trimEnd('.') + ". Nothing was changed.") }
            if(utf8Bytes(result.text) > 16 * 1024) fail(SegmentedFailure.Reason.output)
            assembled.append(result.text).append(plan.separator(segment))
            bounded(assembled.toString())
            usages += result.usage
        }
        val joined = assembled.toString()
        if(cleanupLengthFailure(raw, joined, emptyList()) != null) fail(SegmentedFailure.Reason.output)
        val text = bounded(TextRules.replace(joined, frozen.replacements))
        return Outcome(text, usage(usages), "Cleaned up in $planned sections with your current settings for general text. Nothing inserted into an app.")
    }

    companion object {
        const val BUDGET_MS = 60_000L
        /** Mac finish(): totals only when every request reported them; differing response models are never priced. */
        fun usage(attempts: List<CleanupUsage?>): CleanupUsage? {
            if(attempts.isEmpty() || attempts.all { it?.input == null && it?.output == null }) return null
            fun total(pick: (CleanupUsage) -> Int?): Int? {
                var sum = 0L
                for(u in attempts) sum += u?.let(pick) ?: return null
                return sum.takeIf { it <= Int.MAX_VALUE }?.toInt()
            }
            val mixed = attempts.mapNotNull { it?.model }.distinct().size > 1
            return CleanupUsage(if(mixed) "Mixed response models; usage not priced" else "Experimental response usage; model identity unverified", total { it.input }, total { it.output })
        }
    }
}
