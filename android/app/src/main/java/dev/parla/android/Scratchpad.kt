package dev.parla.android

import android.text.Editable
import android.text.InputFilter
import android.text.TextWatcher
import android.widget.EditText
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import java.io.File
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/** Desktop Parla/scratchpad.txt: one private document, separate from history, never sent anywhere. */
internal class ScratchpadFile(private val file: DurableFile) {
    fun load(): String {
        val bytes = file.read(MAX_BYTES+1) ?: return ""
        check(bytes.size <= MAX_BYTES) { "Scratchpad is too large." }
        return bytes.toString(Charsets.UTF_8)
    }
    private val tickets = AtomicLong()
    private var written = 0L
    /** Take a ticket when the text is read; a write holding an older ticket than the last one written is dropped. */
    fun ticket() = tickets.incrementAndGet()
    @Synchronized fun save(text: String, ticket: Long) {
        require(text.length <= MAX_CHARS)
        if(ticket < written) return
        file.write(text.toByteArray(Charsets.UTF_8)); written = ticket
    }
    companion object {
        const val MAX_CHARS = 100_000
        const val MAX_BYTES = MAX_CHARS * 3 // UTF-8 bytes per UTF-16 unit, at most
    }
}

@Composable internal fun ScratchpadScreen(onCopy: (String) -> Unit) {
    val context = LocalContext.current
    val pad = remember { ScratchpadFile(DurableFile(File(context.filesDir,"scratchpad.txt"))) }
    var loaded by remember { mutableStateOf<Result<String>?>(null) }
    var text by remember { mutableStateOf("") }
    var saved by remember { mutableStateOf("") }
    var editor by remember { mutableStateOf<EditText?>(null) }
    var status by remember { mutableStateOf("") }
    var clear by remember { mutableStateOf(false) }
    val store = remember { Store.get(context) }
    val data by store.data.collectAsState()
    var spelling by remember { mutableStateOf<ScratchpadSpelling.Request?>(null) }
    var spellingStatus by remember { mutableStateOf(ScratchpadSpelling.READY) }
    LaunchedEffect(spelling) { spelling?.let { delay(it.deadline-android.os.SystemClock.elapsedRealtime()); spelling = null } }
    fun beginSpelling() {
        val view = editor ?: return
        spelling = null
        spellingStatus = try {
            val request = ScratchpadSpelling.begin(view.text.toString(),view.selectionStart,view.selectionEnd,store.data.value,android.os.SystemClock.elapsedRealtime())
            spelling = request
            if(request.choices.more) "Dictionary spellings (first 5). Choose one." else "Choose a dictionary spelling."
        } catch(e: ScratchpadSpelling.Refusal) { e.message.orEmpty() }
    }
    // One exact, undoable replacement of the reviewed word. Never a second repair write.
    fun chooseSpelling(candidate: String) {
        val request = spelling ?: return; spelling = null
        val view = editor ?: return
        val edit = ScratchpadSpelling.choose(request,candidate,view.text.toString(),view.selectionStart,view.selectionEnd,
            store.ready && store.data.value.settings.scratchpadSpelling,store.data.value,android.os.SystemClock.elapsedRealtime())
            ?: run { spellingStatus = "Your text or dictionary changed. Try again."; return }
        view.text.replace(edit.start,edit.end,edit.replacement)
        if(view.text.toString() != edit.expected) { spellingStatus = ScratchpadSpelling.FAILED; return }
        view.setSelection(edit.selectionStart,edit.selectionEnd)
        spellingStatus = if(view.selectionStart == edit.selectionStart && view.selectionEnd == edit.selectionEnd) ScratchpadSpelling.READY else ScratchpadSpelling.FAILED
    }
    LaunchedEffect(Unit) { loaded = withContext(Dispatchers.IO) { runCatching { pad.load() } }.also { r -> r.getOrNull()?.let { text = it; saved = it } } }
    val ready = loaded?.isSuccess == true
    // Reads state, not the composition-time `ready`: lifecycle callbacks outlive the first composition.
    fun saveNow() {
        if(loaded?.isSuccess != true || text == saved) return
        status = try { pad.save(text,pad.ticket()); saved = text; "" } catch(_: Exception) { "Couldn’t save the scratchpad. Free storage and keep this screen open." }
    }
    LaunchedEffect(text,ready) { if(ready && text != saved) { delay(500); val value = text; val ticket = pad.ticket(); withContext(Dispatchers.IO) { runCatching { pad.save(value,ticket) } }.onSuccess { saved = value; status = "" }.onFailure { status = "Couldn’t save the scratchpad. Free storage and keep this screen open." } } }
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current
    DisposableEffect(lifecycle) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _,event -> if(event == androidx.lifecycle.Lifecycle.Event.ON_STOP) { spelling = null; saveNow() } }
        lifecycle.lifecycle.addObserver(observer)
        onDispose { lifecycle.lifecycle.removeObserver(observer); saveNow() }
    }
    Column(Modifier.fillMaxSize().imePadding().padding(16.dp),verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("A private note on this device. Dictate into it with the parla voice control, edit, then copy. It is saved as you type and is separate from history. With dictionary spelling on, tap a word, then Dictionary spelling to choose a spelling from your dictionary.",style = MaterialTheme.typography.bodySmall)
        Row {
            TextButton(onClick = { onCopy(text) },enabled = text.isNotEmpty()) { Text("Copy") }
            TextButton(onClick = { editor?.onTextContextMenuItem(android.R.id.undo) },enabled = ready) { Text("Undo") }
            TextButton(onClick = { editor?.onTextContextMenuItem(android.R.id.redo) },enabled = ready) { Text("Redo") }
            TextButton(onClick = { clear = true },enabled = text.isNotEmpty()) { Text("Clear",color = MaterialTheme.colorScheme.error) }
        }
        Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            Checkbox(data.settings.scratchpadSpelling,{ on ->
                spelling = null
                spellingStatus = if(store.update { it.copy(settings = it.settings.copy(scratchpadSpelling = on)) }) ScratchpadSpelling.READY else "Couldn’t save this setting. Check Data recovery and try again."
            },enabled = store.ready)
            Text("Dictionary spelling in Scratchpad",Modifier.weight(1f))
            TextButton(onClick = ::beginSpelling,enabled = ready && store.ready && data.settings.scratchpadSpelling) { Text("Dictionary spelling…") }
        }
        if(data.settings.scratchpadSpelling) Text(spellingStatus,style = MaterialTheme.typography.bodySmall)
        if(status.isNotEmpty()) Text(status,color = MaterialTheme.colorScheme.error)
        when {
            loaded == null -> Text("Loading…")
            loaded?.isFailure == true -> Text("The scratchpad couldn’t be read. Its file is kept unchanged.",color = MaterialTheme.colorScheme.error)
            else -> AndroidView(factory = { c -> EditText(c).apply {
                setText(text); hint = "Your words go here…"; gravity = android.view.Gravity.TOP
                inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE or android.text.InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
                filters = arrayOf(InputFilter.LengthFilter(ScratchpadFile.MAX_CHARS))
                setTextColor(android.graphics.Color.rgb(26,26,26)); setHintTextColor(android.graphics.Color.rgb(116,113,128)); textSize = 18f
                setPadding(30,30,30,30); setBackgroundColor(android.graphics.Color.rgb(247,235,255))
                contentDescription = "Scratchpad editor"
                addTextChangedListener(object : TextWatcher {
                    override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                    override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
                    override fun afterTextChanged(s: Editable?) { text = s?.toString().orEmpty() }
                })
                editor = this
            } },modifier = Modifier.fillMaxWidth().weight(1f).clip(RoundedCornerShape(20.dp)))
        }
    }
    spelling?.let { request ->
        AlertDialog(onDismissRequest = { spelling = null },title = { Text(if(request.choices.more) "Dictionary spellings (first 5)" else "Dictionary spellings") },
            text = { Column { request.choices.outputs.forEach { word -> TextButton(onClick = { chooseSpelling(word) }) { Text(word) } } } },
            confirmButton = {},dismissButton = { TextButton(onClick = { spelling = null }) { Text("Cancel") } })
    }
    if(clear) AlertDialog(onDismissRequest = { clear = false },title = { Text("Clear the scratchpad?") },text = { Text("This removes all of its text from this device and can’t be undone.") },
        confirmButton = { TextButton(onClick = { clear = false; editor?.setText("") ?: run { text = "" }; saveNow() }) { Text("Clear",color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { clear = false }) { Text("Cancel") } })
}
