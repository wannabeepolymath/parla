package dev.parla.android

import android.content.Context
import android.os.SystemClock
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Recognition inputs frozen when a form starts. Any saved change cancels the form (desktop GuidedTemplateOwner.Configuration).
 * [model] is the whole selected model, imported identity included, so a replaced import is a settings change.
 */
internal data class TemplateConfig(val model: SpeechModel, val language: String, val dictionary: List<String>)
internal data class TemplateRun(val session: GuidedTemplateSession? = null, val config: TemplateConfig? = null, val recording: Boolean = false, val busy: Boolean = false, val message: String? = null)

/**
 * Screen-owned voice form. Local controls only: no spoken commands and no automatic next take.
 * Each field is recorded and recognized raw on the device; nothing goes through cleanup, snippets or another app.
 */
internal class GuidedTemplateOwner(
    private val scope: CoroutineScope,
    private val clock: () -> Long,
    /** Fresh saved recognition configuration and template document, or null when either is unusable. */
    private val current: () -> Pair<TemplateConfig,GuidedTemplateDocument>?,
    /** Records one field until [stop] completes, then recognizes it locally. Throws with a user message on failure. */
    private val take: suspend (TemplateConfig, CompletableDeferred<Unit>) -> String,
    private val date: () -> Long = System::currentTimeMillis,
) {
    private val value = MutableStateFlow(TemplateRun())
    val state = value.asStateFlow()
    private var job: Job? = null
    private var stop: CompletableDeferred<Unit>? = null
    private var expiry: Job? = null

    private fun notice(text: String?) { value.value = value.value.copy(message = text) }

    fun begin(definition: GuidedTemplateDefinition) {
        if(value.value.session != null) { notice("Wait for the current form to stop."); return }
        val (config,document) = current() ?: run { notice("Select a downloaded speech model in Models, and repair saved data if asked."); return }
        if(definition !in document.definitions) { notice("Settings changed. Try again."); return }
        val session = try { GuidedTemplateSession.begin(definition,clock()) } catch(e: GuidedTemplateFailure) { notice(e.message); return }
        OriginalCopy.clear() // desktop: a form invalidates the previous dictation's original
        value.value = TemplateRun(session,config,message = "Ready. Record each field.")
        expiry = scope.launch { delay(GuidedTemplateSession.LIFETIME_MS); if(value.value.session?.id == session.id) cancel("Form expired after 20 minutes.") }
    }

    /** Re-checked before every action and whenever saved data changes. */
    private fun boundary(): Boolean {
        val run = value.value; val session = run.session ?: return false
        if(session.isExpired(clock())) { cancel("Form expired after 20 minutes."); return false }
        val fresh = current()
        if(fresh == null || fresh.first != run.config || session.definition !in fresh.second.definitions) { cancel("Form canceled because settings changed."); return false }
        return true
    }
    fun observe() { if(value.value.session != null) boundary() }

    fun start() {
        if(value.value.busy || value.value.recording || !boundary()) return
        val run = value.value; val session = run.session ?: return; val config = run.config ?: return
        val (next,t) = try { session.start(clock()) } catch(e: GuidedTemplateFailure) { notice(e.message); return }
        val signal = CompletableDeferred<Unit>(); stop = signal
        val previous = job
        value.value = run.copy(session = next,recording = true,message = "Recording… (up to 30 seconds)")
        job = scope.launch {
            previous?.join() // a discarded take releases the microphone before the next one starts
            val result = try { Result.success(take(config,signal)) } catch(c: CancellationException) { throw c } catch(e: Exception) { Result.failure(e) }
            if(value.value.session?.take != t || !boundary()) return@launch // discarded, canceled or stale
            val settled = value.value.session!!.settle(t,result.getOrNull())
            value.value = value.value.copy(session = settled,recording = false,busy = false,message = when {
                settled.candidate != null -> "Check or edit the text, then accept it."
                result.isFailure -> result.exceptionOrNull()?.message?.take(250) ?: "Nothing was recorded. Record the field again."
                else -> "No speech recognized. Record the field again."
            })
        }
    }
    fun stop() {
        if(!value.value.recording) return
        // Publish first: completing the signal can finish the take synchronously.
        value.value = value.value.copy(recording = false,busy = true,message = "Transcribing…")
        stop?.complete(Unit)
    }
    /** Drops the current take (recording or recognition) or the unaccepted candidate. */
    fun discardTake(message: String? = value.value.message) {
        val run = value.value; val session = run.session ?: return
        val t = session.take ?: run { value.value = run.copy(session = session.discardCandidate()); return }
        value.value = run.copy(session = session.settle(t,null),recording = false,busy = false,message = message)
        job?.cancel() // the recorder deletes its audio; LocalSpeech revokes native work
    }
    /** The app left the screen: a background activity can't keep recording. */
    fun pause() { if(value.value.recording) discardTake("Recording stopped because you left parla. Record the field again.") }

    private fun apply(change: (GuidedTemplateSession) -> GuidedTemplateSession) {
        if(value.value.busy || !boundary()) return
        val session = value.value.session ?: return
        try { value.value = value.value.copy(session = change(session)) } catch(e: GuidedTemplateFailure) { notice(e.message) }
    }
    fun editCandidate(text: String) = apply { it.editCandidate(text) }
    fun accept() = apply { it.accept() }
    fun skip() = apply { it.skip() }
    fun back() = apply { it.back() }
    fun review() = apply { it.review() }
    fun approve(id: UUID) = apply { it.approve(id,date()) }

    fun copy(): String? {
        if(!boundary()) return null
        return value.value.session?.completion?.body?.also { notice("Copied.") }
    }
    /** Explicit, once. History stores the literal form as both original and result. */
    fun save(historyOff: Boolean, write: (HistoryEntry) -> Boolean) {
        if(!boundary()) return
        val run = value.value; val session = run.session ?: return; val completion = session.completion ?: return
        if(session.saved) return
        if(historyOff) { notice("Turn on text history in Privacy to save. You can still copy this text."); return }
        val entry = HistoryEntry(completion.id.toString(),completion.date,completion.body,completion.body,"Voice template. Nothing inserted into an app.",model = run.config?.model?.id.orEmpty())
        if(write(entry)) value.value = value.value.copy(session = session.markSaved(completion.id),message = "Saved to history.")
        else notice("Couldn't save to history. Try again.")
    }
    /** Clears every transient value: takes, candidates, accepted fields, preview and the finished form. */
    fun cancel(reason: String = "Form canceled.") {
        if(value.value.session == null) return
        value.value = TemplateRun(message = reason) // revoke publication before stopping the take
        stop?.complete(Unit); job?.cancel(); expiry?.cancel(); stop = null; expiry = null
    }
}

private const val TAKE_LIMIT_MS = 30_000L

/** The frozen model itself (catalog or imported), while its file is still installed. */
internal fun TemplateConfig.installedModel(file: (SpeechModel) -> File): SpeechModel =
    model.takeIf { file(it).isFile } ?: throw GuidedTemplateFailure("Select a downloaded speech model in Models.")

/** One field: private WAV for at most 30 seconds, local Whisper with the frozen model/language/dictionary, then deleted. */
internal suspend fun recordTemplateField(context: Context, config: TemplateConfig, stop: CompletableDeferred<Unit>): String {
    check(MicrophoneOwner.acquire(currentCoroutineContext().job)) { "Finish the current dictation or microphone test first." }
    val manager = ModelManager.get(context)
    val model = config.installedModel(manager::file)
    val file = CaptureAudio.reserve(File(context.cacheDir,"audio"))
    try {
        var limited = false
        coroutineScope {
            val recorder = WavRecorder(context)
            val stopper = launch { if(withTimeoutOrNull(TAKE_LIMIT_MS) { stop.await() } == null) limited = true; recorder.stop() }
            try { recorder.record(file) {} } finally { stopper.cancel() }
        }
        if(limited) throw GuidedTemplateFailure("Recording stopped or hit the time limit. Record the field again.")
        return LocalSpeech().transcribe(file,manager.file(model),model,config.dictionary,config.language)
    } finally { withContext(NonCancellable+Dispatchers.IO) { CaptureAudio.release(file) } }
}

@Composable internal fun GuidedTemplatesScreen(store: Store, onCopy: (String) -> Unit) {
    val context = LocalContext.current
    val file = remember { GuidedTemplateFile(DurableFile(File(context.filesDir,"guided-templates.json"))) }
    var document by remember { mutableStateOf<Result<GuidedTemplateDocument>?>(null) }
    var editor by remember { mutableStateOf<GuidedTemplateDefinition?>(null) }
    var editorBase by remember { mutableStateOf<UUID?>(null) }
    var templateMessage by remember { mutableStateOf<String?>(null) }
    val data by store.data.collectAsState()
    val scope = rememberCoroutineScope()
    val owner = remember {
        GuidedTemplateOwner(scope,SystemClock::elapsedRealtime,current = {
            val doc = document?.getOrNull(); val d = store.data.value
            val manager = ModelManager.get(context); val model = manager.selected(d.settings)
            if(!store.ready || doc == null || model == null || !manager.file(model).isFile) null
            else TemplateConfig(model,d.settings.language,d.dictionary) to doc
        },take = { config,stop -> recordTemplateField(context,config,stop) })
    }
    val run by owner.state.collectAsState()
    LaunchedEffect(Unit) { document = withContext(Dispatchers.IO) { runCatching { file.load() } } }
    LaunchedEffect(data,document) { owner.observe() }
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current
    DisposableEffect(lifecycle) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _,event -> if(event == androidx.lifecycle.Lifecycle.Event.ON_STOP) owner.pause() }
        lifecycle.lifecycle.addObserver(observer)
        onDispose { lifecycle.lifecycle.removeObserver(observer); owner.cancel() }
    }
    fun mutate(change: (GuidedTemplateDocument) -> GuidedTemplateDocument): Boolean = try {
        document = Result.success(file.mutate(change)); templateMessage = null; true
    } catch(e: GuidedTemplateFailure) { templateMessage = e.message; false }
    catch(_: Exception) { templateMessage = "Couldn’t save templates. Free storage and try again."; false }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).imePadding().padding(24.dp),verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Voice templates",style = MaterialTheme.typography.headlineMedium)
        Text("Fill in a form by voice, one field at a time. Uses your original words, without cleanup or snippets. Recorded and transcribed on this device.")
        templateMessage?.let { Text(it,color = MaterialTheme.colorScheme.error) }
        run.message?.let { Text(it) }
        val session = run.session
        val draft = editor
        when {
            session != null -> TemplateSession(session,run,owner,data.settings,onCopy = { owner.copy()?.let(onCopy) },
                onSave = { owner.save(data.settings.noHistory) { entry -> store.update { it.copy(history = if(it.history.any { row -> row.id == entry.id }) it.history else listOf(entry)+it.history) } } })
            draft != null -> TemplateEditor(draft,{ editor = it },onSave = { if(mutate { it.saving(draft,editorBase) }) { editor = null; editorBase = null } },onCancel = { editor = null; editorBase = null; templateMessage = null })
            document == null -> Text("Loading…")
            document?.isFailure == true -> Text("This template file can't be read. It is kept unchanged.",color = MaterialTheme.colorScheme.error)
            else -> {
                val definitions = document?.getOrNull()?.definitions.orEmpty()
                if(definitions.isEmpty()) Text("Create a template to get started.")
                definitions.forEach { d ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(d.name,Modifier.weight(1f))
                        TextButton(onClick = { owner.begin(d) }) { Text("Start") }
                        TextButton(onClick = { editor = d; editorBase = d.revision; templateMessage = null }) { Text("Edit") }
                        TextButton(onClick = { mutate { it.deleting(d.id,d.revision) } }) { Text("Delete",color = MaterialTheme.colorScheme.error) }
                    }
                }
                Button(onClick = { editor = GuidedTemplateDefinition(name = "",body = "",fields = listOf(GuidedTemplateField(key = "",label = ""))); editorBase = null; templateMessage = null },
                    enabled = definitions.size < 32) { Text("New template") }
            }
        }
    }
}

@Composable private fun TemplateSession(state: GuidedTemplateSession, run: TemplateRun, owner: GuidedTemplateOwner, settings: Settings, onCopy: () -> Unit, onSave: () -> Unit) {
    val idle = !run.busy && !run.recording
    Text(state.definition.name,style = MaterialTheme.typography.titleLarge)
    Text("Speech model: ${speechModelLabel(run.config?.model?.id.orEmpty())} · Language: ${run.config?.language?.let { if(it == "auto") "auto-detect" else it }}",style = MaterialTheme.typography.bodySmall)
    Text("${state.index+1} of ${state.definition.fields.size}: ${state.field.label} · ${if(state.field.required) "Required" else "Optional"}")
    val completion = state.completion; val preview = state.preview; val candidate = state.candidate
    when {
        completion != null -> {
            Text("Finished",style = MaterialTheme.typography.titleMedium)
            SelectionContainer { Text(completion.body) }
            Row {
                TextButton(onClick = onCopy) { Text("Copy") }
                if(settings.noHistory) Text("History is off.",Modifier.padding(12.dp))
                else TextButton(onClick = onSave,enabled = !state.saved) { Text(if(state.saved) "Saved" else "Save to history") }
                TextButton(onClick = { owner.cancel("Form closed.") }) { Text("Done") }
            }
        }
        preview != null -> {
            Text("Review",style = MaterialTheme.typography.titleMedium)
            SelectionContainer { Text(preview.body) }
            Row {
                TextButton(onClick = { owner.approve(preview.id) },enabled = idle) { Text("Finish") }
                TextButton(onClick = owner::back,enabled = idle) { Text("Back to fields") }
                TextButton(onClick = owner::start,enabled = idle) { Text("Re-record field") }
            }
        }
        else -> {
            if(candidate != null) {
                OutlinedTextField(candidate,owner::editCandidate,Modifier.fillMaxWidth().heightIn(min = 130.dp),label = { Text(state.field.label) })
                Button(onClick = owner::accept,enabled = idle) { Text("Accept field") }
            }
            if(run.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            Row {
                Button(onClick = { if(run.recording) owner.stop() else owner.start() },enabled = !run.busy) { Text(if(run.recording) "Stop" else if(candidate == null) "Record" else "Re-record") }
                TextButton(onClick = { owner.discardTake() }) { Text("Discard") }
                TextButton(onClick = owner::back,enabled = idle) { Text("Back") }
                TextButton(onClick = owner::skip,enabled = idle && !state.field.required) { Text("Skip") }
            }
            OutlinedButton(onClick = owner::review,enabled = idle && state.allAnswered) { Text("Review") }
        }
    }
    TextButton(onClick = { owner.cancel() }) { Text("Cancel form",color = MaterialTheme.colorScheme.error) }
    Text("Leaving this screen cancels the form. Nothing is kept unless you save it.",style = MaterialTheme.typography.bodySmall)
}

@Composable private fun TemplateEditor(draft: GuidedTemplateDefinition, change: (GuidedTemplateDefinition) -> Unit, onSave: () -> Unit, onCancel: () -> Unit) {
    fun field(index: Int, update: (GuidedTemplateField) -> GuidedTemplateField) = change(draft.copy(fields = draft.fields.toMutableList().also { it[index] = update(it[index]) }))
    OutlinedTextField(draft.name,{ change(draft.copy(name = it)) },Modifier.fillMaxWidth(),label = { Text("Template name") },singleLine = true)
    Text("You'll fill in fields in this order. Keys use lowercase letters, digits or _.",style = MaterialTheme.typography.bodySmall)
    draft.fields.forEachIndexed { index,f ->
        Column {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(f.key,{ v -> field(index) { it.copy(key = v) } },Modifier.weight(1f),label = { Text("Key") },singleLine = true)
                OutlinedTextField(f.label,{ v -> field(index) { it.copy(label = v) } },Modifier.weight(1f),label = { Text("Label") },singleLine = true)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Switch(f.required,{ v -> field(index) { it.copy(required = v) } }); Text("Required",Modifier.padding(start = 8.dp).weight(1f))
                TextButton(onClick = { change(draft.copy(fields = draft.fields.toMutableList().also { java.util.Collections.swap(it,index,index-1) })) },enabled = index > 0) { Text("Move up") }
                TextButton(onClick = { change(draft.copy(fields = draft.fields.filterIndexed { i,_ -> i != index })) }) { Text("Remove") }
            }
        }
    }
    TextButton(onClick = { change(draft.copy(fields = draft.fields+GuidedTemplateField(key = "",label = ""))) },enabled = draft.fields.size < 12) { Text("Add field") }
    Text("Write the text below. Put {{key}} where each field goes. Type {{{{ or }}}} for literal {{ or }}.",style = MaterialTheme.typography.bodySmall)
    OutlinedTextField(draft.body,{ change(draft.copy(body = it)) },Modifier.fillMaxWidth().heightIn(min = 180.dp),label = { Text("Template text") })
    Row {
        Button(onClick = onSave) { Text("Save template") }
        TextButton(onClick = onCancel) { Text("Cancel") }
    }
}
