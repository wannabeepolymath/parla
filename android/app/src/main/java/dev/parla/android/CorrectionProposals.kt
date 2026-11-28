package dev.parla.android

import android.content.Context
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.io.File
import java.util.Locale
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

/** One word the user replaced in text parla had just inserted. [key] is the case-insensitive dedupe/dismissal identity. */
internal data class CorrectionProposal(val from: String, val to: String, val at: Long) {
    val key get() = from.lowercase(Locale.ROOT) + "→" + to.lowercase(Locale.ROOT)
}

/**
 * Port of Mac DictionaryLearner. A dictionary entry biases every later dictation, so the bias is hard toward
 * false negatives, and nothing here is ever applied: the user adds or dismisses each proposal.
 */
internal object DictionaryLearner {
    private val LENGTH = 3..24
    private const val MAX_DISTANCE_RATIO = 0.65
    private val clusters = Regex("\\X")
    private val whitespace = Regex("(?U)\\s+")
    private class Token(val word: String, val canon: String)

    private fun tokens(s: String) = s.split(whitespace).mapNotNull { chunk ->
        val canon = WER.normalize(chunk)
        if (canon.isEmpty()) null else Token(chunk.trim { !it.isLetterOrDigit() }, canon)
    }
    private fun graphemes(s: String) = clusters.findAll(s).map { it.value }.toList()

    /** The single word that changed between two versions of a field, or null for any other edit. */
    private fun singleSubstitution(before: String, after: String): Pair<Token, Token>? {
        val b = tokens(before); val a = tokens(after)
        if (b.isEmpty() || b.size != a.size) return null
        var head = 0
        while (head < b.size && b[head].canon == a[head].canon) head++
        if (head == b.size) return null
        var tail = b.size - 1
        while (tail > head && b[tail].canon == a[tail].canon) tail--
        return if (tail == head) b[head] to a[head] else null
    }

    /** Letters, with ' and - allowed inside. Rejects numbers, emails, paths, code and emoji. */
    private fun wordlike(s: String): Boolean {
        val points = s.codePoints().toArray()
        if (points.isEmpty() || !Character.isLetter(points[0])) return false
        return points.all { Character.isLetter(it) || it == '\''.code || it == '-'.code || Character.getType(it) == Character.NON_SPACING_MARK.toInt() }
    }

    private fun distance(a: List<String>, b: List<String>): Int {
        var prev = IntArray(b.size + 1) { it }
        for (i in 1..a.size) {
            val cur = IntArray(b.size + 1); cur[0] = i
            for (j in 1..b.size) cur[j] = if (a[i - 1] == b[j - 1]) prev[j - 1] else minOf(prev[j - 1], prev[j], cur[j - 1]) + 1
            prev = cur
        }
        return prev[b.size]
    }

    /** [inserted]: what parla wrote. [before]: the field right after that write. [after]: the field once the user paused. */
    fun propose(inserted: String, before: String, after: String, dictionary: List<String>, now: Long = System.currentTimeMillis()): CorrectionProposal? {
        val (from, to) = singleSubstitution(before, after) ?: return null
        // The changed word must be one parla wrote, not the user fixing older text in the same field.
        if (tokens(inserted).none { it.canon == from.canon }) return null
        val a = from.word; val b = to.word
        if (a.countCharacters() !in LENGTH || b.countCharacters() !in LENGTH || !wordlike(a) || !wordlike(b)) return null
        val known = dictionary.map { it.lowercase(Locale.ROOT) }.toSet()
        if (a.lowercase(Locale.ROOT) in known || b.lowercase(Locale.ROOT) in known) return null
        val ga = graphemes(a.lowercase(Locale.ROOT)); val gb = graphemes(b.lowercase(Locale.ROOT))
        val d = distance(ga, gb)
        if (d == 0 || d > MAX_DISTANCE_RATIO * maxOf(ga.size, gb.size)) return null
        return CorrectionProposal(a, b, now)
    }
}

/** Pending proposals and one-time dismissals, private to this device. Mac dictionary-proposals.json. */
internal class ProposalBook(private val file: DurableFile) {
    private val mutable = MutableStateFlow<List<CorrectionProposal>>(emptyList())
    val pending = mutable.asStateFlow()
    private var dismissed = listOf<String>()

    init {
        runCatching {
            val root = JSONObject(file.read(MAX_BYTES)?.toString(Charsets.UTF_8) ?: return@runCatching)
            val rows = root.getJSONArray("pending")
            mutable.value = (0 until rows.length()).map { rows.getJSONObject(it).let { o -> CorrectionProposal(o.getString("from"), o.getString("to"), o.getLong("at")) } }
            val keys = root.getJSONArray("dismissed")
            dismissed = (0 until keys.length()).map { keys.getString(it) }
        }
    }

    /** False when already pending or dismissed once before: one "no" is final. */
    @Synchronized fun add(proposal: CorrectionProposal): Boolean {
        if (proposal.key in dismissed || mutable.value.any { it.key == proposal.key }) return false
        mutable.value = (mutable.value + proposal).takeLast(CAP)
        save(); return true
    }

    @Synchronized fun resolve(proposal: CorrectionProposal, dismiss: Boolean) {
        mutable.value = mutable.value.filterNot { it.key == proposal.key }
        if (dismiss && proposal.key !in dismissed) dismissed = (dismissed + proposal.key).takeLast(DISMISSED_CAP)
        save()
    }

    private fun save() {
        val root = JSONObject().put("pending", JSONArray(mutable.value.map { JSONObject().put("from", it.from).put("to", it.to).put("at", it.at) }))
            .put("dismissed", JSONArray(dismissed))
        runCatching { file.write(root.toString().toByteArray(Charsets.UTF_8)) } // Mac: try?. A lost proposal costs one suggestion.
    }

    companion object {
        const val CAP = 20
        const val DISMISSED_CAP = 200
        private const val MAX_BYTES = 256 * 1024
        @Volatile private var instance: ProposalBook? = null
        fun get(context: Context): ProposalBook = instance ?: synchronized(this) {
            instance ?: ProposalBook(DurableFile(File(context.applicationContext.filesDir, "dictionary-proposals.json"))).also { instance = it }
        }
    }
}

/** Dictionary-screen review. Nothing is learned without an explicit Add. */
@Composable internal fun CorrectionProposalsSection(words: List<String>, onAdd: (String) -> Boolean) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val book = remember { ProposalBook.get(context) }
    val pending by book.pending.collectAsState()
    if (pending.isEmpty()) return
    Column(Modifier.padding(horizontal = 16.dp)) {
        Text("Suggested", style = MaterialTheme.typography.titleMedium)
        Text("You corrected these after parla inserted them. Add the ones you want parla to learn.", fontSize = 12.sp)
        pending.forEach { p ->
            Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) { Text(p.to); Text("parla wrote “${p.from}”", fontSize = 12.sp) }
                val known = words.any { it.equals(p.to, true) }
                TextButton(onClick = { if (known || onAdd(p.to)) book.resolve(p, dismiss = false) }, enabled = known || words.size < 1000) { Text("Add") }
                TextButton(onClick = { book.resolve(p, dismiss = true) }) { Text("Dismiss") }
            }
        }
        HorizontalDivider()
    }
}
