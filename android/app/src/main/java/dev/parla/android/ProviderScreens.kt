package dev.parla.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.*

/** Settings row subtitle. Reads no key, only whether one is saved for the selected address. */
internal fun connectionSummary(store: Store, settings: Settings): String {
    val endpoint = runCatching { settings.endpoint() }.getOrNull() ?: return "Optional"
    if (!endpoint.custom && !store.hasKey(endpoint.scope)) return "Optional"
    return endpoint.label + if (endpoint.local) " · Local server" else " · Cloud"
}

private fun accessLabel(endpoint: Endpoint) = when {
    endpoint.cleartext -> "Local server · not encrypted. http:// works only for servers on your private network. On a phone, localhost means this phone; use your computer's network address, such as http://192.168.1.20:11434/v1."
    endpoint.local -> "Local server · encrypted (HTTPS)."
    else -> "Cloud service · encrypted (HTTPS). Your text is sent to ${endpoint.label}."
}
private fun failureText(e: Exception) = when (e) {
    is ApiFailure -> e.message.orEmpty() + (e.detail?.let { " ($it)" } ?: "")
    else -> e.message ?: "Something went wrong. Try again."
}

@Composable internal fun ApiScreen(store: Store, data: LocalData, message: (String) -> Unit) {
    val saved = data.settings
    var provider by remember { mutableStateOf(if (ProviderCatalog.find(saved.provider) != null) saved.provider else "anthropic") }
    // Drafts per provider: switching never rewrites another provider's values.
    var drafts by remember { mutableStateOf(saved.providers) }
    val config = drafts[provider] ?: ProviderCatalog.default(provider)
    fun edit(next: ProviderConfig) { drafts = drafts + (provider to next) }
    var key by remember { mutableStateOf("") }
    var revision by remember { mutableIntStateOf(0) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var result by remember { mutableStateOf<String?>(null) }
    var models by remember { mutableStateOf<List<String>?>(null) }
    val scope = rememberCoroutineScope()
    val api = remember { ApiClient() }
    val endpoint = runCatching { endpointFor(provider, config) }.getOrNull()
    val hasKey = remember(endpoint?.scope, revision) { endpoint != null && store.hasKey(endpoint.scope) }
    val valid = endpoint != null && (endpoint.model.isNotEmpty() || endpoint.custom) && endpoint.model.length <= 200
    // Entered key first, else only the key saved for this exact address.
    fun requestKey(e: Endpoint) = key.trim().ifEmpty { if (store.hasKey(e.scope)) store.readKey(e.scope) else "" }
    fun launch(work: suspend () -> Unit) {
        busy = true; error = null; result = null
        scope.launch {
            try { work() } catch (c: CancellationException) { throw c } catch (e: Exception) { error = failureText(e) } finally { busy = false }
        }
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).imePadding().padding(24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("AI text cleanup", style = MaterialTheme.typography.headlineMedium)
        Text("Audio stays on your device. AI cleanup sends your transcript, vocabulary and snippets to the provider you choose. Your provider may charge for use and has its own data retention policy.", style = MaterialTheme.typography.bodyMedium)
        Text("Text provider", style = MaterialTheme.typography.titleMedium)
        ProviderCatalog.all.forEach { preset ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                RadioButton(provider == preset.id, { provider = preset.id; key = ""; error = null; result = null; models = null })
                Text(preset.label)
            }
        }
        if (provider == "custom") {
            OutlinedTextField(config.baseUrl, { edit(config.copy(baseUrl = it.take(500))) }, label = { Text("API address") },
                placeholder = { Text("https://api.example.com/v1") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            if (endpoint == null && config.baseUrl.isNotBlank()) Text(runCatching { canonicalBase(config.baseUrl) }.exceptionOrNull()?.message.orEmpty(), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
        }
        if (endpoint != null) Text(accessLabel(endpoint), style = MaterialTheme.typography.bodySmall)
        OutlinedTextField(config.model, { edit(config.copy(model = it.take(200))) }, label = { Text(if (provider == "custom") "Model ID (optional)" else "Model ID") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        if (provider == "custom") Text("Leave blank to use the server's first chat model.", style = MaterialTheme.typography.bodySmall)
        if (provider != "anthropic") TextButton(onClick = { endpoint?.let { e -> launch { models = withContext(Dispatchers.IO) { requestKey(e) }.let { api.listModels(e, it) } } } }, enabled = endpoint != null && !busy) { Text("Choose from the server's models") }
        OutlinedTextField(key, { key = it.take(8192) }, label = { Text(if (hasKey) "Replace saved key (optional)" else if (provider == "custom") "API key (optional)" else "API key") },
            visualTransformation = PasswordVisualTransformation(), singleLine = true, modifier = Modifier.fillMaxWidth())
        Text(if (hasKey) "A key for this address is saved in encrypted device storage. Leave this field blank to keep it." else "Each provider's key is encrypted on this device, used only for its own address and excluded from backups.", style = MaterialTheme.typography.bodySmall)
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        result?.let { Text(it, color = MaterialTheme.colorScheme.primary) }
        Button(onClick = {
            val e = endpoint ?: return@Button
            val entered = key
            launch {
                withContext(Dispatchers.IO) {
                    val current = store.data.value.settings
                    store.saveConnection(current.copy(provider = provider, providers = current.providers + (provider to ProviderConfig(e.baseUrl, e.model))), entered)
                }
                key = ""; revision++; message("API settings saved. No test request was sent.")
            }
        }, enabled = valid && !busy, modifier = Modifier.fillMaxWidth().height(52.dp)) { Text(if (busy) "Working…" else "Save API settings") }
        OutlinedButton(onClick = {
            val e = endpoint ?: return@OutlinedButton
            launch {
                api.testConnection(e, withContext(Dispatchers.IO) { requestKey(e) })
                result = "Connection works. ${e.label} accepted the key and model."
            }
        }, enabled = valid && !busy, modifier = Modifier.fillMaxWidth()) { Text("Test connection") }
        Text("Test connection sends one tiny request to the provider, which may charge for it. It never runs on its own.", style = MaterialTheme.typography.bodySmall)
        if (hasKey) OutlinedButton(onClick = {
            val e = endpoint ?: return@OutlinedButton
            launch { withContext(Dispatchers.IO) { store.removeKey(e.scope) }; key = ""; revision++; message("Saved key removed") }
        }, enabled = !busy, modifier = Modifier.fillMaxWidth()) { Text("Remove saved key") }
        Text("If cleanup fails, your original words are kept. As spoken mode, AI cleanup off, and snippets used on their own work without an API connection.", style = MaterialTheme.typography.bodySmall)
        HorizontalDivider()
        BackupSection(store, data, message)
    }
    models?.let { list ->
        var filter by remember { mutableStateOf("") }
        AlertDialog(onDismissRequest = { models = null }, title = { Text("Choose a model") }, text = {
            Column {
                if (list.isEmpty()) Text("The server listed no chat models.")
                else OutlinedTextField(filter, { filter = it }, label = { Text("Filter") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                LazyColumn(Modifier.heightIn(max = 360.dp)) {
                    items(list.filter { it.contains(filter.trim(), ignoreCase = true) }) { id ->
                        TextButton(onClick = { edit(config.copy(model = id)); models = null }, modifier = Modifier.fillMaxWidth()) { Text(id, Modifier.fillMaxWidth()) }
                    }
                }
            }
        }, confirmButton = { TextButton(onClick = { models = null }) { Text("Close") } })
    }
}

@Composable private fun BackupSection(store: Store, data: LocalData, message: (String) -> Unit) {
    val settings = data.settings
    var drafts by remember(settings.backups) { mutableStateOf(settings.backups) }
    var keys by remember { mutableStateOf(mapOf<Int, String>()) }
    var revision by remember { mutableIntStateOf(0) }
    var review by remember { mutableStateOf<Pair<String, List<CleanupFailover.Identity>>?>(null) }
    var note by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    fun change(index: Int, next: CleanupBackup) { drafts = drafts.mapIndexed { i, b -> if (i == index) next else b }; review = null }
    fun save(next: Settings, done: String) { if (store.update { it.copy(settings = it.settings.copy(backups = next.backups, backupReview = next.backupReview)) }) { note = done; review = null } else note = "Backup settings were not saved." }
    Text("Backup cleanup", style = MaterialTheme.typography.titleMedium)
    Text(when { CleanupFailover.isReviewed(settings) -> "On"; settings.backups.isNotEmpty() -> "Saved, not turned on"; else -> "Off" }, style = MaterialTheme.typography.titleSmall)
    Text("If cleanup fails because a service is down, slow or busy, Parla tries up to two backups in order, within 15 seconds in total. A backup starts only if at least 3 seconds remain. Key, model, content and setup errors never switch services. Backups apply to dictation only, not presets or history retries. Each backup receives your text and may charge you. Any change turns backups off until you review them again.", style = MaterialTheme.typography.bodySmall)
    drafts.forEachIndexed { index, backup ->
        val endpoint = runCatching { backup.endpoint() }.getOrNull()
        val hasKey = remember(endpoint?.scope, revision) { endpoint != null && store.hasKey(endpoint.scope) }
        Text("Backup ${index + 1}", style = MaterialTheme.typography.titleSmall)
        ProviderMenu(backup.provider) { id -> change(index, CleanupBackup(id, ProviderCatalog.default(id).baseUrl, ProviderCatalog.default(id).model)) }
        if (backup.provider == "custom") OutlinedTextField(backup.baseUrl, { change(index, backup.copy(baseUrl = it.take(500))) }, label = { Text("API address") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        if (endpoint != null) Text(accessLabel(endpoint), style = MaterialTheme.typography.bodySmall)
        OutlinedTextField(backup.model, { change(index, backup.copy(model = it.take(200))) }, label = { Text("Model ID") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        if (backup.provider == "custom") Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(backup.keyless, { change(index, backup.copy(keyless = it)) }); Text("No key needed")
        }
        if (!backup.keyless && endpoint != null) {
            Text(if (hasKey) "Uses the key saved for this address." else "No key saved for this address yet.", style = MaterialTheme.typography.bodySmall)
            OutlinedTextField(keys[index].orEmpty(), { keys = keys + (index to it.take(8192)) }, label = { Text("New key for this backup") },
                visualTransformation = PasswordVisualTransformation(), singleLine = true, modifier = Modifier.fillMaxWidth())
            TextButton(onClick = {
                val value = keys[index].orEmpty()
                scope.launch {
                    try { withContext(Dispatchers.IO) { store.saveKey(endpoint.scope, value) }; keys = keys - index; revision++; message("Backup key saved") }
                    catch (c: CancellationException) { throw c } catch (e: Exception) { note = failureText(e) }
                }
            }, enabled = keys[index].orEmpty().isNotBlank()) { Text("Save key") }
        }
        Row {
            if (index > 0) TextButton(onClick = { drafts = drafts.reversed(); review = null }) { Text("Move up") }
            TextButton(onClick = { drafts = drafts.filterIndexed { i, _ -> i != index }; keys = emptyMap(); review = null }) { Text("Remove backup") }
        }
    }
    if (drafts.size < CleanupFailover.MAX_BACKUPS) TextButton(onClick = { drafts = drafts + CleanupBackup(); review = null }) { Text("Add backup") }
    note?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = { save(settings.copy(backups = drafts, backupReview = ""), "Backups saved, not turned on.") }) { Text("Save without turning on") }
        if (settings.backupReview.isNotEmpty()) OutlinedButton(onClick = { save(settings.copy(backupReview = ""), "Backups turned off.") }) { Text("Turn off") }
    }
    Button(onClick = {
        try {
            val next = store.data.value.settings.copy(backups = drafts)
            review = CleanupFailover.digest(next) to CleanupFailover.chain(next).map { it.second }; note = null
        } catch (e: Exception) { note = failureText(e); review = null }
    }, enabled = drafts.isNotEmpty(), modifier = Modifier.fillMaxWidth()) { Text("Review and turn on…") }
    review?.let { (digest, rows) ->
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Confirm these services, in order", style = MaterialTheme.typography.titleSmall)
                rows.forEachIndexed { i, row ->
                    Text((if (i == 0) "Primary" else "Backup $i") + " · " + row.label, style = MaterialTheme.typography.labelLarge)
                    Text(row.endpoint + "\nModel: " + row.model + "\nKey: " + row.key, style = MaterialTheme.typography.bodySmall)
                }
                Button(onClick = {
                    val next = store.data.value.settings.copy(backups = drafts)
                    // The confirmed digest must still describe the current primary and drafts exactly.
                    if (runCatching { CleanupFailover.digest(next) }.getOrNull() != digest) { note = "Settings changed. Review again."; review = null }
                    else save(next.copy(backupReview = digest), "Backups turned on.")
                }) { Text("Turn on backups") }
            }
        }
    }
}

@Composable private fun ProviderMenu(selected: String, select: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        OutlinedButton(onClick = { open = true }) { Text("Service: " + (ProviderCatalog.find(selected)?.label ?: selected)) }
        DropdownMenu(open, { open = false }) {
            ProviderCatalog.all.forEach { preset -> DropdownMenuItem(text = { Text(preset.label) }, onClick = { open = false; select(preset.id) }) }
        }
    }
}
