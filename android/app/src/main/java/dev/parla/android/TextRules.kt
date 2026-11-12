package dev.parla.android

import java.util.Locale
import java.text.Normalizer

private val graphemes = Regex("\\X")
private val whitespace = Regex("[\\p{Z}\\s\\u0085]+")
internal fun String.countCharacters() = graphemes.findAll(this).count()
private fun String.canonical() = Normalizer.normalize(this, Normalizer.Form.NFC)

object VocabularyHints {
    fun move(words: List<String>, index: Int, delta: Int): List<String> {
        val target = index+delta
        if(index !in words.indices || target !in words.indices || delta !in setOf(-1,1)) return words
        return words.toMutableList().apply { add(target,removeAt(index)) }
    }
    fun select(words: List<String>, byteLimit: Int): List<String> {
        val seen = mutableSetOf<String>(); var used = 0
        return words.mapNotNull { raw ->
            val word = raw.trim().split(whitespace).joinToString(" ")
            val bytes = word.toByteArray(Charsets.UTF_8).size
            if (word.isEmpty() || bytes > 256 || !seen.add(word.lowercase(Locale.ROOT).canonical())) null
            else if (used + bytes + (if (used == 0) 0 else 2) > byteLimit) null
            else { used += bytes + if (used == 0) 0 else 2; word }
        }
    }
    fun asrPrompt(words: List<String>) = select(words, 2048).joinToString(", ")
}

enum class AppCategory { terminal, code, chat, email, prose, unknown }
object TextRules {
    // Exact package mapping stays on device. Browsers without trusted URL metadata are unknown.
    fun category(pkg: String?): AppCategory = when(pkg) {
        "com.termux", "jackpal.androidterm" -> AppCategory.terminal
        "com.discord", "com.Slack", "com.whatsapp", "org.telegram.messenger", "com.google.android.apps.messaging", "com.microsoft.teams" -> AppCategory.chat
        "com.google.android.gm", "com.microsoft.office.outlook", "ch.protonmail.android", "com.readdle.spark" -> AppCategory.email
        "com.microsoft.office.word", "md.obsidian", "notion.id", "com.google.android.keep", "com.openai.chatgpt" -> AppCategory.prose
        "com.foxdebug.acode", "io.spck" -> AppCategory.code
        else -> AppCategory.unknown
    }
    fun shape(text: String, category: AppCategory, singleLine: Boolean): String = if (singleLine || category == AppCategory.terminal || category == AppCategory.chat) text.replace(Regex("\\s*\\n\\s*"), " ").trim() else text
    fun snippetExpansion(text: String, snippets: List<Snippet>): String? {
        val key = WER.normalize(text)
        if (key.isEmpty()) return null
        return snippets.filter { WER.normalize(it.trigger) == key }.sortedWith(compareByDescending<Snippet> { it.trigger.countCharacters() }.thenBy { it.trigger.canonical() }).firstOrNull()?.expansion
    }
    private fun word(cp: Int) = Character.isLetterOrDigit(cp) || Character.getType(cp) in setOf(Character.NON_SPACING_MARK.toInt(), Character.COMBINING_SPACING_MARK.toInt(), Character.ENCLOSING_MARK.toInt(), Character.CONNECTOR_PUNCTUATION.toInt())
    fun replace(text: String, rules: List<LiteralReplacement>): String {
        val sorted = rules.filter { it.source.isNotEmpty() }.sortedByDescending { it.source.countCharacters() }
            .map { it to graphemes.findAll(it.source).map { part -> part.value }.toList() }
        val characters = graphemes.findAll(text).toList()
        val out = StringBuilder(); var i = 0
        while (i < characters.size) {
            val start = characters[i].range.first
            val match = sorted.firstOrNull { (r, parts) ->
                if (i + parts.size > characters.size) false else {
                    val end = characters[i + parts.size - 1].range.last + 1
                    text.substring(start, end).canonical() == r.source.canonical() &&
                        (!parts.first().codePoints().anyMatch { word(it) } || start == 0 || !word(text.codePointBefore(start))) &&
                        (!parts.last().codePoints().anyMatch { word(it) } || end == text.length || !word(text.codePointAt(end)))
                }
            }
            if (match != null) { out.append(match.first.replacement); i += match.second.size }
            else { out.append(characters[i].value); i++ }
        }
        return out.toString()
    }
    fun stripNonSpeech(text: String): String {
        if (text.replace(Regex("\\[[^\\]]*\\]|\\([^)]*\\)|\\*[^*]*\\*"), " ").isBlank()) return ""
        return text.trim().split(Regex("\\s+")).filterNot { w -> w.length > 3 && when(w.firstOrNull()) { '[' -> w.endsWith(']'); '(' -> w.endsWith(')'); '*' -> w.endsWith('*'); else -> false } }.joinToString(" ")
    }
    fun wordCount(text: String) = text.trim().split(Regex("\\s+")).count { it.isNotBlank() }
}

/** Port of Eval.werTokens: conservative English number grammar, never guess years. */
object WER {
    private val numbers = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety".split(" ").mapIndexed { i,w -> w to if(i < 20) i.toLong() else (i-18)*10L }.toMap()
    private val scales = mapOf("thousand" to 1000L, "million" to 1000000L, "billion" to 1000000000L)
    private val ordinals = "first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth thirteenth fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth twentieth thirtieth fortieth fiftieth sixtieth seventieth eightieth ninetieth hundredth thousandth".split(" ").zip("one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred thousand".split(" ")).toMap()
    fun normalize(source: String): String {
        var text = java.text.Normalizer.normalize(source,java.text.Normalizer.Form.NFC).replace('’', '\'').replace('‘', '\'').replace('“','"').replace('”','"').replace(Regex("(?<=[0-9]),(?=[0-9])"), "")
        for ((symbol, name) in mapOf("$" to "dollar", "£" to "pound", "€" to "euro")) text = text.replace(Regex(Regex.escape(symbol) + "([0-9][0-9.]*)")) { "${it.groupValues[1]} $name" }
        val t = text.lowercase(Locale.ROOT).split(Regex("[^\\p{L}\\p{N}\\p{M}']+")).map { it.trim('\'') }.filter { it.isNotEmpty() }.map { w -> ordinals[w] ?: mapOf("dollars" to "dollar", "pounds" to "pound", "euros" to "euro")[w] ?: if(Regex("[0-9]+(st|nd|rd|th)").matches(w)) w.dropLast(2) else w }
        fun sub(start: Int): Pair<Long,Int>? {
            val v = numbers[t.getOrNull(start)] ?: return null
            val unit = numbers[t.getOrNull(start+1)]
            return if(v >= 20 && unit != null && unit in 1..9) v+unit to start+2 else v to start+1
        }
        fun group(start: Int): Pair<Long,Int>? {
            val first = sub(start) ?: return null
            if(t.getOrNull(first.second) != "hundred") return first
            var i = first.second+1
            if(t.getOrNull(i) == "and" && numbers.containsKey(t.getOrNull(i+1))) i++
            val rest = sub(i)
            return first.first*100 + (rest?.first ?: 0) to (rest?.second ?: i)
        }
        val out = mutableListOf<String>(); var cursor = 0
        while(cursor < t.size) {
            var i = cursor; var total = 0L; var last = Long.MAX_VALUE; var complete: Pair<Long,Int>? = null
            while(true) {
                val g = group(i) ?: break
                val scale = scales[t.getOrNull(g.second)]
                if(scale != null) {
                    if(scale >= last) break
                    total += g.first*scale; last = scale; i = g.second+1; complete = total to i
                    if(t.getOrNull(i) == "and" && numbers.containsKey(t.getOrNull(i+1))) i++
                } else { if(g.first < last) complete = total+g.first to g.second; break }
            }
            if(complete != null) { out.add(complete.first.toString()); cursor = complete.second } else { out.add(t[cursor]); cursor++ }
        }
        return out.joinToString(" ")
    }
}
