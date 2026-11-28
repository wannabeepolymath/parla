package dev.parla.android

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener

/** Desktop `parla-vocabulary` v1. Intentionally separate from app data: no credentials, provider or device fields. */
internal data class VocabularyDocument(val words: List<String>, val snippets: Map<String,String>, val replacements: List<LiteralReplacement>) {
    val isEmpty get() = words.isEmpty() && snippets.isEmpty() && replacements.isEmpty()

    fun validate() {
        fun bytes(s: String) = s.toByteArray(Charsets.UTF_8).size
        invalid(words.size + snippets.size + replacements.size <= MAX_ENTRIES, "This file has more than 10,000 entries.")
        invalid(words.all { normalized(it).isNotEmpty() && bytes(it) <= MAX_HINT_BYTES }, "A word in this file is empty or too long.")
        invalid(snippets.all { (k,v) -> k.isNotBlank() && bytes(k) <= MAX_HINT_BYTES && bytes(v) <= MAX_TEXT_BYTES } &&
            replacements.all { it.source.isNotEmpty() && bytes(it.source) <= MAX_HINT_BYTES && bytes(it.replacement) <= MAX_TEXT_BYTES }, "A snippet in this file is too long.")
    }

    /** Desktop JSONEncoder [.prettyPrinted, .sortedKeys] layout. */
    fun encode(): ByteArray {
        validate()
        val rules = replacements.joinToString(",\n") { "    {\n      \"replacement\" : ${quote(it.replacement)},\n      \"source\" : ${quote(it.source)}\n    }" }
        val json = buildString {
            append("{\n  \"format\" : \"$FORMAT\",\n")
            append("  \"replacements\" : ").append(if(replacements.isEmpty()) "[]" else "[\n$rules\n  ]").append(",\n")
            append("  \"snippets\" : ").append(if(snippets.isEmpty()) "{}" else snippets.toSortedMap().entries.joinToString(",\n","{\n","\n  }") { "    ${quote(it.key)} : ${quote(it.value)}" }).append(",\n")
            append("  \"version\" : $VERSION,\n")
            append("  \"words\" : ").append(if(words.isEmpty()) "[]" else words.joinToString(",\n","[\n","\n  ]") { "    ${quote(it)}" }).append("\n}")
        }
        return json.toByteArray(Charsets.UTF_8).also { invalid(it.size <= MAX_FILE_BYTES, "This file is too large (over 1 MB).") }
    }

    companion object {
        const val FORMAT = "parla-vocabulary"
        const val VERSION = 1
        const val MAX_FILE_BYTES = 1_048_576
        const val MAX_ENTRIES = 10_000
        const val MAX_TEXT_BYTES = 65_536
        const val MAX_HINT_BYTES = 256
        // Android stored-data limits: the codec refuses >1000 words; the editor allows 250 snippets.
        const val MAX_WORDS = 1000
        const val MAX_SNIPPETS = 250
        private const val NOT_VOCABULARY = "This file isn’t a Parla vocabulary file."
        private val whitespace = Regex("[\\p{Z}\\s\\u0085]+")
        fun normalized(word: String) = word.split(whitespace).filter(String::isNotEmpty).joinToString(" ")
        private fun invalid(ok: Boolean, message: String) { if(!ok) throw IllegalArgumentException(message) }
        private fun quote(s: String) = buildString {
            append('"')
            for(c in s) when(c) {
                '"' -> append("\\\""); '\\' -> append("\\\\"); '/' -> append("\\/")
                '\n' -> append("\\n"); '\r' -> append("\\r"); '\t' -> append("\\t"); '\b' -> append("\\b"); '\u000c' -> append("\\f")
                else -> if(c < ' ') append("\\u%04x".format(c.code)) else append(c)
            }
            append('"')
        }

        fun of(data: LocalData) = VocabularyDocument(data.dictionary, LinkedHashMap<String,String>().apply { data.snippets.forEach { putIfAbsent(it.trigger,it.expansion) } }, data.replacements)

        fun decode(bytes: ByteArray): VocabularyDocument {
            invalid(bytes.size <= MAX_FILE_BYTES, "This file is too large (over 1 MB).")
            val root = try {
                val parser = JSONTokener(bytes.toString(Charsets.UTF_8))
                (parser.nextValue() as? JSONObject).also { invalid(parser.nextClean() == '\u0000', NOT_VOCABULARY) }
            } catch(e: IllegalArgumentException) { throw e } catch(_: Exception) { null } ?: throw IllegalArgumentException(NOT_VOCABULARY)
            // Reject settings dumps and extra fields rather than accepting a credentials-bearing object.
            invalid(root.keys().asSequence().toSet() == setOf("format","version","words","snippets","replacements"), "This is a settings file. Choose an exported vocabulary file.")
            try {
                val format = root.get("format"); val version = root.get("version")
                invalid(format == FORMAT && version is Number && version.toDouble() == VERSION.toDouble(), NOT_VOCABULARY)
                val words = root.getJSONArray("words").let { a -> (0 until a.length()).map { a.get(it) as String } }
                val snippets = root.getJSONObject("snippets").let { o -> o.keys().asSequence().associateWith { o.get(it) as String } }
                val replacements = root.getJSONArray("replacements").let { a -> (0 until a.length()).map {
                    val rule = a.get(it) as JSONObject
                    invalid(rule.keys().asSequence().toSet() == setOf("source","replacement"), NOT_VOCABULARY)
                    LiteralReplacement(rule.get("source") as String, rule.get("replacement") as String)
                } }
                return VocabularyDocument(words,snippets,replacements).also { it.validate() }
            } catch(e: IllegalArgumentException) { throw e } catch(_: Exception) { throw IllegalArgumentException(NOT_VOCABULARY) }
        }
    }
}

/** Bounded review of one decoded file against the vocabulary it was previewed with. */
internal class VocabularyImport private constructor(val incoming: VocabularyDocument, val duplicates: Int, val conflicts: List<String>, private val original: VocabularyDocument) {
    enum class Mode { merge, replace }

    fun result(data: LocalData, mode: Mode, confirmedReplace: Boolean): LocalData {
        require(mode == Mode.merge || confirmedReplace) { "Confirm before replacing your vocabulary." }
        require(VocabularyDocument.of(data) == original) { "Your vocabulary changed. Choose the file again." }
        fun snippets(map: Map<String,String>) = map.map { (k,v) -> Snippet(trigger = k, expansion = v) }
        val next = when(mode) {
            Mode.replace -> data.copy(dictionary = incoming.words, snippets = snippets(incoming.snippets), replacements = incoming.replacements)
            Mode.merge -> {
                val seen = data.dictionary.map { key(it) }.toMutableSet()
                val triggers = data.snippets.map { it.trigger.lowercase(Locale.ROOT) }.toSet()
                val sources = data.replacements.map { it.source }.toMutableSet()
                data.copy(dictionary = data.dictionary + incoming.words.filter { seen.add(key(it)) },
                    snippets = data.snippets + snippets(incoming.snippets.filterKeys { it.lowercase(Locale.ROOT) !in triggers }),
                    replacements = data.replacements + incoming.replacements.filter { sources.add(it.source) })
            }
        }
        require(next.dictionary.size <= VocabularyDocument.MAX_WORDS) { "This would make more than 1,000 dictionary words. Remove some first." }
        require(next.snippets.size <= VocabularyDocument.MAX_SNIPPETS) { "This would make more than 250 snippets. Remove some first." }
        return next
    }

    companion object {
        private fun key(word: String) = VocabularyDocument.normalized(word).lowercase(Locale.ROOT)
        fun preview(bytes: ByteArray, data: LocalData): VocabularyImport {
            val decoded = VocabularyDocument.decode(bytes)
            require(decoded.replacements.map { it.source }.distinct().size == decoded.replacements.size) { "This file has the same replacement twice." }
            val seenWords = mutableSetOf<String>()
            val words = decoded.words.map(VocabularyDocument::normalized).filter { seenWords.add(it.lowercase(Locale.ROOT)) }
            // Android snippet triggers are unique ignoring case (the editor enforces it), so keep the first.
            val seenTriggers = mutableSetOf<String>()
            val snippets = decoded.snippets.toSortedMap().filterKeys { seenTriggers.add(it.lowercase(Locale.ROOT)) }
            val incoming = VocabularyDocument(words,snippets,decoded.replacements)
            val original = VocabularyDocument.of(data)
            val existingWords = data.dictionary.map(::key).toSet()
            val existingTriggers = data.snippets.map { it.trigger.lowercase(Locale.ROOT) }.toSet()
            val existingSources = data.replacements.map { it.source }.toSet()
            val conflicts = words.filter { key(it) in existingWords }.map { "Word: $it" } +
                snippets.keys.filter { it.lowercase(Locale.ROOT) in existingTriggers }.map { "Snippet: $it" } +
                incoming.replacements.filter { it.source in existingSources }.map { "Replacement: ${it.source}" }
            return VocabularyImport(incoming,decoded.words.size-words.size+decoded.snippets.size-snippets.size,conflicts,original)
        }
    }
}

@Composable internal fun VocabularyTransferScreen(store: Store) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var preview by remember { mutableStateOf<VocabularyImport?>(null) }
    var status by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf(false) }
    var pending by remember { mutableStateOf<ByteArray?>(null) }
    val open = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if(uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            preview = null
            status = try {
                check(store.ready) { "Fix the saved data error in Data recovery before importing." }
                val bytes = withContext(Dispatchers.IO) { context.contentResolver.openInputStream(uri)?.use { it.readNBytes(VocabularyDocument.MAX_FILE_BYTES+1) } ?: error("Couldn’t open the file.") }
                preview = VocabularyImport.preview(bytes,store.data.value); ""
            } catch(e: Exception) { e.message ?: "Couldn’t open the file." }
        }
    }
    val save = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        val bytes = pending; pending = null
        if(uri == null) return@rememberLauncherForActivityResult
        status = if(bytes == null) "Export interrupted. Please export again." else try {
            context.contentResolver.openOutputStream(uri,"wt")?.use { it.write(bytes) } ?: error("No destination")
            "Exported."
        } catch(_: Exception) { "Couldn’t export. Choose another location and try again." }
    }
    fun apply(mode: VocabularyImport.Mode) {
        val p = preview ?: run { status = "Import expired. Choose the file again."; return }
        status = try {
            val next = p.result(store.data.value,mode,confirmedReplace = mode == VocabularyImport.Mode.merge || confirm)
            check(store.update { it.copy(dictionary = next.dictionary, snippets = next.snippets, replacements = next.replacements) }) { "Changes were not saved. Your vocabulary is unchanged." }
            preview = null
            if(mode == VocabularyImport.Mode.replace) "Imported. Your previous words, snippets and replacements were replaced." else "Added. Your existing entries were kept."
        } catch(e: Exception) { e.message ?: "Import failed." }
        confirm = false
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("Import and export vocabulary",style = MaterialTheme.typography.headlineMedium)
        Text("Share your dictionary words, snippets and replacements as a file. The file works with parla on Mac. API keys and other settings are never included.")
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = { status = ""; open.launch(arrayOf("application/json","text/plain","application/octet-stream")) }) { Text("Import…") }
            OutlinedButton(onClick = {
                status = try {
                    check(store.ready) { "Fix the saved data error in Data recovery before exporting." }
                    pending = VocabularyDocument.of(store.data.value).encode(); save.launch("parla-vocabulary.json"); ""
                } catch(e: Exception) { e.message ?: "Couldn’t export." }
            }) { Text("Export…") }
        }
        preview?.let { p ->
            HorizontalDivider()
            Text("${p.incoming.words.size} words · ${p.incoming.snippets.size} snippets · ${p.incoming.replacements.size} replacements")
            Text("${p.conflicts.size} already exist · ${p.duplicates} duplicates skipped",style = MaterialTheme.typography.bodySmall)
            // Bounded preview: a 10,000-entry file shows only the first conflicts.
            p.conflicts.take(20).forEach { Text(it,style = MaterialTheme.typography.bodySmall) }
            if(p.conflicts.size > 20) Text("and ${p.conflicts.size-20} more",style = MaterialTheme.typography.bodySmall)
            Text("Add to mine keeps your entries when a name already exists.",style = MaterialTheme.typography.bodySmall)
            Row {
                TextButton(onClick = { apply(VocabularyImport.Mode.merge) }) { Text("Add to mine") }
                TextButton(onClick = { confirm = true },enabled = !p.incoming.isEmpty) { Text("Replace mine…") }
                TextButton(onClick = { preview = null }) { Text("Cancel") }
            }
        }
        if(status.isNotEmpty()) Text(status)
    }
    if(confirm) AlertDialog(onDismissRequest = { confirm = false },title = { Text("Replace your words, snippets and replacements?") },
        text = { Text("Your current dictionary, snippets and replacements are removed and replaced by this file. This can’t be undone; export yours first to keep a copy. Other settings aren’t changed.") },
        confirmButton = { TextButton(onClick = { apply(VocabularyImport.Mode.replace) }) { Text("Replace",color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { confirm = false }) { Text("Cancel") } })
}
