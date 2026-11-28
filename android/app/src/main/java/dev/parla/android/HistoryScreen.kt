package dev.parla.android

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import java.text.DateFormat
import java.util.Date

internal data class HistoryExportRequest(val scope: String, val rows: List<HistoryEntry>)

/** Package names stay on the device; show the installed app's name when Android lets us read it. */
@Composable internal fun rememberAppLabel(): (String) -> String {
    val pm = LocalContext.current.packageManager
    return remember(pm) {
        val cache = mutableMapOf<String,String>()
        val label: (String) -> String = { pkg -> cache.getOrPut(pkg) {
            runCatching { pm.getApplicationLabel(pm.getApplicationInfo(pkg,PackageManager.ApplicationInfoFlags.of(0))).toString() }.getOrDefault(pkg)
        } }
        label
    }
}

internal fun historyDetails(row: HistoryEntry, appLabel: (String) -> String): String = listOfNotNull(
    row.app.takeIf { it.isNotEmpty() }?.let(appLabel),
    row.model.takeIf { it.isNotEmpty() }?.let(::speechModelLabel),
    row.latencyMs.takeIf { it > 0 }?.let { "Ready in %.1f s".format(it/1000.0) },
    row.cleanupModel.takeIf { it.isNotEmpty() },
    if(row.inputTokens != null || row.outputTokens != null) "${row.inputTokens ?: "?"} in / ${row.outputTokens ?: "?"} out tokens" else null,
).joinToString(" · ")

/** Storage-only retry of a kept row; nothing is recognized or sent again. */
internal fun savePendingEntry(store: Store, id: String): String {
    if(!store.ready) return "Repair saved data in Data recovery first. The text is kept until parla closes."
    if(store.data.value.settings.noHistory) return "Text history is paused in Privacy. Turn it on to save, or copy the text."
    return if(PendingHistory.retry(id) { entry -> store.update { local ->
        if(local.history.any { it.id == entry.id }) local else local.copy(history = (local.history + entry).sortedByDescending { it.createdAt })
    } }) "Saved to history" else "Still not saved. Free storage and try again."
}

/** Always composed by its host so the document pickers survive the dialog. */
@Composable internal fun HistoryExportDialog(request: HistoryExportRequest?, dismiss: () -> Unit, message: (String) -> Unit) {
    val context = LocalContext.current
    val appLabel = rememberAppLabel()
    var content by remember { mutableStateOf(TranscriptExport.Content.result) }
    var format by remember { mutableStateOf(TranscriptExport.Format.text) }
    var pending by remember { mutableStateOf("") }
    val written: (Uri?) -> Unit = { uri ->
        if(uri != null) {
            message(writeHistoryExport(pending) { payload ->
                val output = context.contentResolver.openOutputStream(uri) ?: error("No writable destination")
                output.bufferedWriter().use { it.write(payload) }
            })
            dismiss()
        }
        pending = ""
    }
    val text = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(TranscriptExport.Format.text.mime),written)
    val markdown = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(TranscriptExport.Format.markdown.mime),written)
    if(request == null) return
    val count = request.rows.size
    fun payload() = TranscriptExport.encode(request.rows,content,format,appLabel)
    AlertDialog(onDismissRequest = dismiss, title = { Text("Export $count ${if(count == 1) "dictation" else "dictations"}") }, text = {
        Column {
            Text(request.scope,style = MaterialTheme.typography.bodySmall)
            Text("Text",style = MaterialTheme.typography.titleSmall)
            TranscriptExport.Content.entries.forEach { c -> Row(verticalAlignment = Alignment.CenterVertically) { RadioButton(content == c,{ content = c }); Text(c.label) } }
            Text("File format",style = MaterialTheme.typography.titleSmall)
            TranscriptExport.Format.entries.forEach { f -> Row(verticalAlignment = Alignment.CenterVertically) { RadioButton(format == f,{ format = f }); Text(f.label) } }
            Text("Includes the date and app for each dictation. Notes, models and timings are not exported.",style = MaterialTheme.typography.bodySmall)
        }
    }, confirmButton = { TextButton(onClick = {
        pending = payload()
        (if(format == TranscriptExport.Format.text) text else markdown).launch(format.filename(System.currentTimeMillis()))
    },enabled = count > 0) { Text("Export file") } }, dismissButton = { Row {
        TextButton(onClick = {
            val status = shareHistory(payload()) { body ->
                context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType(format.mime).putExtra(Intent.EXTRA_TEXT,body),"Share text history"))
            }
            if(status.isEmpty()) dismiss() else message(status)
        },enabled = count > 0) { Text("Share") }
        TextButton(onClick = dismiss) { Text("Cancel") }
    } })
}

/** Home entry point: export everything, or open History to search first. */
@Composable internal fun HistoryExportControls(rows: List<HistoryEntry>) {
    var request by remember { mutableStateOf<HistoryExportRequest?>(null) }
    var status by remember { mutableStateOf("") }
    HistoryExportDialog(request,{ request = null }) { status = it }
    Column {
        if(status.isNotEmpty()) Text(status)
        Row {
            TextButton(onClick = { MainActivity.requestedRoute.value = "History" }) { Text("Search history") }
            TextButton(onClick = { status = ""; request = HistoryExportRequest("All saved dictations",rows) },enabled = rows.isNotEmpty()) { Text("Export (${rows.size})") }
        }
    }
}

@Composable internal fun HistoryScreen(rows: List<HistoryEntry>, onCopy: (String) -> Unit, onDelete: (String) -> Unit, onRetry: (HistoryEntry) -> Unit, message: (String) -> Unit, savePending: (String) -> String) {
    val appLabel = rememberAppLabel()
    val pending by PendingHistory.value.collectAsState()
    val cost = remember(rows) { CleanupCostEstimate.over(rows) }
    var query by rememberSaveable { mutableStateOf("") }
    var request by remember { mutableStateOf<HistoryExportRequest?>(null) }
    val filtered = remember(rows,query) { filterHistory(rows,query,appLabel) }
    HistoryExportDialog(request,{ request = null },message)
    LazyColumn(Modifier.fillMaxSize().imePadding(),contentPadding = PaddingValues(16.dp),verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            OutlinedTextField(query,{ query = it.take(200) },Modifier.fillMaxWidth(),label = { Text("Search history") },singleLine = true)
        }
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(if(query.isEmpty()) "${rows.size} saved" else "${filtered.size} of ${rows.size} match",Modifier.weight(1f))
                TextButton(onClick = { request = HistoryExportRequest(if(query.isEmpty()) "All saved dictations" else "Dictations matching your search",filtered) },enabled = filtered.isNotEmpty()) { Text("Export (${filtered.size})") }
            }
        }
        cost?.let { est -> item {
            Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp),verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Estimated cleanup cost",style = MaterialTheme.typography.titleSmall)
                Text("${CleanupCostEstimate.money(est.usd)} · ${est.dictations} ${if(est.dictations == 1) "dictation" else "dictations"} since ${DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(est.since))}" +
                    if(est.unpriced > 0) " · ${est.unpriced} not priced" else "")
                est.monthlyUsd?.let { Text("At this rate: ${CleanupCostEstimate.money(it)}/mo over 30 days") }
                Text("Based on list prices checked ${CleanupPricing.CHECKED}, for dictations in History. Not a bill. Unknown and local models are not priced.",style = MaterialTheme.typography.bodySmall)
            } }
        } }
        items(pending,key = { "pending-" + it.id }) { row ->
            Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp),verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Not saved — kept until parla closes",style = MaterialTheme.typography.titleSmall)
                Text(row.text)
                Row {
                    TextButton(onClick = { message(savePending(row.id)) }) { Text("Try saving again") }
                    TextButton(onClick = { onCopy(row.text) }) { Text("Copy") }
                    TextButton(onClick = { PendingHistory.discard(row.id) }) { Text("Discard",color = MaterialTheme.colorScheme.error) }
                }
            } }
        }
        if(filtered.isEmpty()) item { Text(if(rows.isEmpty()) (if(pending.isEmpty()) "No dictations yet" else "Nothing saved yet") else "No matches for “$query”") }
        items(filtered,key = { it.id }) { row ->
            var original by remember { mutableStateOf(false) }
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp),verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(DateFormat.getDateTimeInstance(DateFormat.MEDIUM,DateFormat.SHORT).format(Date(row.createdAt)),style = MaterialTheme.typography.bodySmall)
                    historyDetails(row,appLabel).takeIf { it.isNotEmpty() }?.let { Text(it,style = MaterialTheme.typography.bodySmall) }
                    Text(if(original) "Original" else "Result",style = MaterialTheme.typography.labelMedium)
                    Text(if(original) row.raw else row.text)
                    Row(Modifier.fillMaxWidth(),horizontalArrangement = Arrangement.SpaceBetween) {
                        TextButton(onClick = { original = !original },contentPadding = PaddingValues(0.dp)) { Text(if(original) "Result" else "Original") }
                        TextButton(onClick = { onCopy(if(original) row.raw else row.text) },contentPadding = PaddingValues(0.dp)) { Text("Copy") }
                        TextButton(onClick = { request = HistoryExportRequest("1 dictation",listOf(row)) },contentPadding = PaddingValues(0.dp)) { Text("Export") }
                        TextButton(onClick = { onRetry(row) },contentPadding = PaddingValues(0.dp)) { Text("Retry") }
                        TextButton(onClick = { onDelete(row.id) },contentPadding = PaddingValues(0.dp)) { Text("Delete",color = MaterialTheme.colorScheme.error) }
                    }
                }
            }
        }
    }
}
