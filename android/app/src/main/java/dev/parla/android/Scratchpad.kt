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
        val observer = androidx.lifecycle.LifecycleEventObserver { _,event -> if(event == androidx.lifecycle.Lifecycle.Event.ON_STOP) saveNow() }
        lifecycle.lifecycle.addObserver(observer)
        onDispose { lifecycle.lifecycle.removeObserver(observer); saveNow() }
    }
    Column(Modifier.fillMaxSize().imePadding().padding(16.dp),verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("A private note on this device. Dictate into it with the parla voice control, edit, then copy. It is saved as you type and is separate from history.",style = MaterialTheme.typography.bodySmall)
        Row {
            TextButton(onClick = { onCopy(text) },enabled = text.isNotEmpty()) { Text("Copy") }
            TextButton(onClick = { editor?.onTextContextMenuItem(android.R.id.undo) },enabled = ready) { Text("Undo") }
            TextButton(onClick = { editor?.onTextContextMenuItem(android.R.id.redo) },enabled = ready) { Text("Redo") }
            TextButton(onClick = { clear = true },enabled = text.isNotEmpty()) { Text("Clear",color = MaterialTheme.colorScheme.error) }
        }
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
    if(clear) AlertDialog(onDismissRequest = { clear = false },title = { Text("Clear the scratchpad?") },text = { Text("This removes all of its text from this device and can’t be undone.") },
        confirmButton = { TextButton(onClick = { clear = false; editor?.setText("") ?: run { text = "" }; saveNow() }) { Text("Clear",color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { clear = false }) { Text("Cancel") } })
}
