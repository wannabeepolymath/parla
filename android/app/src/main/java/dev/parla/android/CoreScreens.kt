package dev.parla.android

import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.*

@Composable private fun CorePage(content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).imePadding().padding(24.dp),verticalArrangement = Arrangement.spacedBy(14.dp),content = content)
}
@Composable private fun Choice(label: String, selected: Boolean, select: () -> Unit) { Row(verticalAlignment = Alignment.CenterVertically) { RadioButton(selected,select); TextButton(onClick = select) { Text(label) } } }
@Composable private fun Field(value: String, change: (String) -> Unit, label: String) { OutlinedTextField(value,change,label = { Text(label) },modifier = Modifier.fillMaxWidth()) }

@Composable internal fun ModelsScreen(store: Store) {
    val context = LocalContext.current
    val manager = remember { ModelManager.get(context) }
    val state by manager.transfer.collectAsState()
    val rows by manager.rows.collectAsState()
    val data by store.data.collectAsState()
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf("") }
    var revision by remember { mutableIntStateOf(0) }
    CorePage {
        Text("Speech models",style = MaterialTheme.typography.headlineMedium)
        Text("Download a model to transcribe on your device. No API key is needed. Base and Small support English; Large v3 Turbo supports multiple languages. Speed and accuracy vary by device, and Android compatibility is still being tested.")
        Text(state.message)
        if(error.isNotEmpty()) Text(error,color = MaterialTheme.colorScheme.error)
        if(state.active && state.pausable) {
            val total = ModelCatalog.all.firstOrNull { it.id == state.id }?.bytes ?: 1
            LinearProgressIndicator(progress = { (state.bytes.toFloat()/total).coerceIn(0f,1f) },modifier = Modifier.fillMaxWidth())
            Text("${fileSizeLabel(state.bytes)} of ${fileSizeLabel(total)}")
            Button(onClick = manager::pause) { Text("Pause") }
            TextButton(onClick = { ModelCatalog.all.firstOrNull { it.id == state.id }?.let(manager::discard) }) { Text("Discard download") }
        }
        for(model in ModelCatalog.all) {
            val installed = revision.let { state.let { manager.file(model).isFile } }
            val row = rows[model.id]
            HorizontalDivider(); Text(speechModelLabel(model.id),style = MaterialTheme.typography.titleMedium)
            Text("${fileSizeLabel(model.bytes)} · ${if(model.id == data.settings.localModel) "Selected" else "Not selected"} · ${if(installed) "Downloaded" else "Not downloaded"}")
            if(row != null) Text("${row.message} · ${fileSizeLabel(row.bytes)} of ${fileSizeLabel(model.bytes)}")
            Row {
                Button(onClick = { manager.download(model) },enabled = !state.active) { Text(if(row?.paused == true) "Resume" else if(installed) "Download again" else "Download") }
                if(row?.paused == true) TextButton(onClick = { manager.discard(model) },enabled = !state.active) { Text("Discard") }
                TextButton(onClick = { scope.launch {
                    error = "Checking model…"
                    try {
                        NativeTasks.run { ModelCatalog.verify(manager.file(model),model) }
                        if(store.update { it.copy(settings = it.settings.copy(localModel = model.id)) }) error = "Model selected" else error = "Selection was not saved"
                    } catch(e: Exception) { error = "Could not update this model. Check storage or download it again." }
                } },enabled = installed && !state.active) { Text("Select") }
                TextButton(onClick = { scope.launch { try { manager.delete(model); revision++ } catch(e: Exception) { error = "Could not update this model. Check storage or download it again." } } },enabled = installed && !state.active) { Text("Delete") }
            }
        }
        Text("Downloads use storage and may use mobile data. Models need extra memory while running. Interrupted downloads stay paused until you resume them. Discard removes an unfinished download, keeping any installed model. After downloading, tap Select to use it.",style = MaterialTheme.typography.bodySmall)
    }
}

@Composable internal fun OutputScreen(data: LocalData, store: Store, message: (String) -> Unit) {
    var editing by remember { mutableStateOf<TransformPreset?>(null) }
    var adding by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }; var instruction by remember { mutableStateOf("") }; var kind by remember { mutableStateOf("rewrite") }; var target by remember { mutableStateOf("") }
    var source by remember { mutableStateOf("") }; var replacement by remember { mutableStateOf("") }
    fun save(settings: Settings) { if(!store.update { it.copy(settings = settings) }) message("Settings were not saved") }
    CorePage {
        Text("Output settings",style = MaterialTheme.typography.headlineMedium)
        listOf("cleanup","raw","selectedPreset").forEach { mode -> Choice(outputLabel(mode),data.settings.outputMode == mode) { save(data.settings.copy(outputMode = mode)) } }
        Text("Clean up speech uses snippets and word replacements, even with AI cleanup off. As spoken skips these changes. Saved presets rewrite or translate without snippets or replacements.")
        Row(Modifier.fillMaxWidth(),verticalAlignment = Alignment.CenterVertically) { Text("AI cleanup",Modifier.weight(1f)); Switch(data.settings.cleanupEnabled,{ save(data.settings.copy(cleanupEnabled = it)) }) }
        Text("AI cleanup and presets send text to your chosen provider. Set up an API connection to use them.")
        Text("Writing style",style = MaterialTheme.typography.titleMedium)
        listOf("standard","conversational","formal").forEach { style -> Choice(styleLabel(style),data.settings.style == style) { save(data.settings.copy(style = style)) } }
        HorizontalDivider(); Text("Saved presets",style = MaterialTheme.typography.titleMedium)
        data.presets.forEach { preset ->
            Choice(preset.name,data.settings.selectedPresetID == preset.id) { save(data.settings.copy(selectedPresetID = preset.id)) }
            Row {
                TextButton(onClick = { editing = preset; name = preset.name; kind = preset.kind; instruction = preset.instruction; target = preset.targetLanguage; adding = true }) { Text("Edit") }
                TextButton(onClick = { store.update { it.copy(presets = it.presets.filterNot { p -> p.id == preset.id }) } }) { Text("Delete") }
            }
        }
        Button(onClick = { editing = null; name = ""; instruction = ""; target = ""; kind = "rewrite"; adding = true }) { Text("Add preset") }
        HorizontalDivider(); Text("Word replacements",style = MaterialTheme.typography.titleMedium)
        Text("Replace whole words or phrases with matching capitalization. Longer matches take priority. Snippets used on their own stay unchanged.")
        data.replacements.forEachIndexed { index,rule -> Row { Text("${rule.source} → ${rule.replacement}",Modifier.weight(1f)); TextButton(onClick = { store.update { it.copy(replacements = it.replacements.filterIndexed { i,_ -> i != index }) } }) { Text("Delete") } } }
        Field(source,{ source = it },"Word or phrase"); Field(replacement,{ replacement = it },"Replace with (blank removes it)")
        Button(onClick = { if(store.update { it.copy(replacements = it.replacements + LiteralReplacement(source,replacement)) }) { source = ""; replacement = "" } },enabled = source.isNotEmpty()) { Text("Add replacement") }
    }
    if(adding) AlertDialog(onDismissRequest = { adding = false },title = { Text("Save a preset") },text = {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            Field(name,{ name = it },"Name")
            listOf("rewrite","translation").forEach { value -> Choice(presetLabel(value),kind == value) { kind = value } }
            if(kind == "rewrite") Field(instruction,{ instruction = it },"How should the text change?") else Field(target,{ target = it },"Target language")
        }
    },confirmButton = { TextButton(onClick = {
        try {
            val preset = TransformPreset(id = editing?.id ?: java.util.UUID.randomUUID().toString(),name = name,kind = kind,instruction = instruction,targetLanguage = target).also { it.validate() }
            if(store.update { it.copy(presets = if(editing == null) it.presets+preset else it.presets.map { p -> if(p.id == preset.id) preset else p }) }) adding = false
        } catch(e: Exception) { message(e.message.orEmpty()) }
    }) { Text("Save") } },dismissButton = { TextButton(onClick = { adding = false }) { Text("Cancel") } })
}

@Composable internal fun ProfilesScreen(data: LocalData, store: Store, message: (String) -> Unit) {
    var editing by remember { mutableStateOf<AppProfile?>(null) }; var adding by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }; var target by remember { mutableStateOf("") }; var cleanup by remember { mutableStateOf("inherit") }; var style by remember { mutableStateOf("") }; var language by remember { mutableStateOf("") }; var model by remember { mutableStateOf("") }; var cleanupModel by remember { mutableStateOf("") }; var words by remember { mutableStateOf("") }
    fun edit(p: AppProfile?) { editing = p; name = p?.name.orEmpty(); target = p?.target.orEmpty(); cleanup = p?.cleanup ?: "inherit"; style = p?.style.orEmpty(); language = p?.language.orEmpty(); model = p?.localModel.orEmpty(); cleanupModel = p?.cleanupModel.orEmpty(); words = p?.vocabulary?.joinToString("\n").orEmpty(); adding = true }
    CorePage {
        Text("App profiles",style = MaterialTheme.typography.headlineMedium)
        Text("Customize dictation for an app. Blank fields use your defaults. If profiles overlap, the first enabled match is used. Profile vocabulary has priority over your dictionary. Website profiles are not available on Android.")
        data.profiles.forEach { p ->
            Text("${p.name} · ${p.target}")
            Row { Switch(p.enabled,{ enabled -> store.update { it.copy(profiles = it.profiles.map { row -> if(row.id == p.id) row.copy(enabled = enabled) else row }) } }); TextButton(onClick = { edit(p) }) { Text("Edit") }; TextButton(onClick = { store.update { it.copy(profiles = it.profiles.filterNot { row -> row.id == p.id }) } }) { Text("Delete") } }
        }
        Button(onClick = { edit(null) }) { Text("Add app profile") }
    }
    if(adding) AlertDialog(onDismissRequest = { adding = false },title = { Text("App profile") },text = { Column(Modifier.verticalScroll(rememberScrollState())) {
        Field(name,{ name = it },"Name"); Field(target,{ target = it },"App package name (e.g. com.whatsapp)")
        listOf("inherit","on","off").forEach { c -> Choice("AI cleanup: ${cleanupLabel(c)}",cleanup == c) { cleanup = c } }
        listOf("","standard","conversational","formal").forEach { c -> Choice("Style: ${styleLabel(c)}",style == c) { style = c } }
        Field(language,{ language = it },"Language code (optional)")
        Text("For example, en for English or auto to detect the language. Leave blank to use your default.")
        (listOf("")+ModelCatalog.all.map { it.id }).forEach { c -> Choice("Speech model: ${speechModelLabel(c)}",model == c) { model = c } }
        Field(cleanupModel,{ cleanupModel = it },"AI model ID (optional)")
        Field(words,{ words = it },"Priority words, one per line")
    } },confirmButton = { TextButton(onClick = {
        try {
            val p = AppProfile(id = editing?.id ?: java.util.UUID.randomUUID().toString(),name = name.trim(),target = target.trim(),enabled = editing?.enabled ?: true,cleanup = cleanup,style = style,language = language.trim(),localModel = model,cleanupModel = cleanupModel.trim(),vocabulary = words.lines().filter { it.isNotBlank() }).also { it.validate() }
            if(store.update { it.copy(profiles = if(editing == null) it.profiles+p else it.profiles.map { row -> if(row.id == p.id) p else row }) }) adding = false
        } catch(e: Exception) { message(e.message.orEmpty()) }
    }) { Text("Save") } },dismissButton = { TextButton(onClick = { adding = false }) { Text("Cancel") } })
}

@Composable internal fun DataRecoveryScreen(store: Store, message: (String) -> Unit) {
    var source by remember { mutableStateOf("") }
    CorePage {
        Text("Data recovery",style = MaterialTheme.typography.headlineMedium)
        Text("If saved data cannot be read, saving and AI cleanup are paused. Reload after fixing the file, or edit its JSON below. Saving a repair keeps a dated private copy of the original. API keys are not included. You do not need to uninstall.")
        Button(onClick = { message(if(store.reload()) "Data reloaded" else "Data still cannot be read. Original kept.") }) { Text("Reload saved data") }
        Button(onClick = { try { source = store.recoverySource() } catch(_: Exception) { message("Could not read the original file. Check device storage.") } }) { Text("Load original data") }
        Field(source,{ source = it },"Data to repair (JSON)")
        Button(onClick = { message(if(store.repair(source)) "Repair saved. Original copy kept." else "Repair failed. Original copy kept.") },enabled = source.isNotBlank()) { Text("Save repair") }
    }
}
@Composable internal fun HistoryExportControls(rows: List<HistoryEntry>) {
    val context = LocalContext.current
    var pending by remember { mutableStateOf("") }
    var exportStatus by remember { mutableStateOf("") }
    var markdown by remember { mutableStateOf(false) }
    val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("text/plain")) { uri ->
        if(uri != null) exportStatus = writeHistoryExport(pending) { payload ->
            val output = context.contentResolver.openOutputStream(uri) ?: error("No writable destination")
            output.bufferedWriter().use { it.write(payload) }
        }
        pending = ""
    }
    Column {
        if(exportStatus.isNotEmpty()) Text(exportStatus)
        Row(Modifier.fillMaxWidth(),verticalAlignment = Alignment.CenterVertically) { Text("Export as Markdown",Modifier.weight(1f)); Switch(markdown,{ markdown = it }) }
        Row {
            TextButton(onClick = {
                exportStatus = shareHistory(exportHistory(rows,markdown)) { text ->
                    val intent = Intent(Intent.ACTION_SEND).setType(if(markdown) "text/markdown" else "text/plain").putExtra(Intent.EXTRA_TEXT,text)
                    context.startActivity(Intent.createChooser(intent,"Share text history"))
                }
            }) { Text("Share history") }
            TextButton(onClick = { pending = exportHistory(rows,markdown); export.launch(if(markdown) "parla-history.md" else "parla-history.txt") }) { Text("Export file") }
        }
    }
}

@Composable internal fun AudioRecoveryScreen(store: Store, message: (String) -> Unit) {
    val context = LocalContext.current
    val recordings = remember { RecordingStore.get(context) }
    val manager = remember { ModelManager.get(context) }
    val playback = remember { RecoveryPlayback(recordings) }
    val recovery = remember {
        AudioRecovery(recordings,{ store.data.value.takeIf { store.ready && store.persistenceError.value == null } },manager::file,
            { entry -> store.update { if(it.settings.noHistory) error("History is off") else it.copy(history = listOf(entry)+it.history) } })
    }
    val state by recovery.state.collectAsState()
    val revision by recordings.revision.collectAsState()
    val error by recordings.error.collectAsState()
    val data by store.data.collectAsState()
    val status by ParlaService.status.collectAsState()
    var rows by remember { mutableStateOf<List<AudioDescriptor>>(emptyList()) }
    var playing by remember { mutableStateOf<String?>(null) }
    var refresh by remember { mutableIntStateOf(0) }
    var clear by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(revision,refresh,data.settings.recoveryAudioDays,store.ready) {
        rows = withContext(Dispatchers.IO) { recordings.descriptors() }
    }
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current
    DisposableEffect(lifecycle) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _,event ->
            if(event == androidx.lifecycle.Lifecycle.Event.ON_STOP) { playback.stop(); playing = null }
        }
        lifecycle.lifecycle.addObserver(observer)
        onDispose { lifecycle.lifecycle.removeObserver(observer); playback.stop(); recovery.close() }
    }
    fun stop() { playback.stop(); playing = null }
    CorePage {
        Text("Recovery audio",style = MaterialTheme.typography.headlineMedium)
        Text("Failed or interrupted recordings are kept on this device for ${data.settings.recoveryAudioDays} days. Saving new recordings is ${if(data.settings.recoveryAudioEnabled) "on" else "off"}. Audio is never uploaded or backed up. Successful, canceled and private recordings are removed.")
        Text("Retranscribe uses your current speech model, language and dictionary on this device. It does not use AI cleanup or insert text. Recordings stay until you delete them or they expire. Storage is limited to 5 minutes per recording and 134 MB or 128 files.")
        if(state.message.isNotEmpty()) Text(state.message)
        error?.let { Text(it,color = MaterialTheme.colorScheme.error) }
        Row {
            TextButton(onClick = { refresh++ }) { Text("Refresh") }
            TextButton(onClick = { stop() },enabled = playing != null) { Text("Stop playback") }
            TextButton(onClick = { clear = true }) { Text("Clear audio") }
        }
        if(state.activeID != null) {
            Text(if(state.stopping) "Stopping…" else "Transcribing on device…")
            Button(onClick = recovery::cancel,enabled = !state.stopping) { Text("Cancel retranscription") }
        }
        if(rows.isEmpty()) Text("No recordings to recover.")
        rows.forEach { row ->
            HorizontalDivider()
            Text(java.text.DateFormat.getDateTimeInstance().format(java.util.Date(row.created)))
            Text("${row.seconds?.let { "%.1f seconds".format(it) } ?: "Duration unavailable"} · ${fileSizeLabel(row.bytes)}")
            Text("Expires: ${row.expires?.let { java.text.DateFormat.getDateTimeInstance().format(java.util.Date(it)) } ?: "Unavailable until settings are repaired"}")
            row.reason?.let { Text(it) }
            Row {
                TextButton(onClick = {
                    try { stop(); playback.start(row.id) { success -> playing = null; message(if(success) "Playback finished" else "Playback failed. Recording kept.") }; playing = playback.id }
                    catch(_: Exception) { message("Could not play this recording. Refresh and try again.") }
                },enabled = row.reason == null && state.activeID == null && status.phase != Phase.RECORDING) { Text("Play") }
                TextButton(onClick = { stop(); recovery.transcribe(row.id) },enabled = row.reason == null && state.activeID == null && status.phase != Phase.RECORDING) { Text("Retranscribe") }
                TextButton(onClick = { if(playing == row.id) stop(); scope.launch { message(withContext(Dispatchers.IO) { recordings.delete(row.id).message }); refresh++ } }) { Text("Delete") }
            }
        }
        state.preview?.let { preview ->
            HorizontalDivider(); Text("Transcript preview",style = MaterialTheme.typography.titleMedium)
            Text(preview.text)
            Text("Save keeps this transcript in text history, limited to ${data.settings.historyLimit} entries. It does not insert text into an app.")
            Row {
                TextButton(onClick = { copyPrivate(context,preview.text); message("Original text copied") }) { Text("Copy") }
                TextButton(onClick = recovery::savePreview,enabled = !preview.saved && !data.settings.noHistory && store.ready) { Text(if(preview.saved) "Saved" else "Save to history") }
                TextButton(onClick = recovery::cancel) { Text("Dismiss preview") }
            }
            if(data.settings.noHistory) Text("History is off. You can copy this text now. To save it, enable history in Privacy and transcribe the recording again. Leaving this screen clears the preview but keeps the recording.")
        }
    }
    if(clear) AlertDialog(onDismissRequest = { clear = false },title = { Text("Clear retained audio?") },text = { Text("Deletes recovery recordings that are not in use. Recordings being played or transcribed are kept; clear them after stopping. Saved text history is kept.") },
        confirmButton = { TextButton(onClick = { clear = false; stop(); scope.launch { message(withContext(Dispatchers.IO) { recordings.clear().message }); refresh++ } }) { Text("Clear audio") } },
        dismissButton = { TextButton(onClick = { clear = false }) { Text("Cancel") } })
}
