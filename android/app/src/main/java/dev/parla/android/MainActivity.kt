package dev.parla.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings as AndroidSettings
import android.widget.EditText
import android.view.inputmethod.InputMethodManager
import androidx.activity.compose.BackHandler
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.*
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private val Cream = Color(0xFFFFFFEB)
private val Lilac = Color(0xFFF7EBFF)
private val Ink = Color(0xFF1A1A1A)
private val Muted = Neutral500
private val Line = Color(0xFFD3D3D3)
private val Purple = Primary800
private val ParlaColors = lightColorScheme(primary = Primary800, onPrimary = Color.White, secondary = Purple,
    background = PageGray, surface = Color.White, surfaceVariant = Lilac, onSurface = Ink, onBackground = Ink,
    outline = Line, primaryContainer = Lilac, onPrimaryContainer = Ink, error = Color(0xFFA63142))

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestedRoute.value = intent?.getStringExtra("route")
        enableEdgeToEdge()
        if (BuildConfig.DEBUG) android.util.Log.i("ParlaVisualEvidence", "pixels=${resources.displayMetrics.widthPixels}x${resources.displayMetrics.heightPixels}; densityDpi=${resources.displayMetrics.densityDpi}; density=${resources.displayMetrics.density}; fontScale=${resources.configuration.fontScale}; uiMode=${resources.configuration.uiMode}; locale=${resources.configuration.locales[0]}")
        setContent { MaterialTheme(colorScheme = ParlaColors, typography = ParlaTypography) { ParlaApp() } }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent); setIntent(intent)
        requestedRoute.value = intent.getStringExtra("route")
    }
    companion object { internal val requestedRoute = kotlinx.coroutines.flow.MutableStateFlow<String?>(null) }

}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun ParlaApp() {
    val context = LocalContext.current
    val store = remember { Store.get(context) }
    val data by store.data.collectAsStateWithLifecycle()
    val error by store.persistenceError.collectAsStateWithLifecycle()
    val status by ParlaService.status.collectAsStateWithLifecycle()
    val visible by ParlaService.visible.collectAsStateWithLifecycle()
    val recovery by RecoveryVault.value.collectAsStateWithLifecycle()
    val retry = remember { HistoryRetry() }
    var retrySource by remember { mutableStateOf<HistoryEntry?>(null) }
    var proposal by remember { mutableStateOf<RetryProposal?>(null) }
    var retryBusy by remember { mutableStateOf(false) }
    var route by rememberSaveable { mutableStateOf("Home") }
    val drawerState = rememberDrawerState(DrawerValue.Closed)
    var setup by rememberSaveable { mutableStateOf(!data.settings.onboarded) }
    LaunchedEffect(Unit) {
        MainActivity.requestedRoute.collect { requested ->
            if(requested != null) { route = requested; setup = false; MainActivity.requestedRoute.value = null }
        }
    }
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    fun message(text: String) { scope.launch { snackbar.showSnackbar(text) } }
    var refresh by remember { mutableIntStateOf(0) }
    val lifecycle = LocalLifecycleOwner.current
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) refresh++ }
        lifecycle.lifecycle.addObserver(observer)
        onDispose { lifecycle.lifecycle.removeObserver(observer) }
    }
    val microphone = refresh.let { context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED }
    val overlay = refresh.let { AndroidSettings.canDrawOverlays(context) }
    val notifications = refresh.let { context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED }
    val accessibility by ParlaAccessibilityService.connected.collectAsStateWithLifecycle()
    val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { refresh++ }
    fun startRetry(source: HistoryEntry, applyPreset: Boolean) {
        val frozen = data.copy(settings = data.settings.copy(outputMode = if(applyPreset) "selectedPreset" else "cleanup"))
        val token = retry.begin(source)
        retrySource = null; retryBusy = true
        scope.launch {
            try {
                val proposed = retry.propose(token,source,frozen,{ store.readKey(frozen.settings) },applyPreset)
                if(retry.valid(token,source,store.data.value.history)) proposal = proposed
            } catch(c: CancellationException) { throw c }
            catch(e: Exception) { message(e.message ?: "Retry failed. Previous cleaned text is preserved.") }
            finally { retryBusy = false }
        }
    }
    fun startBubble() {
        if (!microphone || !overlay || !accessibility) { setup = true; return }
        try { ParlaService.command(context, ParlaService.SHOW) }
        catch (_: Exception) { message("Could not start parla. Check microphone and overlay permissions.") }
    }
    val tabs = listOf("Home", "Dictionary", "Style", "Snippets")
    val dashboard = route in tabs && !setup
    BackHandler(enabled = setup || !dashboard || drawerState.isOpen) {
        when {
            drawerState.isOpen -> scope.launch { drawerState.close() }
            setup -> setup = false
            else -> route = if (route in listOf("Settings", "Account", "Practice")) "Home" else "Settings"
        }
    }
    ModalNavigationDrawer(
        drawerState = drawerState,
        gesturesEnabled = dashboard,
        drawerContent = {
            ModalDrawerSheet(drawerContainerColor = Color.White) {
                ParlaWordmark(Modifier.padding(24.dp).width(114.dp))
                Spacer(Modifier.height(24.dp))
                DrawerSection("Support")
                DrawerRow("Report an issue", R.drawable.ic_sb_report) { scope.launch { drawerState.close() }; route = "Report an issue" }
                DrawerRow("Share feedback", R.drawable.ic_sb_feedback) { scope.launch { drawerState.close() }; route = "Share feedback" }
                DrawerSection("General")
                DrawerRow("Settings", R.drawable.ic_sb_settings) { scope.launch { drawerState.close() }; route = "Settings" }
                DrawerRow("Account", R.drawable.ic_sb_account) { scope.launch { drawerState.close() }; route = "Account" }
            }
        },
    ) {
    Scaffold(
        containerColor = if (setup) Cream else if (dashboard) PageGray else SettingsGray,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            if (!setup) {
                if (dashboard) CenterAlignedTopAppBar(
                    title = { ParlaWordmark(Modifier.width(114.dp).height(32.dp)) },
                    navigationIcon = { IconButton(onClick = { scope.launch { drawerState.open() } }) { Icon(painterResource(R.drawable.ic_menu), "Open drawer", tint = Color(0xFF191A21)) } },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = PageGray),
                ) else CenterAlignedTopAppBar(
                    title = { Text(route, style = ScreenTitleStyle) },
                    navigationIcon = { IconButton(onClick = { route = if (route in listOf("Settings", "Account", "Practice", "Report an issue", "Share feedback")) "Home" else "Settings" }) { Icon(painterResource(R.drawable.ic_arrow_back), "Back", tint = Ink) } },
                    actions = {
                        if (route == "parla Bubble Size" || route == "parla Bubble Opacity") TextButton(onClick = {
                            store.update { it.copy(settings = if (route == "parla Bubble Size") it.settings.copy(bubbleSize = .85f) else it.settings.copy(bubbleOpacity = .8f)) }
                        }) { Text("Reset", color = Ink) }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = SettingsGray),
                )
            }
        },
        bottomBar = {
            if (dashboard) NavigationBar(containerColor = PageGray, tonalElevation = 0.dp) {
                tabs.forEach { tab ->
                    val icon = when (tab) {
                        "Home" -> if (route == tab) R.drawable.ic_nav_home_selected else R.drawable.ic_nav_home
                        "Dictionary" -> if (route == tab) R.drawable.ic_nav_dict_selected else R.drawable.ic_nav_dict
                        "Style" -> R.drawable.ic_nav_style
                        else -> R.drawable.ic_nav_snippets
                    }
                    NavigationBarItem(
                        selected = route == tab, onClick = { route = tab },
                        icon = { Icon(painterResource(icon), null) },
                        label = { Text(tab, style = NavLabelStyle) },
                        colors = NavigationBarItemDefaults.colors(selectedIconColor = M3Gray, unselectedIconColor = M3Gray, selectedTextColor = Color(0xFF191A21), unselectedTextColor = Neutral500, indicatorColor = Color(0xFFDCDCDD)),
                    )
                }
            }
        }
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            if (setup) {
                SetupScreen(microphone, overlay, accessibility, notifications,
                    recoveryEnabled = data.settings.recoveryAudioEnabled,
                    onRecovery = { enabled -> store.update { it.copy(settings = it.settings.copy(recoveryAudioEnabled = enabled)) } },
                    onMic = { permissions.launch(arrayOf(Manifest.permission.RECORD_AUDIO)) },
                    onOverlay = { context.startActivity(Intent(AndroidSettings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${context.packageName}"))) },
                    onAccess = { context.startActivity(Intent(AndroidSettings.ACTION_ACCESSIBILITY_SETTINGS)) },
                    onNotify = { permissions.launch(arrayOf(Manifest.permission.POST_NOTIFICATIONS)) },
                    onKeyboard = { context.getSystemService(InputMethodManager::class.java).showInputMethodPicker() },
                    onDone = { store.update { it.copy(settings = it.settings.copy(onboarded = true)) }; setup = false; route = "Models" })
            } else when (route) {
                "Home" -> HomeScreen(data, status, visible, recovery, onBubble = { if (visible) ParlaService.command(context, ParlaService.HIDE) else startBubble() },
                    onRecord = { if (!visible) { startBubble() } else ParlaService.command(context, ParlaService.TOGGLE) },
                    onCancel = { ParlaService.command(context, ParlaService.CANCEL) },
                    onPractice = { route = "Practice" },
                    onApi = { route = "Models" },
                    onCopy = { copyPrivate(context, it); message("Copied to clipboard") },
                    onDelete = { id -> retry.invalidate(id); store.update { it.copy(history = it.history.filterNot { row -> row.id == id }) } },
                    onRetry = { entry -> retrySource = entry }, onClear = { retry.clear(); store.update { it.copy(history = emptyList()) } })
                "Dictionary" -> DictionaryScreen(data.dictionary) { words -> store.update { it.copy(dictionary = words) } }
                "Snippets" -> SnippetsScreen(data.snippets) { snippets -> store.update { it.copy(snippets = snippets) } }
                "Style", "Output settings" -> OutputScreen(data,store,::message)
                "Models" -> ModelsScreen(store)
                "Profiles" -> ProfilesScreen(data,store,::message)
                "Recovery audio" -> AudioRecoveryScreen(store,::message)
                "Data recovery" -> DataRecoveryScreen(store,::message)
                "Settings" -> SettingsScreen(data, store.hasKey, onRoute = { route = it }, onSetup = { setup = true })
                "API connection" -> ApiScreen(store, data.settings, ::message)
                "Languages" -> LanguageScreen(data.settings.language) { language -> store.update { it.copy(settings = it.settings.copy(language = language)) } }
                "Voice control position" -> PositionScreen(data.settings) { settings -> store.update { it.copy(settings = settings) } }
                "parla Bubble Size", "parla Bubble Opacity" -> BubbleScreen(data.settings, route == "parla Bubble Opacity") { settings -> store.update { it.copy(settings = settings) } }
                "Account" -> AccountScreen(onApi = { route = "API connection" }, onPrivacy = { route = "Privacy" })
                "Report an issue", "Share feedback" -> FeedbackScreen(route, onCopy = { copyPrivate(context, it); message("Copied to clipboard") })
                "Privacy" -> PrivacyScreen(data, onSettings = { settings -> store.update { it.copy(settings = settings) } }, onClear = { retry.clear(); if(store.update { it.copy(history = emptyList()) }) message("History cleared") })
                "Practice" -> PracticeScreen(visible, ::startBubble)
            }
            if (error != null) Column(Modifier.align(Alignment.BottomCenter).background(Cream).padding(12.dp)) {
                Text(error!!, color = MaterialTheme.colorScheme.error, fontSize = 12.sp)
                TextButton(onClick = { setup = false; route = "Data recovery" }) { Text("Reload / repair data") }
            }
        }
    }
    }
    retrySource?.let { source ->
        AlertDialog(onDismissRequest = { retrySource = null }, title = { Text("Retry original text") },
            text = { Text("Use current global settings with unknown destination. No speech recognition or insertion. A proposed result is shown before saving.") },
            confirmButton = { TextButton(onClick = { startRetry(source,false) }, enabled = !retryBusy) { Text("Cleanup original") } },
            dismissButton = { Row { TextButton(onClick = { startRetry(source,true) }, enabled = !retryBusy && data.presets.any { it.id == data.settings.selectedPresetID }) { Text("Apply selected preset") }; TextButton(onClick = { retrySource = null }) { Text("Cancel") } } })
    }
    proposal?.let { p ->
        AlertDialog(onDismissRequest = { retry.invalidate(p.source.id); proposal = null }, title = { Text("Proposed text") },
            text = { Column(Modifier.verticalScroll(rememberScrollState())) { Text(p.summary); Text("Original: " + p.source.raw); Text("Previous: " + p.source.text); Text("Proposed: " + p.result) } },
            confirmButton = { TextButton(onClick = {
                if(retry.valid(p.token,p.source,store.data.value.history)) {
                    if(store.update { it.copy(history = it.history.map { row -> if(row == p.source) row.copy(text = p.result,revision = row.revision+1,note = p.summary) else row }) }) { retry.invalidate(p.source.id); proposal = null; message("Proposed result saved") }
                } else { proposal = null; message("Row changed or was deleted. Start a new retry.") }
            }) { Text("Apply to saved row") } },
            dismissButton = { Row { TextButton(onClick = { if(retry.valid(p.token,p.source,store.data.value.history)) { copyPrivate(context,p.result); message("Copied proposed text") } else message("Row changed or was deleted") }) { Text("Copy") }; TextButton(onClick = { retry.invalidate(p.source.id); proposal = null }) { Text("Discard") } } })
    }
}

@Composable
private fun ParlaWordmark(modifier: Modifier = Modifier) {
    Text("parla", modifier, fontFamily = Figtree, fontWeight = FontWeight.SemiBold, fontSize = 28.sp, lineHeight = 32.sp, color = Ink, textAlign = TextAlign.Center)
}

@Composable
private fun ParlaLogo(modifier: Modifier = Modifier) {
    Image(painterResource(R.drawable.ic_parla_mark), null, modifier)
}
@Composable
private fun PageTitle(title: String, description: String? = null) {
    Column(Modifier.padding(bottom = 16.dp)) {
        Text(title, style = ScreenTitleStyle)
        if (description != null) { Spacer(Modifier.height(8.dp)); Text(description, color = Muted, style = BodyStyle) }
    }
}
@Composable
private fun Card(content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Color.White).padding(16.dp), content = content)
}
@Composable
private fun SetupScreen(mic: Boolean, overlay: Boolean, access: Boolean, notify: Boolean, recoveryEnabled: Boolean, onRecovery: (Boolean) -> Unit, onMic: () -> Unit, onOverlay: () -> Unit, onAccess: () -> Unit, onNotify: () -> Unit, onKeyboard: () -> Unit, onDone: () -> Unit) {
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("Your voice. Your keyboard.", fontFamily = Garamond, fontSize = 36.sp, lineHeight = 42.sp, color = M3Gray)
        Text("Keep Gboard or your usual keyboard selected. The parla voice control floats above it. Tap to speak and tap the check mark to finish, or hold to talk.", style = BodyStyle, color = Ink)
        OutlinedButton(onClick = onKeyboard, modifier = Modifier.fillMaxWidth()) { Text("Choose Gboard or your usual keyboard") }
        PermissionRow("Display over apps", "Shows the small draggable parla voice control alongside your keyboard.", overlay, "Enable", onOverlay)
        PermissionRow("Text insertion", "Enable parla text insertion in Accessibility. It checks the original editor and selection, skips sensitive fields, and uses keyboard-window bounds for placement. No screenshots or general screen text are collected.", access, "Open settings", onAccess)
        PermissionRow("Microphone", "Used only after an explicit tap or hold on the voice control. Speech is transcribed on device with a model you explicitly download.", mic, "Allow", onMic)
        Card {
            Row(verticalAlignment = Alignment.CenterVertically) { Text("Keep failed audio for recovery",Modifier.weight(1f)); Switch(recoveryEnabled,onRecovery) }
            Text("When enabled, failed recognition and interrupted completed recordings remain privately on this device for 7 days by default (1–30 in Privacy), up to 128MiB total. Successful, canceled and private sessions are disposed. Audio never uploads. This is independent of text history; manage/delete audio in Settings → Recovery audio.",style = BodyStyle)
        }
        PermissionRow("Notifications", "Finish, cancel or stop parla from its ongoing notification.", notify, "Allow", onNotify)
        Text("Download and select a local model on the next screen. An API key is optional for text cleanup. Then choose Show parla control on Home to enable it while this app is visible. Dragging switches to manual placement; turn Follow keyboard back on in Settings to dock above the keyboard again.", style = BodyStyle, color = Muted)
        Button(onClick = onDone, modifier = Modifier.fillMaxWidth().height(54.dp), shape = RoundedCornerShape(6.dp), colors = ButtonDefaults.buttonColors(containerColor = Ink)) { Text("Continue to app") }
    }
}
@Composable
private fun PermissionRow(title: String, detail: String, granted: Boolean, action: String, onClick: () -> Unit) {
    Card {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            TextButton(onClick = onClick) { Text(if (granted) "Enabled" else action) }
        }
        Text(detail, color = Muted, style = BodyStyle)
    }
}

@Composable
private fun HomeScreen(data: LocalData, status: DictationStatus, visible: Boolean, recovery: RecoveryResult?, onBubble: () -> Unit, onRecord: () -> Unit, onCancel: () -> Unit, onPractice: () -> Unit, onApi: () -> Unit, onCopy: (String) -> Unit, onDelete: (String) -> Unit, onRetry: (HistoryEntry) -> Unit, onClear: () -> Unit) {
    var clear by remember { mutableStateOf(false) }
    val words = data.history.sumOf { it.text.split(Regex("""\s+""")).count(String::isNotBlank) }
    val grouped = data.history.groupBy { SimpleDateFormat("MMMM d", Locale.getDefault()).format(Date(it.createdAt)) }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(horizontal = 16.dp, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        if (status.phase == Phase.ERROR) item { Card { Text(status.message, color = MaterialTheme.colorScheme.error); TextButton(onClick = onApi) { Text("Models / local speech setup") } } }
        item {
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(22.5.dp)).background(Color.White).padding(horizontal = 48.dp, vertical = 32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("${java.text.NumberFormat.getIntegerInstance().format(words)} words", fontFamily = Garamond, fontSize = if (words >= 10000) 52.sp else 60.sp, lineHeight = 57.sp, color = Color(0xFF007A5A), textAlign = TextAlign.Center)
                Spacer(Modifier.height(8.dp))
                Text("spoken so far", style = TranscriptStyle, textAlign = TextAlign.Center)
                Spacer(Modifier.height(4.dp))
                Text(if (words == 0) "Start dictating to track your progress." else "", style = BodyStyle, color = Muted, textAlign = TextAlign.Center)
            }
        }
        item {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                Box(Modifier.size(6.dp).clip(CircleShape).background(Color(0xFF312D37)))
            }
        }
        if (data.history.isEmpty()) item {
            Text("It’s quiet here", Modifier.fillMaxWidth().padding(top = 48.dp), fontFamily = Garamond, fontSize = 60.sp, lineHeight = 57.sp, color = Muted, textAlign = TextAlign.Center)
        }
        grouped.forEach { (day, entries) ->
            item(key = "day-$day") { Text(day, style = DayStyle, color = Ink, modifier = Modifier.padding(top = 16.dp)) }
            items(entries, key = { it.id }) { entry -> HistoryCard(entry, onCopy, { onDelete(entry.id) }, { onRetry(entry) }) }
        }
        item {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                TextButton(onClick = onBubble) { Text(if (visible) "Hide parla control" else "Show parla control") }
                TextButton(onClick = onPractice) { Text("Try it here") }
            }
        }
        if (visible && status.phase != Phase.IDLE) item {
            Card {
                Text(status.message, style = BodyStyle)
                TextButton(onClick = if (status.phase == Phase.RECORDING) onRecord else onCancel) { Text(if (status.phase == Phase.RECORDING) "Done" else "Cancel") }
                if (status.phase == Phase.RECORDING) TextButton(onClick = onCancel) { Text("Cancel") }
            }
        }
        recovery?.takeIf { it.expiresAt > System.currentTimeMillis() }?.let { pending -> item {
            Card {
                Text(pending.outcome)
                Text("Transient recovery: RAM only, expires within 5 minutes, 64KiB combined text limit.",color = Muted,fontSize = 12.sp)
                var showOriginal by remember { mutableStateOf(false) }
                Text(if(showOriginal) pending.original else pending.result,style = TranscriptStyle)
                Row { TextButton(onClick = { showOriginal = !showOriginal }) { Text(if(showOriginal) "Result" else "Original") }
                    TextButton(onClick = { RecoveryVault.current()?.takeIf { it.operationID == pending.operationID }?.let { onCopy(if(showOriginal) it.original else it.result) } }) { Text("Copy") }
                    TextButton(onClick = { RecoveryVault.clear() }) { Text("Dismiss") } }
            }
        } }
        if(data.history.isNotEmpty()) item { HistoryExportControls(data.history) }
        if (data.history.isNotEmpty()) item { TextButton(onClick = { clear = true }) { Text("Clear history", color = MaterialTheme.colorScheme.error) } }
        item { Spacer(Modifier.height(24.dp)) }
    }
    if (clear) ConfirmDialog("Clear all history?", "This removes saved text from this device.", { clear = false }, { onClear(); clear = false })
}
@Composable
private fun HistoryCard(entry: HistoryEntry, onCopy: (String) -> Unit, onDelete: () -> Unit, onRetry: () -> Unit) {
    var raw by remember { mutableStateOf(false) }
    val displayedText = if (raw) entry.raw else entry.text
    Card {
        Text(SimpleDateFormat("h:mm a", Locale.getDefault()).format(Date(entry.createdAt)), color = Color(0xFFB0ABB2), fontSize = 14.sp, lineHeight = 20.sp)
        Spacer(Modifier.height(12.dp)); Text(displayedText, style = TranscriptStyle)
        if (entry.note.isNotBlank()) { Spacer(Modifier.height(10.dp)); Text(entry.note, color = Muted, fontSize = 11.sp, lineHeight = 16.sp) }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            TextButton(onClick = { onCopy(displayedText) }, contentPadding = PaddingValues(0.dp)) { Text("Copy", fontSize = 12.sp) }
            TextButton(onClick = { raw = !raw }, contentPadding = PaddingValues(0.dp)) { Text(if (raw) "Cleaned" else "Original", fontSize = 12.sp) }
            TextButton(onClick = onRetry, contentPadding = PaddingValues(0.dp)) { Text("Retry", fontSize = 12.sp) }
            TextButton(onClick = onDelete, contentPadding = PaddingValues(0.dp)) { Text("Delete", fontSize = 12.sp, color = MaterialTheme.colorScheme.error) }
        }
    }
}

@Composable
private fun DictionaryScreen(words: List<String>, onChange: (List<String>) -> Unit) {
    var edit by remember { mutableStateOf<String?>(null) }
    var value by remember { mutableStateOf("") }
    var dialog by remember { mutableStateOf(false) }
    var search by rememberSaveable { mutableStateOf("") }
    val filtered = words.filter { it.contains(search, true) }
    fun editWord(word: String?) { edit = word; value = word.orEmpty(); dialog = true }
    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            ListSearch(search) { search = it }
            Text("Saved order is priority. Hints: 256 UTF-8 bytes each; ASR 2048 bytes, cleanup 8192 bytes. Later hints may be omitted.",Modifier.padding(horizontal = 16.dp),fontSize = 12.sp,color = Muted)
            if (filtered.isEmpty()) CenteredListMessage(if (words.isEmpty()) "Your dictionary words show up here." else "No words match your search")
            else LazyColumn(contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 96.dp)) {
                items(filtered, key = { it }) { word ->
                    Column {
                        EditableListRow(word, onEdit = { editWord(word) }, onDelete = { onChange(words - word) })
                        val index = words.indexOf(word)
                        Row {
                            TextButton(onClick = { onChange(VocabularyHints.move(words,index,-1)) },enabled = index > 0) { Text("Move up") }
                            TextButton(onClick = { onChange(VocabularyHints.move(words,index,1)) },enabled = index < words.lastIndex) { Text("Move down") }
                        }
                    }
                }
            }
        }
        ListAddButton("Add word", Modifier.align(Alignment.BottomEnd)) { editWord(null) }
    }
    if (dialog) AlertDialog(
        onDismissRequest = { dialog = false }, shape = RoundedCornerShape(16.dp), containerColor = Color.White,
        title = { Text(if (edit == null) "Add word" else "Edit word", style = TranscriptStyle) },
        text = { OutlinedTextField(value, { value = it.take(256) }, placeholder = { Text("Enter a word") }, supportingText = { Text("${value.trim().toByteArray(Charsets.UTF_8).size} / 256 UTF-8 bytes") }, singleLine = true, textStyle = BodyStyle) },
        confirmButton = { TextButton(onClick = { onChange(if(edit == null) words + value.trim() else words.map { if(it == edit) value.trim() else it }); dialog = false }, enabled = value.isNotBlank() && value.trim().toByteArray(Charsets.UTF_8).size <= 256 && (value.trim() == edit || words.none { it.equals(value.trim(), true) }) && (edit != null || words.size < 1000)) { Text(if (edit == null) "Add" else "Save") } },
        dismissButton = { TextButton(onClick = { dialog = false }) { Text("Cancel", color = M3Gray) } },
    )
}
@Composable
private fun SnippetsScreen(snippets: List<Snippet>, onChange: (List<Snippet>) -> Unit) {
    var edit by remember { mutableStateOf<Snippet?>(null) }
    var trigger by remember { mutableStateOf("") }
    var expansion by remember { mutableStateOf("") }
    var dialog by remember { mutableStateOf(false) }
    var search by rememberSaveable { mutableStateOf("") }
    val filtered = snippets.filter { it.trigger.contains(search, true) || it.expansion.contains(search, true) }
    fun editSnippet(snippet: Snippet?) { edit = snippet; trigger = snippet?.trigger.orEmpty(); expansion = snippet?.expansion.orEmpty(); dialog = true }
    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            ListSearch(search) { search = it }
            if (filtered.isEmpty()) CenteredListMessage(if (snippets.isEmpty()) "Your Snippets show up here." else "No Snippets match your search")
            else LazyColumn(contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 96.dp)) {
                items(filtered, key = { it.id }) { snippet -> EditableListRow(snippet.trigger, snippet.expansion, { editSnippet(snippet) }, { onChange(snippets.filterNot { it.id == snippet.id }) }) }
            }
        }
        ListAddButton("Add snippet", Modifier.align(Alignment.BottomEnd)) { editSnippet(null) }
    }
    if (dialog) AlertDialog(
        onDismissRequest = { dialog = false }, shape = RoundedCornerShape(16.dp), containerColor = Color.White,
        title = { Text(if (edit == null) "Add snippet" else "Edit snippet", style = TranscriptStyle) },
        text = { Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            OutlinedTextField(trigger, { trigger = it.take(60) }, label = { Text("Snippet") }, singleLine = true)
            OutlinedTextField(expansion, { expansion = it.take(4000) }, label = { Text("Expansion") }, minLines = 3, maxLines = 6)
        } },
        confirmButton = { TextButton(onClick = {
            val next = edit?.copy(trigger = trigger.trim(), expansion = expansion.trim()) ?: Snippet(trigger = trigger.trim(), expansion = expansion.trim())
            onChange(snippets.filterNot { it.id == next.id } + next); dialog = false
        }, enabled = trigger.isNotBlank() && expansion.isNotBlank() && snippets.none { it.id != edit?.id && it.trigger.equals(trigger.trim(), true) } && (edit != null || snippets.size < 250)) { Text(if (edit == null) "Add" else "Save") } },
        dismissButton = { TextButton(onClick = { dialog = false }) { Text("Cancel", color = M3Gray) } },
    )
}
@Composable
private fun ListSearch(value: String, onChange: (String) -> Unit) {
    OutlinedTextField(value, onChange, Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).height(54.dp),
        placeholder = { Text("Search", style = BodyStyle) }, leadingIcon = { Icon(painterResource(R.drawable.ic_search), "Search", tint = M3Gray) },
        singleLine = true, shape = RoundedCornerShape(8.dp), textStyle = BodyStyle,
        colors = OutlinedTextFieldDefaults.colors(unfocusedBorderColor = Color.Transparent, focusedBorderColor = Primary800, unfocusedContainerColor = Color.White, focusedContainerColor = Color.White))
}
@Composable
private fun ColumnScope.CenteredListMessage(text: String) {
    Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) { Text(text, Modifier.padding(horizontal = 32.dp), style = TranscriptStyle, color = Muted, textAlign = TextAlign.Center) }
}
@Composable
private fun ListAddButton(description: String, modifier: Modifier, onClick: () -> Unit) {
    FloatingActionButton(onClick, modifier.padding(16.dp), containerColor = Primary800, contentColor = Color.White, shape = CircleShape) { Icon(painterResource(R.drawable.add), description) }
}
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun EditableListRow(title: String, subtitle: String? = null, onEdit: () -> Unit, onDelete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    var delete by remember { mutableStateOf(false) }
    val currentEdit by rememberUpdatedState(onEdit)
    val state = rememberSwipeToDismissBoxState(confirmValueChange = { direction ->
        if (direction == SwipeToDismissBoxValue.StartToEnd) currentEdit()
        if (direction == SwipeToDismissBoxValue.EndToStart) delete = true
        false
    })
    SwipeToDismissBox(state, backgroundContent = {
        Row(Modifier.fillMaxSize().background(if (state.dismissDirection == SwipeToDismissBoxValue.StartToEnd) Primary800 else Color(0xFFEF5E68)).padding(16.dp), horizontalArrangement = if (state.dismissDirection == SwipeToDismissBoxValue.StartToEnd) Arrangement.Start else Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
            Icon(painterResource(if (state.dismissDirection == SwipeToDismissBoxValue.StartToEnd) R.drawable.edit else R.drawable.ic_delete), null, tint = Color.White)
        }
    }) {
        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).background(Color.White).clickable(onClick = onEdit).padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f).padding(vertical = 8.dp)) {
                Text(title, style = TranscriptStyle, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (subtitle != null) Text(subtitle, style = BodyStyle, color = Muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Box {
                IconButton(onClick = { menu = true }) { Icon(painterResource(R.drawable.ic_bar_menu), "More options", Modifier.size(24.dp), tint = M3Gray) }
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem(text = { Text("Edit") }, onClick = { menu = false; onEdit() })
                    DropdownMenuItem(text = { Text("Delete") }, onClick = { menu = false; delete = true })
                }
            }
        }
    }
    if (delete) AlertDialog(onDismissRequest = { delete = false }, shape = RoundedCornerShape(16.dp), containerColor = Color.White,
        text = { Text("Are you sure you want to delete \"$title\"?", style = TranscriptStyle) },
        confirmButton = { TextButton(onClick = { delete = false; onDelete() }) { Text("Delete", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { delete = false }) { Text("Cancel", color = M3Gray) } })
}
@Composable
private fun SettingsScreen(data: LocalData, hasKey: Boolean, onRoute: (String) -> Unit, onSetup: () -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) {
        SettingsSection("GENERAL")
        SettingsRow("Models", data.settings.localModel) { onRoute("Models") }
        SettingsRow("Output settings", data.settings.outputMode) { onRoute("Output settings") }
        SettingsRow("Profiles") { onRoute("Profiles") }
        SettingsRow("Recovery audio",if(data.settings.recoveryAudioEnabled) "${data.settings.recoveryAudioDays} days" else "Retention off") { onRoute("Recovery audio") }
        SettingsRow("Data recovery") { onRoute("Data recovery") }
        SettingsRow("Languages", languageName(data.settings.language)) { onRoute("Languages") }
        Spacer(Modifier.height(8.dp))
        SettingsRow("parla Bubble Size") { onRoute("parla Bubble Size") }
        Spacer(Modifier.height(8.dp))
        SettingsRow("parla Bubble Opacity") { onRoute("parla Bubble Opacity") }
        Spacer(Modifier.height(8.dp))
        SettingsRow("Voice control position", if (data.settings.bubbleDocked) "Follow keyboard" else "Manual") { onRoute("Voice control position") }
        SettingsSection("DATA & PRIVACY")
        SettingsRow("Local Data Storage", if (data.settings.noHistory) "Off" else "On") { onRoute("Privacy") }
        SettingsSection("GENERAL")
        SettingsRow("API connection", if (hasKey) data.settings.cleanupModel else "Optional") { onRoute("API connection") }
        Spacer(Modifier.height(8.dp))
        SettingsRow("Permissions", onClick = onSetup)
    }
}
@Composable
private fun SettingsSection(title: String) {
    Text(title, Modifier.padding(start = 16.dp, top = 24.dp, bottom = 12.dp), color = Muted, fontSize = 14.sp, lineHeight = 14.sp, fontWeight = FontWeight.SemiBold, letterSpacing = .28.sp)
}
@Composable
private fun SettingsRow(title: String, subtitle: String? = null, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Color.White).clickable(onClick = onClick).padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) { Text(title, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, lineHeight = 24.sp); if (subtitle != null) Text(subtitle, color = Muted, fontSize = 15.sp, lineHeight = 20.sp) }
        Icon(painterResource(R.drawable.ic_chevron_right), null, Modifier.size(24.dp), tint = Muted)
    }
}
@Composable
private fun DrawerSection(title: String) { Text(title, Modifier.padding(start = 24.dp, top = 24.dp, bottom = 8.dp), color = Muted, fontSize = 14.sp, fontWeight = FontWeight.SemiBold) }
@Composable
private fun DrawerRow(label: String, icon: Int, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 24.dp, vertical = 16.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(painterResource(icon), null, Modifier.size(24.dp), tint = Muted); Spacer(Modifier.width(16.dp)); Text(label, style = BodyStyle, fontWeight = FontWeight.SemiBold)
    }
}
@Composable
private fun AccountScreen(onApi: () -> Unit, onPrivacy: () -> Unit) {
    // Private authentication, subscription and cloud account state are excluded.
    Column(Modifier.fillMaxSize().padding(16.dp)) {
        SettingsRow("API connection", onClick = onApi)
        Spacer(Modifier.height(8.dp))
        SettingsRow("Local Data Storage", onClick = onPrivacy)
    }
}
@Composable
private fun FeedbackScreen(title: String, onCopy: (String) -> Unit) {
    var text by rememberSaveable { mutableStateOf("") }
    Column(Modifier.fillMaxSize().imePadding().padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        OutlinedTextField(text, { text = it.take(4000) }, Modifier.fillMaxWidth().weight(1f), label = { Text(title) })
        Button(onClick = { onCopy(text) }, enabled = text.isNotBlank(), modifier = Modifier.fillMaxWidth()) { Text("Copy") }
    }
}
@Composable
private fun ApiScreen(store: Store, settings: Settings, message: (String) -> Unit) {
    var base by remember { mutableStateOf(settings.baseUrl) }
    var provider by remember { mutableStateOf(settings.provider) }
    var cleanup by remember { mutableStateOf(settings.cleanupModel) }
    var key by remember { mutableStateOf("") }
    var hasKey by remember { mutableStateOf(store.hasKey) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val url = base.trim().trimEnd('/').toHttpUrlOrNull()
    val valid = url != null && url.isHttps && url.username.isEmpty() && url.password.isEmpty() && url.query == null && url.fragment == null && cleanup.isNotBlank()
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).imePadding().padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        PageTitle("Connect your API.", "Speech stays on device. Optional text cleanup sends dictated text and saved vocabulary/snippets to your chosen provider. Save explicitly binds your key to this provider and endpoint; changing either requires this confirmation.")
        OutlinedTextField(base, { base = it.take(500) }, label = { Text("HTTPS base URL") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        Text("Text provider")
        listOf("openai-compatible","anthropic").forEach { choice -> Row(verticalAlignment = Alignment.CenterVertically) { RadioButton(provider == choice,{ provider = choice; if(choice == "anthropic") { base = "https://api.anthropic.com/v1"; cleanup = "claude-haiku-4-5" } else { base = "https://api.openai.com/v1"; cleanup = "gpt-4.1-mini" } }); Text(choice) } }
        Text("Apple Intelligence is unavailable on Android. Selecting a remote provider is explicit.",fontSize = 12.sp)
        OutlinedTextField(cleanup, { cleanup = it.take(100) }, label = { Text("Cleanup model") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(key, { key = it.take(8192) }, label = { Text(if (hasKey) "Replace saved key (optional)" else "API key") }, visualTransformation = PasswordVisualTransformation(), singleLine = true, modifier = Modifier.fillMaxWidth())
        Text(if (hasKey) "A key is saved in encrypted device storage. Leave this field blank to keep it." else "Your key is encrypted using AndroidKeyStore and excluded from backups.", color = Muted, fontSize = 12.sp, lineHeight = 19.sp)
        if (error != null) Text(error!!, color = MaterialTheme.colorScheme.error, fontSize = 13.sp)
        Button(onClick = {
            busy = true; error = null
            val savedKey = key
            val savedBase = base.trim().trimEnd('/')

            val savedCleanup = cleanup.trim()
            scope.launch {
                try {
                    withContext(Dispatchers.IO) { store.saveConnection(settings.copy(provider = provider,baseUrl = savedBase,cleanupModel = savedCleanup),savedKey) }
                    hasKey = store.hasKey; key = ""; message("API settings saved. No test request was sent.")
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (failure: Exception) { error = failure.message ?: "Could not save your key." }
                finally { busy = false }
            }
        }, enabled = valid && !busy, modifier = Modifier.fillMaxWidth().height(52.dp)) { Text(if (busy) "Saving…" else "Save API settings") }
        if (hasKey) OutlinedButton(onClick = {
            scope.launch {
                busy = true; error = null
                try {
                    withContext(Dispatchers.IO) { store.saveKey("") }
                    key = ""; hasKey = store.hasKey; message("Saved key removed")
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { error = "Saved key could not be removed. Check device storage and try again." }
                finally { busy = false }
            }
        }, enabled = !busy, modifier = Modifier.fillMaxWidth()) { Text("Remove saved key") }
        Text("No audio is uploaded. OpenAI-compatible cleanup uses /chat/completions; Anthropic uses its fixed /v1/messages endpoint. Requests have a 15-second deadline. Failures keep the original transcript. Raw mode, cleanup-off, and locked snippets need no API key.", color = Muted, fontSize = 12.sp, lineHeight = 19.sp)
    }
}
private val Languages = listOf("auto" to "Follow the speaker automatically") + SpeechLanguages.all
private fun languageName(code: String) = Languages.firstOrNull { it.first == code }?.second ?: code
@Composable
private fun LanguageScreen(selected: String, onSelect: (String) -> Unit) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(24.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        item { PageTitle("Languages") }
        items(Languages) { (code, name) -> Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(if (code == selected) Lilac else Cream).clickable { onSelect(code) }.padding(16.dp), verticalAlignment = Alignment.CenterVertically) { Text(name, modifier = Modifier.weight(1f)); RadioButton(selected == code, { onSelect(code) }) } }
    }
}
@Composable
private fun BubbleScreen(settings: Settings, opacity: Boolean, onChange: (Settings) -> Unit) {
    val stops = if (opacity) listOf(.2f, .4f, .6f, .8f, 1f) else listOf(.7f, .85f, 1f, 1.15f)
    val value = if (opacity) settings.bubbleOpacity else settings.bubbleSize
    Column(Modifier.fillMaxSize().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
            Box(Modifier.size((56 * settings.bubbleSize).dp).clip(RoundedCornerShape((16 * settings.bubbleSize).dp)).background(Lilac.copy(alpha = settings.bubbleOpacity)), contentAlignment = Alignment.Center) { ParlaLogo(Modifier.size((28 * settings.bubbleSize).dp)) }
        }
        Slider(value.coerceIn(stops.first(), stops.last()), { next ->
            val snapped = stops.minBy { kotlin.math.abs(it - next) }
            onChange(if (opacity) settings.copy(bubbleOpacity = snapped) else settings.copy(bubbleSize = snapped))
        }, valueRange = stops.first()..stops.last(), steps = stops.size - 2)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) { stops.forEach { Text("${(it * 100).toInt()}%", fontSize = 12.sp, color = Muted) } }
        Spacer(Modifier.height(32.dp))
    }
}
@Composable
private fun PositionScreen(settings: Settings, onChange: (Settings) -> Unit) {
    Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        PageTitle("Voice control position")
        Card {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Follow keyboard", modifier = Modifier.weight(1f))
                Switch(settings.bubbleDocked, { onChange(settings.copy(bubbleDocked = it)) })
            }
            Text("Places parla above the keyboard when Android reports its window bounds. Dragging switches to manual placement. Floating or split keyboards may need manual adjustment.", color = Muted, style = BodyStyle)
        }
        OutlinedButton(onClick = { onChange(settings.copy(bubbleX = 16, bubbleY = 280, bubbleDocked = true)) }) { Text("Reset position") }
    }
}
@Composable
private fun PrivacyScreen(data: LocalData, onSettings: (Settings) -> Unit, onClear: () -> Unit) {
    var clear by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        PageTitle("Local Data Storage")
        Card {
            Row(verticalAlignment = Alignment.CenterVertically) { Text("No local history", fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f)); Switch(data.settings.noHistory, { onSettings(data.settings.copy(noHistory = it)) }) }
            Text("Turning this on stops new text history without deleting saved rows. Use Clear separately. Transient recovery is RAM only, expires after 5 minutes, and holds at most 64KiB combined original/result text.", color = Muted, fontSize = 13.sp, lineHeight = 20.sp)
        }
        var limit by remember(data.settings.historyLimit) { mutableStateOf(data.settings.historyLimit.toString()) }
        OutlinedTextField(limit,{ limit = it.filter(Char::isDigit).take(4) },label = { Text("Saved history count (1–1000)") })
        Button(onClick = { limit.toIntOrNull()?.takeIf { it in 1..1000 }?.let { onSettings(data.settings.copy(historyLimit = it)) } }, enabled = limit.toIntOrNull() in 1..1000) { Text("Save count") }
        Row(verticalAlignment = Alignment.CenterVertically) { Text("Retain failed recovery audio",Modifier.weight(1f)); Switch(data.settings.recoveryAudioEnabled,{ onSettings(data.settings.copy(recoveryAudioEnabled = it)) }) }
        var days by remember(data.settings.recoveryAudioDays) { mutableStateOf(data.settings.recoveryAudioDays.toString()) }
        OutlinedTextField(days,{ days = it.filter(Char::isDigit).take(2) },label = { Text("Audio retention days (1–30)") })
        Button(onClick = { days.toIntOrNull()?.takeIf { it in 1..30 }?.let { onSettings(data.settings.copy(recoveryAudioDays = it)) } },enabled = days.toIntOrNull() in 1..30) { Text("Save audio retention") }
        Text("Editor context is not sent. App categories and exact package profiles resolve locally. Android has no trusted browser URL metadata, so site profiles are unavailable.",fontSize = 13.sp)
        OutlinedButton(onClick = { clear = true }, enabled = data.history.isNotEmpty(), modifier = Modifier.fillMaxWidth()) { Text("Clear saved history (${data.history.size})") }
        Text("Capture uses private temporary cache. When recovery is enabled, complete audio is atomically saved before recognition; failed/interrupted recognition stays until expiry or explicit deletion. Successful recognition disposes audio even if cleanup fails. Canceled/private sessions are purged after readers exit. Recovery is private, excluded from backup, at most 300 seconds per file and 128MiB total (128 files). Existing schema 1/2 installs keep recovery off until opt-in. Turning retention off stops new stashes; use Recovery audio to delete existing files. Text-history controls never change audio retention. Optional text providers have their own retention policies.", color = Muted, fontSize = 12.sp, lineHeight = 20.sp)
    }
    if (clear) ConfirmDialog("Clear saved history?", "This removes text history from this device.", { clear = false }, { onClear(); clear = false })
}
@Composable
private fun PracticeScreen(visible: Boolean, onBubble: () -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).imePadding().padding(24.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        PageTitle("Try it here", "Keep Gboard selected, tap this field, then tap the floating parla control or hold it to speak.")
        if (!visible) Button(onClick = onBubble, modifier = Modifier.fillMaxWidth()) { Text("Show parla control") }
        AndroidView(factory = { context -> EditText(context).apply {
            hint = "Your words go here…"; minLines = 6; gravity = android.view.Gravity.TOP
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE or android.text.InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            setTextColor(android.graphics.Color.rgb(26,26,26)); setHintTextColor(android.graphics.Color.rgb(116,113,128)); textSize = 18f
            setPadding(30,30,30,30); setBackgroundColor(android.graphics.Color.rgb(247,235,255))
            contentDescription = "Practice editor"
        } }, modifier = Modifier.fillMaxWidth().heightIn(min = 220.dp).clip(RoundedCornerShape(20.dp)))
        Text("Changing fields, moving the cursor or editing cancels pending dictation. If insertion is unconfirmed, open parla to copy the result explicitly and check the field before pasting.", color = Muted, fontSize = 12.sp, lineHeight = 20.sp)
    }
}
@Composable
private fun ConfirmDialog(title: String, detail: String, dismiss: () -> Unit, confirm: () -> Unit) {
    AlertDialog(onDismissRequest = dismiss, title = { Text(title) }, text = { Text(detail) }, confirmButton = { TextButton(onClick = confirm) { Text("Clear", color = MaterialTheme.colorScheme.error) } }, dismissButton = { TextButton(onClick = dismiss) { Text("Cancel") } })
}
