package dev.parla.android

import android.content.Intent
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
import kotlinx.coroutines.*

@Composable private fun CorePage(content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).imePadding().padding(24.dp),verticalArrangement = Arrangement.spacedBy(14.dp),content = content)
}
@Composable private fun Choice(label: String, selected: Boolean, select: () -> Unit) { Row { RadioButton(selected,select); TextButton(onClick = select) { Text(label) } } }
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
        Text("On-device speech",style = MaterialTheme.typography.headlineMedium)
        Text("Choose a model and download it explicitly. No provider key is used. English models only recognize English; Large v3 Turbo supports multiple languages. Downloads are file sizes, not runtime memory requirements. Compatibility, speed, memory use and accuracy depend on your device; these models are not qualified on Android hardware yet.")
        Text(state.message)
        if(error.isNotEmpty()) Text(error,color = MaterialTheme.colorScheme.error)
        if(state.active && state.pausable) {
            val total = ModelCatalog.all.firstOrNull { it.id == state.id }?.bytes ?: 1
            LinearProgressIndicator(progress = { (state.bytes.toFloat()/total).coerceIn(0f,1f) },modifier = Modifier.fillMaxWidth())
            Text("${state.bytes} / $total bytes")
            Button(onClick = manager::pause) { Text("Pause") }
            TextButton(onClick = { ModelCatalog.all.firstOrNull { it.id == state.id }?.let(manager::discard) }) { Text("Discard after writer stops") }
        }
        for(model in ModelCatalog.all) {
            val installed = revision.let { state.let { manager.file(model).isFile } }
            val row = rows[model.id]
            HorizontalDivider(); Text(model.name,style = MaterialTheme.typography.titleMedium)
            Text("${model.bytes} bytes · ${if(model.id == data.settings.localModel) "Selected" else "Not selected"} · ${if(installed) "On disk (verified before use)" else "Not installed"}")
            Text("SHA-256: ${model.sha256}",style = MaterialTheme.typography.bodySmall)
            if(row != null) Text("${row.message} · ${row.bytes} / ${model.bytes} committed bytes")
            Row {
                Button(onClick = { manager.download(model) },enabled = !state.active) { Text(if(row?.paused == true) "Resume" else if(installed) "Download again" else "Download") }
                if(row?.paused == true) TextButton(onClick = { manager.discard(model) },enabled = !state.active) { Text("Discard") }
                TextButton(onClick = { scope.launch {
                    error = "Verifying…"
                    try {
                        NativeTasks.run { ModelCatalog.verify(manager.file(model),model) }
                        if(store.update { it.copy(settings = it.settings.copy(localModel = model.id)) }) error = "Verified and selected" else error = "Selection was not saved"
                    } catch(e: Exception) { error = e.message.orEmpty() }
                } },enabled = installed && !state.active) { Text("Select") }
                TextButton(onClick = { scope.launch { try { manager.delete(model); revision++ } catch(e: Exception) { error = e.message.orEmpty() } } },enabled = installed && !state.active) { Text("Delete") }
            }
        }
        Text("Pause waits for the writer/native operation to exit. Private checkpoints survive process death as paused; Resume and Discard are explicit. Range/validator changes may require a safe full restart. Installed bytes are replaced only after exact size and SHA-256 verification. Selection never changes automatically.",style = MaterialTheme.typography.bodySmall)
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
        listOf("cleanup","raw","selectedPreset").forEach { mode -> Choice(mode,data.settings.outputMode == mode) { save(data.settings.copy(outputMode = mode)) } }
        Text("Raw bypasses AI, snippets and literal rules. Cleanup-off still uses locked snippets and local literal rules. Presets are explicit transforms: no snippets or literal rules.")
        Row { Text("Optional AI cleanup"); Switch(data.settings.cleanupEnabled,{ save(data.settings.copy(cleanupEnabled = it)) }) }
        listOf("standard","conversational","formal").forEach { style -> Choice(style,data.settings.style == style) { save(data.settings.copy(style = style)) } }
        HorizontalDivider(); Text("Saved rewrite / translation presets",style = MaterialTheme.typography.titleMedium)
        data.presets.forEach { preset ->
            Choice(preset.name,data.settings.selectedPresetID == preset.id) { save(data.settings.copy(selectedPresetID = preset.id)) }
            Row {
                TextButton(onClick = { editing = preset; name = preset.name; kind = preset.kind; instruction = preset.instruction; target = preset.targetLanguage; adding = true }) { Text("Edit") }
                TextButton(onClick = { store.update { it.copy(presets = it.presets.filterNot { p -> p.id == preset.id }) } }) { Text("Delete") }
            }
        }
        Button(onClick = { editing = null; name = ""; instruction = ""; target = ""; kind = "rewrite"; adding = true }) { Text("Add preset") }
        HorizontalDivider(); Text("Literal replacements",style = MaterialTheme.typography.titleMedium)
        Text("Exact, case-sensitive, word boundaries, longest match, one pass. Locked whole-utterance snippets bypass these rules.")
        data.replacements.forEachIndexed { index,rule -> Row { Text("${rule.source} → ${rule.replacement}",Modifier.weight(1f)); TextButton(onClick = { store.update { it.copy(replacements = it.replacements.filterIndexed { i,_ -> i != index }) } }) { Text("Delete") } } }
        Field(source,{ source = it },"Exact source"); Field(replacement,{ replacement = it },"Replacement (may be empty)")
        Button(onClick = { if(store.update { it.copy(replacements = it.replacements + LiteralReplacement(source,replacement)) }) { source = ""; replacement = "" } },enabled = source.isNotEmpty()) { Text("Add replacement") }
    }
    if(adding) AlertDialog(onDismissRequest = { adding = false },title = { Text("Saved explicit transform") },text = {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            Field(name,{ name = it },"Name")
            listOf("rewrite","translation").forEach { value -> Choice(value,kind == value) { kind = value } }
            if(kind == "rewrite") Field(instruction,{ instruction = it },"Instruction (up to 8192 UTF-8 bytes)") else Field(target,{ target = it },"Target language")
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
        Text("Exact-app profiles",style = MaterialTheme.typography.headlineMedium)
        Text("The first saved enabled exact package match wins. Blank fields inherit globals. Vocabulary is prepended in saved order. Site profiles are unavailable: Android does not provide trusted URL metadata. No screen scraping is used.")
        data.profiles.forEach { p ->
            Text("${p.name} · ${p.target}")
            Row { Switch(p.enabled,{ enabled -> store.update { it.copy(profiles = it.profiles.map { row -> if(row.id == p.id) row.copy(enabled = enabled) else row }) } }); TextButton(onClick = { edit(p) }) { Text("Edit") }; TextButton(onClick = { store.update { it.copy(profiles = it.profiles.filterNot { row -> row.id == p.id }) } }) { Text("Delete") } }
        }
        Button(onClick = { edit(null) }) { Text("Add app profile") }
    }
    if(adding) AlertDialog(onDismissRequest = { adding = false },title = { Text("App profile") },text = { Column(Modifier.verticalScroll(rememberScrollState())) {
        Field(name,{ name = it },"Name"); Field(target,{ target = it },"Exact Android package")
        listOf("inherit","on","off").forEach { c -> Choice("Cleanup: $c",cleanup == c) { cleanup = c } }
        listOf("","standard","conversational","formal").forEach { c -> Choice("Style: ${c.ifEmpty { "inherit" }}",style == c) { style = c } }
        Field(language,{ language = it },"Spoken language code; blank inherits, auto follows speaker")
        (listOf("")+ModelCatalog.all.map { it.id }).forEach { c -> Choice("Speech model: ${c.ifEmpty { "inherit" }}",model == c) { model = c } }
        Field(cleanupModel,{ cleanupModel = it },"Text cleanup model; blank inherits")
        Field(words,{ words = it },"Priority vocabulary, one per line")
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
        Text("Unreadable settings block writes and provider requests. Reload after repairing the file externally, or load its original JSON below and explicitly repair it. Repair preserves original bytes in a private dated pre-repair file. Credentials are never included. No reset or uninstall is needed.")
        Button(onClick = { message(if(store.reload()) "Data reloaded" else "Still unreadable; original preserved") }) { Text("Reload from disk") }
        Button(onClick = { try { source = store.recoverySource() } catch(_: Exception) { message("Could not read original file. Check storage/access.") } }) { Text("Load original JSON for repair") }
        Field(source,{ source = it },"Repaired local JSON")
        Button(onClick = { message(if(store.repair(source)) "Repair saved; original copy retained" else "Repair failed; original retained") },enabled = source.isNotBlank()) { Text("Validate and save repair") }
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
        Row { Text("Markdown export"); Switch(markdown,{ markdown = it }) }
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
        Text("Failed/interrupted recognition stays local for ${data.settings.recoveryAudioDays} days; retention is ${if(data.settings.recoveryAudioEnabled) "on" else "off for new captures"}. Text history is independent. Audio is excluded from backup; maximum 300 seconds per file, 128MiB total / 128 files. Ordinary dictation success disposes its audio. Retranscription keeps its source until Delete, Clear or expiry.")
        Text("Retranscribe freezes current global model, language and priority vocabulary. It runs local ASR only: no provider, cleanup or insertion. Save requires text history on and uses its current ${data.settings.historyLimit}-row count limit.")
        if(state.message.isNotEmpty()) Text(state.message)
        error?.let { Text(it,color = MaterialTheme.colorScheme.error) }
        Row {
            TextButton(onClick = { refresh++ }) { Text("Refresh / expire") }
            TextButton(onClick = { stop() },enabled = playing != null) { Text("Stop playback") }
            TextButton(onClick = { clear = true }) { Text("Clear audio") }
        }
        if(state.activeID != null) {
            Text(if(state.stopping) "Waiting for reader exit…" else "Local retranscription running…")
            Button(onClick = recovery::cancel,enabled = !state.stopping) { Text("Cancel retranscription") }
        }
        if(rows.isEmpty()) Text("No failed recovery audio available.")
        rows.forEach { row ->
            HorizontalDivider()
            Text(java.text.DateFormat.getDateTimeInstance().format(java.util.Date(row.created)))
            Text("${row.seconds?.let { "%.1f seconds".format(it) } ?: "Duration unavailable"} · ${row.bytes} bytes")
            Text("Expires: ${row.expires?.let { java.text.DateFormat.getDateTimeInstance().format(java.util.Date(it)) } ?: "Repair settings to determine expiry"}")
            row.reason?.let { Text(it) }
            Row {
                TextButton(onClick = {
                    try { stop(); playback.start(row.id) { success -> playing = null; message(if(success) "Local playback finished" else "Local playback failed; audio preserved") }; playing = playback.id }
                    catch(_: Exception) { message("Local playback unavailable. Check settings, expiry and file availability.") }
                },enabled = row.reason == null && state.activeID == null && status.phase != Phase.RECORDING) { Text("Play") }
                TextButton(onClick = { stop(); recovery.transcribe(row.id) },enabled = row.reason == null && state.activeID == null && status.phase != Phase.RECORDING) { Text("Retranscribe") }
                TextButton(onClick = { if(playing == row.id) stop(); scope.launch { message(withContext(Dispatchers.IO) { recordings.delete(row.id).message }); refresh++ } }) { Text("Delete") }
            }
        }
        state.preview?.let { preview ->
            HorizontalDivider(); Text("Original transcript preview",style = MaterialTheme.typography.titleMedium)
            Text(preview.text)
            Text("Save persists this raw text in local history (up to ${data.settings.historyLimit} rows); it never inserts into an editor.")
            Row {
                TextButton(onClick = { copyPrivate(context,preview.text); message("Original text copied") }) { Text("Copy") }
                TextButton(onClick = recovery::savePreview,enabled = !preview.saved && !data.settings.noHistory && store.ready) { Text(if(preview.saved) "Saved" else "Save to history") }
                TextButton(onClick = recovery::cancel) { Text("Dismiss preview") }
            }
            if(data.settings.noHistory) Text("History is off. Copy now, or enable it in Privacy and retranscribe the retained source to Save. Leaving this screen clears the preview; source audio stays until deletion or expiry.")
        }
    }
    if(clear) AlertDialog(onDismissRequest = { clear = false },title = { Text("Clear retained audio?") },text = { Text("Deletes available recovery recordings. Active recognition readers are skipped until they exit. Saved text is independent.") },
        confirmButton = { TextButton(onClick = { clear = false; stop(); scope.launch { message(withContext(Dispatchers.IO) { recordings.clear().message }); refresh++ } }) { Text("Clear audio") } },
        dismissButton = { TextButton(onClick = { clear = false }) { Text("Cancel") } })
}
