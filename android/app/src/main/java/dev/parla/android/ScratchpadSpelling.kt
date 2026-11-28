package dev.parla.android

import android.icu.lang.UCharacter
import android.icu.lang.UProperty
import java.text.BreakIterator
import java.text.Normalizer
import java.util.Locale

/**
 * Desktop ScratchpadSpellingPolicy: deliberately orthographic, not a tokenizer, fuzzy corrector or spellchecker.
 * Only Parla's own scratchpad text is read. Offsets are UTF-16, like NSString.
 */
internal object ScratchpadSpelling {
    const val DOCUMENT_UNITS = 65_536
    const val TOKEN_UNITS = 128
    const val TOKEN_BYTES = 256
    const val ROWS = 10_000
    const val LIFETIME_MS = 30_000L
    const val READY = "Choose a single word of 3 to 64 characters."
    const val NO_WORD = "Tap into a word or select one whole word."
    const val FAILED = "Couldn’t change the spelling. Try again."
    class Refusal(message: String) : Exception(message)
    data class Token(val start: Int, val end: Int, val text: String)
    data class Choices(val outputs: List<String>, val more: Boolean)
    /** Inputs that invalidate an open choice when they change (desktop configuration signature). */
    data class Signature(val words: List<String>, val snippets: List<Snippet>, val rules: List<LiteralReplacement>)
    fun signature(data: LocalData) = Signature(data.dictionary,data.snippets,data.replacements)
    data class Request(val text: String, val start: Int, val end: Int, val token: Token, val choices: Choices, val signature: Signature, val issued: Long) {
        val deadline get() = issued+LIFETIME_MS
    }
    /** One replacement and the selection to restore afterwards. */
    data class Edit(val start: Int, val end: Int, val replacement: String, val expected: String, val selectionStart: Int, val selectionEnd: Int)

    private enum class Cluster { word, delimiter, poison }

    fun key(text: String) = nfc(nfc(text).lowercase(Locale.ROOT))
    private fun nfc(text: String) = Normalizer.normalize(text,Normalizer.Form.NFC)
    fun validUtf16(text: CharSequence): Boolean {
        var i = 0
        while(i < text.length) {
            val c = text[i]
            if(c.isHighSurrogate()) { if(i+1 >= text.length || !text[i+1].isLowSurrogate()) return false; i += 2 }
            else { if(c.isLowSurrogate()) return false; i++ }
        }
        return true
    }

    private fun type(c: Int) = Character.getType(c).toByte()
    private val LETTERS = setOf(Character.UPPERCASE_LETTER,Character.LOWERCASE_LETTER,Character.TITLECASE_LETTER,Character.MODIFIER_LETTER,Character.OTHER_LETTER)
    private val MARKS = setOf(Character.NON_SPACING_MARK,Character.COMBINING_SPACING_MARK,Character.ENCLOSING_MARK)
    /** Foundation CharacterSet.letters is L* and M*; nonBaseCharacters is M*. */
    private fun letter(c: Int) = type(c) in LETTERS || type(c) in MARKS
    private fun mark(c: Int) = type(c) in MARKS
    private fun selector(c: Int) = c in 0xFE00..0xFE0F || c in 0xE0100..0xE01EF
    private fun whitespace(c: Int) = c == 0x09 || c in 0x0A..0x0D || c == 0x85 || type(c) in setOf(Character.SPACE_SEPARATOR,Character.LINE_SEPARATOR,Character.PARAGRAPH_SEPARATOR)
    /** Unicode Default_Ignorable_Code_Point (DerivedCoreProperties). */
    private val IGNORABLE = listOf(0xAD..0xAD,0x34F..0x34F,0x61C..0x61C,0x115F..0x1160,0x17B4..0x17B5,0x180B..0x180F,0x200B..0x200F,0x202A..0x202E,
        0x2060..0x206F,0x3164..0x3164,0xFE00..0xFE0F,0xFEFF..0xFEFF,0xFFA0..0xFFA0,0xFFF0..0xFFF8,0x1BCA0..0x1BCA3,0x1D173..0x1D17A,0xE0000..0xE0FFF)
    private fun ignorable(c: Int) = IGNORABLE.any { c in it }
    // ponytail: ICU's Emoji property; JVM unit tests see the stub's false, the conservative (poison) branch.
    private fun emoji(c: Int) = UCharacter.hasBinaryProperty(c,UProperty.EMOJI)

    private fun cluster(text: String): Cluster {
        val s = text.codePoints().toArray()
        val orthographic = s.any { letter(it) || type(it) == Character.DECIMAL_DIGIT_NUMBER || type(it) == Character.CONNECTOR_PUNCTUATION }
        if(orthographic && s.any { ignorable(it) && it != 0x200C && it != 0x200D }) return Cluster.poison
        if(!orthographic) {
            val emoji = s.any { type(it) == Character.OTHER_SYMBOL && emoji(it) }
            // A mark attached to punctuation/space is not an attached word mark; emoji selectors/ZWJ stay a delimiter.
            if(s.any { c -> when {
                mark(c) -> !emoji || !selector(c)
                type(c) == Character.FORMAT -> !emoji || c != 0x200D
                else -> false
            } }) return Cluster.poison
        }
        var base = false; var letter = false
        for((i,c) in s.withIndex()) when(type(c)) {
            in LETTERS -> { base = true; letter = true }
            Character.DECIMAL_DIGIT_NUMBER, Character.CONNECTOR_PUNCTUATION -> base = true
            in MARKS -> if(selector(c)) return Cluster.poison
            // A joiner is allowed only inside a letter cluster, right after a mark and before another letter.
            Character.FORMAT -> if(!((c == 0x200C || c == 0x200D) && i > 0 && i+1 < s.size && mark(s[i-1]) && letter(s[i+1]))) return Cluster.poison
            Character.CONTROL -> return if(s.all(::whitespace)) Cluster.delimiter else Cluster.poison
            else -> {
                if(base || s.any(::letter)) return Cluster.poison
                // U+FFFC attachment, U+FFFD replacement and noncharacters aren't separators.
                if(c in 0xFFF0..0xFFFF) return Cluster.poison
                return Cluster.delimiter
            }
        }
        if(s.any { it == 0x200C || it == 0x200D } && !letter) return Cluster.poison
        return if(base) Cluster.word else Cluster.poison
    }

    /** Grapheme cluster boundaries, including 0 and the end. */
    private fun boundaries(text: String): IntArray {
        val iterator = BreakIterator.getCharacterInstance(Locale.ROOT).apply { setText(text) }
        return generateSequence(iterator.first()) { iterator.next().takeIf { it != BreakIterator.DONE } }.toList().toIntArray()
    }
    private fun graphemes(text: String) = boundaries(text).let { b -> (0 until b.size-1).map { text.substring(b[it],b[it+1]) } }

    fun admitted(text: String): Boolean {
        if(text.length > TOKEN_UNITS) return false
        val clusters = graphemes(text)
        return clusters.size in 3..64 && text.codePoints().anyMatch(::letter) && clusters.all { cluster(it) == Cluster.word }
    }

    /** The whole word at a caret, or exactly one selected word. Ambiguous compounds, poison neighbors and fragments are refused. */
    fun token(text: String, start: Int, end: Int): Token {
        if(text.isEmpty() || text.length > DOCUMENT_UNITS || start < 0 || end < start || end > text.length || !validUtf16(text)) throw Refusal(NO_WORD)
        val bounds = boundaries(text)
        fun boundary(offset: Int) = offset == text.length || bounds.binarySearch(offset) >= 0
        fun at(offset: Int): IntRange { val i = bounds.binarySearch(offset).let { if(it >= 0) it else -it-2 }; return bounds[i] until bounds[i+1] }
        fun kind(r: IntRange) = cluster(text.substring(r.first,r.last+1))
        if(!boundary(start) || !boundary(end) || (start == 0 && end == 0)) throw Refusal(NO_WORD)
        val anchor = if(start == end) start-1 else start
        if(anchor !in text.indices) throw Refusal(NO_WORD)
        var first = at(anchor).first; var last = at(anchor).last+1 // [first, last)
        if(kind(first until last) != Cluster.word) throw Refusal(NO_WORD)
        val leftLimit = maxOf(0,start-129); val rightLimit = minOf(text.length,end+129)
        while(first > 0) {
            val previous = at(first-1)
            if(previous.first < leftLimit) throw Refusal(NO_WORD)
            if(kind(previous) != Cluster.word) break
            first = previous.first
            if(last-first > TOKEN_UNITS) throw Refusal(NO_WORD)
        }
        while(last < text.length) {
            val next = at(last)
            if(next.last+1 > rightLimit) throw Refusal(NO_WORD)
            if(kind(next) != Cluster.word) break
            last = next.last+1
            if(last-first > TOKEN_UNITS) throw Refusal(NO_WORD)
        }
        if(if(start == end) !(start > first && start <= last) else (start != first || end != last)) throw Refusal(NO_WORD)
        // Ordinary punctuation (including a final period) delimits; identifier punctuation connecting words is ambiguous.
        for(direction in listOf(-1,1)) {
            var cursor = if(direction < 0) first else last
            var connected = false; var steps = 0
            while(if(direction < 0) cursor > 0 else cursor < text.length) {
                val neighbor = at(if(direction < 0) cursor-1 else cursor)
                steps += neighbor.last+1-neighbor.first
                if(steps > 129) throw Refusal(NO_WORD)
                val literal = text.substring(neighbor.first,neighbor.last+1); val type = kind(neighbor)
                if(type == Cluster.poison || (connected && type == Cluster.word)) throw Refusal(NO_WORD)
                if(!literal.all { it in COMPOUND }) break
                // Hanging apostrophe/dash/slash/@ are also conservatively refused.
                if(literal != "." && literal != ":") throw Refusal(NO_WORD)
                connected = true
                cursor = if(direction < 0) neighbor.first else neighbor.last+1
            }
        }
        val literal = text.substring(first,last)
        if(literal.toByteArray(Charsets.UTF_8).size > TOKEN_BYTES || !admitted(literal)) throw Refusal(NO_WORD)
        return Token(first,last,literal)
    }
    private const val COMPOUND = "'’ʼ-‐‑‒–—.@/\\:+"

    /** Dictionary words equal to [original] after NFC + lowercase, in dictionary order, at most five. The exact original is never offered. */
    fun candidates(original: String, words: List<String>): Choices {
        val tooLarge = "Your dictionary is too large for spelling suggestions."
        if(words.size > ROWS) throw Refusal(tooLarge)
        val match = key(original); val outputs = mutableListOf<String>(); val keys = mutableListOf<String>()
        var noOp: String? = null; var more = false; var bytes = 0
        for(word in words) {
            val size = minOf(word.toByteArray(Charsets.UTF_8).size,TOKEN_BYTES+1)
            bytes += size
            if(bytes > ROWS*(TOKEN_BYTES+1)) throw Refusal(tooLarge)
            if(size > TOKEN_BYTES || !admitted(word) || key(word) != match) continue
            val canonical = nfc(word)
            if(canonical == noOp || canonical in keys) continue
            if(word == original) { noOp = canonical; continue }
            if(outputs.size < 5) { outputs += word; keys += canonical } else more = true
        }
        return Choices(outputs,more)
    }

    /** Explicit action on the scratchpad's own text and selection. Returns the choices to present. */
    fun begin(text: String, start: Int, end: Int, data: LocalData, now: Long): Request {
        if(text.length > DOCUMENT_UNITS) throw Refusal("Tap into a word in the scratchpad first.")
        val token = token(text,minOf(start,end),maxOf(start,end))
        val choices = candidates(token.text,data.dictionary)
        if(choices.outputs.isEmpty()) throw Refusal("No dictionary spelling matches this word.")
        return Request(text,minOf(start,end),maxOf(start,end),token,choices,signature(data),now)
    }

    /** The choice still applies only to the same text, selection and dictionary, within 30 seconds. */
    fun choose(request: Request, candidate: String, text: String, start: Int, end: Int, enabled: Boolean, data: LocalData, now: Long): Edit? {
        if(!enabled || now !in request.issued until request.deadline || signature(data) != request.signature || candidate !in request.choices.outputs
            || text != request.text || minOf(start,end) != request.start || maxOf(start,end) != request.end || candidate == request.token.text) return null
        val t = request.token
        val expected = text.substring(0,t.start)+candidate+text.substring(t.end)
        if(expected.length > DOCUMENT_UNITS || !validUtf16(expected)) return null
        val after = t.start+candidate.length
        return if(request.start == request.end) Edit(t.start,t.end,candidate,expected,after,after) else Edit(t.start,t.end,candidate,expected,t.start,after)
    }
}
