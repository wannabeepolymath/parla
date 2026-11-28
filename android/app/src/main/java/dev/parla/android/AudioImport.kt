package dev.parla.android

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import java.io.File
import java.nio.ByteOrder
import java.util.UUID
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.sin
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal class ImportFailure(message: String) : Exception(message)

/** Bounded, clamped 16 kHz output. Exceeding the ceiling is the desktop duration failure, not truncation. */
internal class PcmSink(private val maximum: Int, initial: Int = 16_000 * 30) {
    private var data = FloatArray(initial.coerceIn(1,maximum))
    var size = 0; private set
    fun add(value: Float) {
        if(!value.isFinite()) throw ImportFailure(AudioFileDecoder.UNREADABLE)
        if(size == data.size) {
            if(size >= maximum) throw ImportFailure(AudioFileDecoder.TOO_LONG)
            data = data.copyOf(minOf(maximum.toLong(),size*2L).toInt())
        }
        data[size++] = value.coerceIn(-1f,1f)
    }
    fun toArray(): FloatArray = if(size == data.size) data else data.copyOf(size)
}

/**
 * Streaming polyphase windowed-sinc resampler to 16 kHz. Blackman window, 8 zero crossings per side,
 * cutoff at 95% of the lower Nyquist rate, each phase normalized to unity DC gain.
 */
internal class Resampler(sourceRate: Int, private val out: PcmSink) {
    private val up: Int; private val down: Int; private val half: Int; private val taps: Int
    private val table: FloatArray
    private var history = FloatArray(8192)
    private var historyStart = 0L // absolute input index of history[0]
    private var historyCount = 0
    private var received = 0L
    private var produced = 0L
    init {
        if(sourceRate !in 4_000..384_000) throw ImportFailure(AudioFileDecoder.UNREADABLE)
        val g = gcd(sourceRate,OUTPUT_RATE); up = OUTPUT_RATE/g; down = sourceRate/g
        if(up == down) { half = 0; taps = 0; table = FloatArray(0) } else {
            val cutoff = 0.5*minOf(1.0,OUTPUT_RATE.toDouble()/sourceRate)*0.95 // cycles per input sample
            half = ceil(ZEROS/(2*cutoff)).toInt(); taps = 2*half
            if(up.toLong()*taps > 4_000_000) throw ImportFailure(AudioFileDecoder.UNREADABLE)
            table = FloatArray(up*taps)
            for(p in 0 until up) {
                var sum = 0.0
                for(k in 0 until taps) {
                    val x = (k-half+1) - p.toDouble()/up // input index minus output position
                    val v = if(abs(x) >= half) 0.0 else 2*cutoff*sinc(2*cutoff*x)*(0.42+0.5*cos(PI*x/half)+0.08*cos(2*PI*x/half))
                    table[p*taps+k] = v.toFloat(); sum += v
                }
                for(k in 0 until taps) table[p*taps+k] = (table[p*taps+k]/sum).toFloat()
            }
        }
    }
    fun push(sample: Float) {
        if(taps == 0) { out.add(sample); return }
        if(historyCount == history.size) compact()
        history[historyCount++] = sample; received++
        drain(false)
    }
    /** Emits the tail as if followed by silence: ceil(input * 16000 / sourceRate) samples in total. */
    fun finish() { if(taps > 0) drain(true) }
    private fun drain(final: Boolean) {
        while(true) {
            val position = produced*down // in 1/up input samples
            val center = position/up
            if(final) { if(produced >= (received*up+down-1)/down) return } else if(center+half >= received) return
            val row = (position%up).toInt()*taps; val first = center-half+1
            var sum = 0f
            for(k in 0 until taps) { val index = first+k; if(index in 0 until received) sum += history[(index-historyStart).toInt()]*table[row+k] }
            out.add(sum); produced++
        }
    }
    private fun compact() {
        val keep = maxOf(historyStart,produced*down/up-half+1)
        val shift = (keep-historyStart).toInt()
        if(shift > history.size/4) { history.copyInto(history,0,shift,historyCount); historyCount -= shift; historyStart = keep }
        else history = history.copyOf(history.size*2)
    }
    companion object {
        const val OUTPUT_RATE = 16_000
        private const val ZEROS = 8.0
        private fun sinc(x: Double) = if(x == 0.0) 1.0 else sin(PI*x)/(PI*x)
        private tailrec fun gcd(a: Int, b: Int): Int = if(b == 0) a else gcd(b,a%b)
    }
}

/** Interleaved PCM frames to mono by averaging channels. */
internal fun downmix(frame: FloatArray, channels: Int): Float { var sum = 0f; for(c in 0 until channels) sum += frame[c]; return sum/channels }

/** WAV (PCM), M4A (AAC) or MP3 through Android's own decoders; no audio leaves the device. */
internal object AudioFileDecoder {
    const val MAX_FILE_BYTES = 20 * 1024 * 1024
    const val TOO_LONG = "Use a file under 10 minutes and 20 MB."
    const val UNREADABLE = "This file couldn’t be decoded. Try exporting it as M4A or WAV."
    private val tracks = setOf(MediaFormat.MIMETYPE_AUDIO_RAW,MediaFormat.MIMETYPE_AUDIO_AAC,MediaFormat.MIMETYPE_AUDIO_MPEG)

    const val TIMED_SOURCE = "Timestamps need a 16 kHz WAV file."
    /** [timed] keeps the whisper clock exact: only 16 kHz PCM WAV, never resampled. */
    fun decode(file: File, canceled: () -> Boolean, timed: Boolean = false): FloatArray {
        val extractor = MediaExtractor()
        try {
            try { extractor.setDataSource(file.absolutePath) } catch(_: Exception) { throw ImportFailure(UNREADABLE) }
            val index = (0 until extractor.trackCount).firstOrNull { extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
                ?: throw ImportFailure("This file has no audio track parla can read.")
            val format = extractor.getTrackFormat(index)
            val mime = format.getString(MediaFormat.KEY_MIME)
            if(mime !in tracks) throw ImportFailure("Use a WAV (PCM), M4A (AAC) or MP3 file.")
            if(timed && mime != MediaFormat.MIMETYPE_AUDIO_RAW) throw ImportFailure(TIMED_SOURCE)
            val duration = if(format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else -1
            if(duration > WavInput.MAX_SECONDS*1_000_000L+500_000) throw ImportFailure(TOO_LONG)
            extractor.selectTrack(index)
            val sink = PcmSink(WavInput.MAX_SAMPLES,if(duration > 0) (duration*16/1000+16_000).coerceAtMost(WavInput.MAX_SAMPLES.toLong()).toInt() else 16_000*30)
            val codec = try { MediaCodec.createDecoderByType(mime!!) } catch(_: Exception) { throw ImportFailure(UNREADABLE) }
            try {
                codec.configure(format,null,null,0); codec.start()
                val info = MediaCodec.BufferInfo()
                var inputDone = false
                var resampler: Resampler? = null; var rate = 0
                var frame = FloatArray(0)
                while(true) {
                    if(canceled()) throw CancellationException("Import canceled")
                    if(!inputDone) {
                        val i = codec.dequeueInputBuffer(10_000)
                        if(i >= 0) {
                            val n = extractor.readSampleData(codec.getInputBuffer(i)!!,0)
                            if(n < 0) { codec.queueInputBuffer(i,0,0,0,MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputDone = true }
                            else { codec.queueInputBuffer(i,0,n,extractor.sampleTime,0); extractor.advance() }
                        }
                    }
                    val o = codec.dequeueOutputBuffer(info,10_000)
                    if(o < 0) continue
                    val out = codec.getOutputFormat(o)
                    val channels = out.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    val encoding = if(out.containsKey(MediaFormat.KEY_PCM_ENCODING)) out.getInteger(MediaFormat.KEY_PCM_ENCODING) else AudioFormat.ENCODING_PCM_16BIT
                    val sourceRate = out.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    if(timed && sourceRate != Resampler.OUTPUT_RATE) throw ImportFailure(TIMED_SOURCE)
                    if(channels !in 1..8) throw ImportFailure(UNREADABLE)
                    if(encoding != AudioFormat.ENCODING_PCM_16BIT && encoding != AudioFormat.ENCODING_PCM_FLOAT) throw ImportFailure("Use a 16-bit WAV, M4A or MP3 file.")
                    // A rate change after audio was resampled would corrupt timing; refuse rather than guess.
                    val r = resampler ?: Resampler(sourceRate,sink).also { resampler = it; rate = sourceRate }
                    if(sourceRate != rate) throw ImportFailure(UNREADABLE)
                    if(frame.size != channels) frame = FloatArray(channels)
                    val buffer = codec.getOutputBuffer(o)!!.order(ByteOrder.nativeOrder())
                    buffer.position(info.offset); buffer.limit(info.offset+info.size)
                    if(encoding == AudioFormat.ENCODING_PCM_16BIT) {
                        val pcm = buffer.slice().order(ByteOrder.nativeOrder()).asShortBuffer()
                        while(pcm.remaining() >= channels) { for(c in 0 until channels) frame[c] = pcm.get()/32768f; r.push(downmix(frame,channels)) }
                    } else {
                        val pcm = buffer.slice().order(ByteOrder.nativeOrder()).asFloatBuffer()
                        while(pcm.remaining() >= channels) { for(c in 0 until channels) frame[c] = pcm.get(); r.push(downmix(frame,channels)) }
                    }
                    codec.releaseOutputBuffer(o,false)
                    if(info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
                resampler?.finish()
                if(sink.size == 0) throw ImportFailure(UNREADABLE)
                return sink.toArray()
            } catch(e: ImportFailure) { throw e } catch(e: CancellationException) { throw e }
            catch(_: Exception) { throw ImportFailure(UNREADABLE) }
            finally { runCatching { codec.stop() }; codec.release() }
        } finally { extractor.release() }
    }
}

/** Copies at most MAX_FILE_BYTES, checking cancellation per chunk. Any failure removes the partial copy. */
internal fun copyBounded(input: java.io.InputStream, file: File, canceled: () -> Boolean): Long {
    try {
        var total = 0L
        file.outputStream().use { output ->
            val buffer = ByteArray(64*1024)
            while(true) {
                if(canceled()) throw CancellationException("Import canceled")
                val n = input.read(buffer); if(n < 0) break
                total += n; if(total > AudioFileDecoder.MAX_FILE_BYTES) throw ImportFailure(AudioFileDecoder.TOO_LONG)
                output.write(buffer,0,n)
            }
        }
        if(total == 0L) throw ImportFailure(AudioFileDecoder.UNREADABLE)
        return total
    } catch(t: Throwable) { file.delete(); throw t }
}

/** Publishes the copy, or deletes it, including when cancellation discards a finished result at the dispatcher handoff. */
internal suspend fun stagePrivateCopy(file: File, copy: suspend () -> ImportSource, publish: (ImportSource) -> Unit) {
    var published = false
    try { publish(copy()); published = true } finally { if(!published) file.delete() }
}

internal data class ImportSource(val name: String, val bytes: Long, val file: File)
/** [recognition] keeps the raw result for JSON export; its cues exist only for an explicit timed transcription. */
internal data class ImportState(val source: ImportSource? = null, val busy: Boolean = false, val message: String = "", val preview: String? = null, val model: String = "", val saved: Boolean = false,
                                val recognition: TimedTranscript? = null, val language: String = "")
/** One saved transcript in review. [token] is set only for a just-finished attempt whose result may still need writing. */
internal data class SavedReview(val jobID: String, val resultID: String, val token: SavedImportStore.Token?, val text: String, val date: Long, val model: String, val language: String,
                                val accepted: SavedImportStore.Result?, val historySaved: Boolean = false)
internal data class SavedState(val busy: Boolean = false, val message: String = "", val review: SavedReview? = null)

/** One screen-owned import: private copy, local decode and recognition, explicit save. Never uploads or inserts. */
internal class AudioImport(private val context: Context, private val store: Store) {
    private val scope = CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
    private val value = MutableStateFlow(ImportState())
    val state = value.asStateFlow()
    private var job: Job? = null
    private val directory = File(context.cacheDir,"imports")
    init { scope.launch(Dispatchers.IO) { directory.listFiles()?.filter { it.name.startsWith("import-") }?.forEach { it.delete() } } }

    fun choose(uri: Uri) {
        if(job?.isActive == true) return
        discard()
        value.value = ImportState(busy = true,message = "Reading file…")
        val file = File(directory,"import-${UUID.randomUUID()}")
        job = scope.launch {
            try {
                stagePrivateCopy(file,{ withContext(Dispatchers.IO) { val work = coroutineContext; copy(uri,file) { !work.isActive } } }) { value.value = ImportState(source = it) }
            } catch(c: CancellationException) { throw c } catch(e: ImportFailure) { value.value = ImportState(message = e.message.orEmpty()) }
            catch(_: Exception) { value.value = ImportState(message = "Couldn’t open the file. Choose it again.") }
        }
    }

    private fun copy(uri: Uri, file: File, canceled: () -> Boolean): ImportSource {
        val resolver = context.contentResolver
        val name = resolver.query(uri,arrayOf(OpenableColumns.DISPLAY_NAME),null,null,null)?.use { if(it.moveToFirst()) it.getString(0) else null } ?: "Audio file"
        val type = resolver.getType(uri).orEmpty()
        if(type !in MIME_TYPES && name.substringAfterLast('.',"").lowercase() !in setOf("wav","m4a","mp3")) throw ImportFailure("Choose a WAV, M4A or MP3 file.")
        directory.mkdirs()
        val input = resolver.openInputStream(uri) ?: throw ImportFailure("Couldn’t open the file. Choose it again.")
        return ImportSource(name,input.use { copyBounded(it,file,canceled) },file)
    }

    private fun frozenModel(report: (String) -> Unit): Pair<LocalData, SpeechModel>? {
        val frozen = store.data.value.takeIf { store.ready } ?: run { report("Repair settings in Data recovery first. Nothing was sent."); return null }
        val manager = ModelManager.get(context)
        val model = manager.selected(frozen.settings)?.takeIf { manager.file(it).isFile } ?: run { report("Select a downloaded speech model in Models."); return null }
        return frozen to model
    }
    private suspend fun decode(file: File, timed: Boolean) = withContext(Dispatchers.Default) { val work = coroutineContext; AudioFileDecoder.decode(file,{ !work.isActive },timed) }

    fun transcribe(timed: Boolean = false) {
        val source = value.value.source ?: return
        if(job?.isActive == true) return
        val (frozen, model) = frozenModel { m -> value.update { it.copy(message = m) } } ?: return
        if(timed && SpeechLanguagePolicy.language(model,frozen.settings.language) == "auto") { value.update { it.copy(message = "Timestamps need a chosen language. Choose one in Languages.") }; return }
        val file = ModelManager.get(context).file(model)
        value.value = ImportState(source,busy = true,message = "Decoding on device…")
        job = scope.launch {
            value.value = try {
                val timing = TimingSession().apply { mark(TimingStage.import_start) }
                val samples = timing.span(null,TimingStage.file_decode) { decode(source.file,timed) }
                value.update { it.copy(message = "Transcribing on device…") }
                val recognition = timing.span(TimingStage.transcription_start,TimingStage.transcription_end) {
                    if(timed) LocalSpeech().transcribeTimed(samples,file,model,frozen.dictionary,frozen.settings.language,timing)
                    else TimedTranscript(LocalSpeech().transcribe(samples,file,model,frozen.dictionary,frozen.settings.language,timing = timing),samples.size,null)
                }
                ImportState(source,preview = recognition.text,model = model.id,recognition = recognition,language = frozen.settings.language,
                    message = if(timed && recognition.cues == null) "Transcript ready, but timestamps weren’t available for it. Nothing was uploaded or inserted." else "Transcript ready. Nothing was uploaded or inserted.")
            } catch(c: CancellationException) { throw c } // cancel()/discard() publish their own state
            catch(e: ImportFailure) { ImportState(source,message = e.message.orEmpty()) }
            catch(e: Exception) { ImportState(source,message = e.message?.take(200) ?: "Could not transcribe this file.") }
        }
    }

    fun cancel() { job?.cancel(); value.update { it.copy(busy = false,message = "Canceled. Nothing was saved.") } }

    fun save() {
        val s = value.value; val text = s.preview ?: return
        if(s.saved) return
        if(!store.ready || store.data.value.settings.noHistory) { value.update { it.copy(message = "Turn on text history in Privacy to save. You can still copy this text.") }; return }
        val entry = HistoryEntry(raw = text,text = text,note = "Transcribed from an audio file. Nothing inserted into an app.",model = s.model)
        if(store.update { it.copy(history = listOf(entry)+it.history) }) value.update { it.copy(saved = true,message = "Transcript saved to history.") }
        else value.update { it.copy(message = "Text was not saved. Copy it or try Save again.") }
    }

    fun discard() {
        job?.cancel(); job = null
        value.value.source?.file?.delete()
        value.value = ImportState()
    }

    fun close() { discard(); scope.cancel() }

    // Saved files: an explicit, durable copy and transcript ledger (desktop SavedAudioImportView).
    val saved = SavedImportStore.get(context)
    private val savedValue = MutableStateFlow(SavedState())
    val savedState = savedValue.asStateFlow()
    private var savedJob: Job? = null
    private fun savedMessage(text: String) = savedValue.update { it.copy(message = text) }
    private fun failed(e: Throwable) = (e as? SavedImportStore.Failure ?: e as? ImportFailure)?.message ?: e.message?.take(200) ?: "Something went wrong. Try again."
    init { scope.launch(Dispatchers.IO) { runCatching { saved.maintenance() } } }

    fun keepAndTranscribe() {
        val source = value.value.source ?: return
        if(savedJob?.isActive == true || job?.isActive == true) return
        val (frozen, model) = frozenModel(::savedMessage) ?: return
        start(frozen, model) { saved.admit(source.file, source.name) }
    }
    fun retrySaved(id: String) {
        if(savedJob?.isActive == true) return
        val (frozen, model) = frozenModel(::savedMessage) ?: return
        start(frozen, model) { saved.begin(id) }
    }
    /** One attempt: admit/begin, verified source, local recognition, then a storage-only result write. */
    private fun start(frozen: LocalData, model: SpeechModel, admit: () -> SavedImportStore.Token) {
        savedValue.value = SavedState(busy = true, message = "Saving a private copy…")
        savedJob = scope.launch {
            var token: SavedImportStore.Token? = null
            try {
                val t = withContext(Dispatchers.IO) { admit().also { token = it; saved.running(it) } }
                savedMessage("Transcribing on device…")
                val file = withContext(Dispatchers.IO) { saved.source(t) }
                val timing = TimingSession().apply { mark(TimingStage.import_start) }
                val samples = timing.span(null, TimingStage.file_decode) { decode(file, false) }
                val text = timing.span(TimingStage.transcription_start, TimingStage.transcription_end) {
                    LocalSpeech().transcribe(samples, ModelManager.get(context).file(model), model, frozen.dictionary, frozen.settings.language, timing = timing)
                }
                val review = SavedReview(t.job, UUID.randomUUID().toString(), t, text, System.currentTimeMillis(), model.id, frozen.settings.language, null)
                savedValue.value = SavedState(review = review, message = "Transcript ready.")
                writeResult(review)
            } catch(c: CancellationException) {
                token?.let { saved.finish(it, true) }; savedValue.value = SavedState(message = "Canceled. The saved copy is kept."); throw c
            } catch(e: Exception) {
                token?.let { saved.finish(it, false) }; savedValue.value = SavedState(message = failed(e))
            }
        }
    }
    private suspend fun writeResult(review: SavedReview) {
        val token = review.token ?: return
        try {
            val accepted = withContext(Dispatchers.IO) { saved.saveResult(token, review.resultID, review.text, review.model, review.language, review.date) }
            savedValue.update { if(it.review?.resultID == review.resultID) it.copy(review = review.copy(accepted = accepted), message = "Transcript saved with the file. Nothing was uploaded or inserted.") else it }
        } catch(e: Exception) { savedMessage("The transcript wasn’t kept. Try saving again; it won’t be transcribed again.") }
    }
    /** Storage only: rewrites the same result ID and bytes, never recognition. */
    fun retrySaveResult() {
        val review = savedValue.value.review?.takeIf { it.accepted == null } ?: return
        if(savedJob?.isActive == true) return
        savedJob = scope.launch { writeResult(review) }
    }
    fun cancelSaved() { savedJob?.cancel() }
    fun openSaved(id: String) {
        if(savedJob?.isActive == true) return
        savedJob = scope.launch {
            savedValue.value = try {
                val (result, text) = withContext(Dispatchers.IO) { saved.openResult(id) }
                SavedState(review = SavedReview(id, result.id, null, text, result.date, result.model, result.language, result, result.association == SavedImportStore.Association.saved), message = "Saved transcript.")
            } catch(e: Exception) { SavedState(message = failed(e)) }
        }
    }
    fun deleteSaved(id: String) {
        if(savedValue.value.review?.jobID == id) savedValue.update { it.copy(review = null) }
        scope.launch {
            val result = runCatching { withContext(Dispatchers.IO) { saved.delete(id) } }
            savedMessage(result.exceptionOrNull()?.let { "Couldn’t delete the saved file. " + failed(it) } ?: "Saved file deleted.")
        }
    }
    /**
     * Desktop saveHistory: persist savingIntent before the history write; the row's ID is the result ID, so an
     * interrupted save is resolved by looking for that exact row ("Check history"), never by adding a duplicate.
     */
    fun saveSavedToHistory() {
        val review = savedValue.value.review ?: return
        val accepted = review.accepted ?: return
        if(savedJob?.isActive == true) return
        if(!store.ready || store.data.value.settings.noHistory) { savedMessage("Turn on text history in Privacy to save. You can still copy this text."); return }
        val entry = HistoryEntry(id = accepted.id, createdAt = accepted.date, raw = review.text, text = review.text, note = "Transcribed from a saved audio file. Nothing inserted into an app.", model = accepted.model)
        fun present() = store.data.value.history.any { it.id == entry.id && it.raw == entry.raw && it.createdAt == entry.createdAt }
        savedJob = scope.launch {
            try {
                val unknown = accepted.association == SavedImportStore.Association.savingIntent || accepted.association == SavedImportStore.Association.unknown
                if(review.historySaved || unknown) {
                    if(!present()) { savedMessage("Couldn’t tell whether this was saved to history. You can still copy or export it."); return@launch }
                } else {
                    withContext(Dispatchers.IO) { saved.association(review.jobID, accepted.id, SavedImportStore.Association.savingIntent) }
                    val written = store.update { local -> if(local.settings.noHistory || local.history.any { it.id == entry.id }) local else local.copy(history = (local.history + entry).sortedByDescending { it.createdAt }) }
                    if(!written || !present()) {
                        val reset = runCatching { withContext(Dispatchers.IO) { saved.association(review.jobID, accepted.id, SavedImportStore.Association.notSaved) } }
                        savedValue.update { it.copy(review = review.copy(accepted = reset.getOrNull() ?: accepted.copy(association = SavedImportStore.Association.unknown)), message = "Couldn’t save to history. Try again.") }
                        return@launch
                    }
                }
                savedValue.update { it.copy(review = review.copy(historySaved = true, accepted = accepted.copy(association = SavedImportStore.Association.savingIntent))) }
                val recorded = withContext(Dispatchers.IO) { saved.association(review.jobID, accepted.id, SavedImportStore.Association.saved) }
                savedValue.update { it.copy(review = review.copy(historySaved = true, accepted = recorded), message = "Saved to history.") }
            } catch(e: Exception) { savedMessage("Saved files couldn’t record this. " + failed(e)) }
        }
    }

    companion object {
        val MIME_TYPES = arrayOf("audio/wav","audio/x-wav","audio/wave","audio/vnd.wave","audio/mp4","audio/x-m4a","audio/m4a","audio/aac","audio/mp4a-latm","audio/mpeg","audio/mp3")
    }
}

@Composable internal fun AudioImportScreen(store: Store, onCopy: (String) -> Unit) {
    val context = LocalContext.current
    val owner = remember { AudioImport(context,store) }
    val state by owner.state.collectAsState()
    val data by store.data.collectAsState()
    val status by ParlaService.status.collectAsState()
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> if(uri != null) owner.choose(uri) }
    DisposableEffect(owner) { onDispose { owner.close() } }
    val savedState by owner.savedState.collectAsState()
    val rows by owner.saved.rows.collectAsState()
    val savedFailure by owner.saved.failure.collectAsState()
    var exportMessage by remember { mutableStateOf("") }
    var pending by remember { mutableStateOf("") }
    val written: (Uri?) -> Unit = { uri ->
        if(uri != null) exportMessage = runCatching {
            check(pending.isNotEmpty())
            (context.contentResolver.openOutputStream(uri) ?: error("No destination")).bufferedWriter().use { it.write(pending) }
        }.fold({ "Exported." }, { "Couldn’t export. Choose another location and try again." })
        pending = ""
    }
    val launchers = mapOf("vtt" to SubtitleExport.Format.webVTT.mime, "srt" to SubtitleExport.Format.srt.mime, "json" to "application/json", "txt" to "text/plain")
        .mapValues { (_, mime) -> rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(mime), written) }
    fun export(extension: String, name: String, payload: () -> String) {
        exportMessage = try { pending = payload(); launchers.getValue(extension).launch(name); "" }
        catch(e: SubtitleExport.Refused) { pending = ""; if(extension == "json") "This transcript can’t be exported as JSON. Copy or save it instead." else SubtitleExport.message(e.refusal, if(extension == "srt") SubtitleExport.Format.srt else SubtitleExport.Format.webVTT) }
    }
    val busy = state.busy || savedState.busy
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("Transcribe an audio file",style = MaterialTheme.typography.headlineMedium)
        Text("WAV, M4A or MP3, up to ${WavInput.MAX_SECONDS/60} minutes and 20 MB. Transcribed on this device with your speech model, language and dictionary. Nothing is uploaded, sent for AI cleanup or inserted into an app.")
        Text("Language: ${if(data.settings.language == "auto") "auto-detect" else data.settings.language} · Model: ${speechModelLabel(data.settings.localModel)}",style = MaterialTheme.typography.bodySmall)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = { pick.launch(arrayOf("audio/*")) },enabled = !busy) { Text("Choose file…") }
            Button(onClick = { owner.transcribe() },enabled = state.source != null && !busy && status.phase != Phase.RECORDING) { Text("Transcribe") }
            TextButton(onClick = owner::discard,enabled = state.source != null || state.preview != null) { Text("Discard") }
        }
        OutlinedButton(onClick = { owner.transcribe(timed = true) },enabled = state.source != null && !busy && status.phase != Phase.RECORDING) { Text("Transcribe with timestamps") }
        Text("Timestamps need a 16 kHz WAV and a chosen language.",style = MaterialTheme.typography.bodySmall)
        state.source?.let { Text("${it.name} · ${fileSizeLabel(it.bytes)}") }
        if(state.busy) {
            LinearProgressIndicator(Modifier.fillMaxWidth())
            OutlinedButton(onClick = owner::cancel) { Text("Cancel") }
        }
        if(state.message.isNotEmpty()) Text(state.message)
        state.preview?.let { text ->
            HorizontalDivider(); Text("Transcript",style = MaterialTheme.typography.titleMedium)
            SelectionContainer { Text(text) }
            val cues = state.recognition?.cues
            if(cues != null) {
                Text("Timestamps",style = MaterialTheme.typography.titleMedium)
                Text("Timestamps are approximate and are lost when you leave this screen.",style = MaterialTheme.typography.bodySmall)
                cues.take(200).forEach { cue ->
                    Text("${runCatching { SubtitleExport.timestamp(cue.start) }.getOrDefault("–")} → ${runCatching { SubtitleExport.timestamp(cue.end) }.getOrDefault("–")}",style = MaterialTheme.typography.labelSmall)
                    Text(cue.text)
                }
                if(cues.size > 200) Text("${cues.size - 200} more in the exported file.",style = MaterialTheme.typography.bodySmall)
            }
            FlowRow {
                TextButton(onClick = { onCopy(text) }) { Text("Copy") }
                if(cues != null) {
                    TextButton(onClick = { export("vtt","Parla-transcript.vtt") { SubtitleExport.encode(cues,SubtitleExport.Format.webVTT) } }) { Text("Export WebVTT") }
                    TextButton(onClick = { export("srt","Parla-transcript.srt") { SubtitleExport.encode(cues,SubtitleExport.Format.srt) } }) { Text("Export SRT") }
                }
                state.recognition?.let { r -> ModelCatalog.all.firstOrNull { it.id == state.model }?.let { model ->
                    TextButton(onClick = { export("json",RecognitionExport.filename(System.currentTimeMillis())) { RecognitionExport.encode(r,model,state.language.takeIf { it != "auto" }) } }) { Text("Export JSON") }
                } }
                if(data.settings.noHistory) Text("History is off.",Modifier.padding(12.dp))
                else TextButton(onClick = owner::save,enabled = !state.saved) { Text(if(state.saved) "Saved" else "Save to history") }
            }
            Text("JSON includes the raw transcript, model, and timestamps when available.",style = MaterialTheme.typography.bodySmall)
        }
        if(exportMessage.isNotEmpty()) Text(exportMessage)
        Text("Leaving this screen discards the transcript and the private copy of the file.",style = MaterialTheme.typography.bodySmall)
        HorizontalDivider()
        Text("Saved files",style = MaterialTheme.typography.titleMedium)
        Text("parla can keep a private copy of the file and its transcript on this phone for 7 days, even with history off. Up to ${SavedImportStore.MAX_JOBS} files. Never uploaded or backed up.")
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = owner::keepAndTranscribe,enabled = state.source != null && !busy && savedFailure == null && status.phase != Phase.RECORDING) { Text("Save a copy and transcribe") }
            if(savedState.busy) OutlinedButton(onClick = owner::cancelSaved) { Text("Cancel") }
        }
        if(savedState.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        savedFailure?.let { Text(it,color = MaterialTheme.colorScheme.error) }
        if(savedState.message.isNotEmpty()) Text(savedState.message)
        val dates = remember { java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.MEDIUM,java.text.DateFormat.SHORT) }
        val days = remember { java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM) }
        rows.forEach { row ->
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(row.label,style = MaterialTheme.typography.titleSmall)
                Text("${fileSizeLabel(row.sourceBytes)} · Saved ${dates.format(java.util.Date(row.created))} · Deletes ${days.format(java.util.Date(row.expires))}",style = MaterialTheme.typography.bodySmall)
                Text(savedStatus(row.state),style = MaterialTheme.typography.bodySmall)
                if(!row.sourceAvailable && row.state != SavedImportStore.State.deleting) Text("The audio file is missing.",style = MaterialTheme.typography.bodySmall)
                FlowRow {
                    if(row.result != null) TextButton(onClick = { owner.openSaved(row.id) },enabled = !busy) { Text("Open transcript") }
                    TextButton(onClick = { owner.retrySaved(row.id) },enabled = row.sourceAvailable && !busy && status.phase != Phase.RECORDING) { Text("Transcribe again") }
                    TextButton(onClick = { owner.deleteSaved(row.id) }) { Text(if(row.state == SavedImportStore.State.deleting) "Try deleting again" else "Delete",color = MaterialTheme.colorScheme.error) }
                }
            }
        }
        savedState.review?.let { review ->
            Text("Saved transcript",style = MaterialTheme.typography.titleMedium)
            SelectionContainer { Text(review.text) }
            FlowRow {
                TextButton(onClick = { onCopy(review.text) }) { Text("Copy") }
                TextButton(onClick = { export("txt","Parla-transcript.txt") { review.text } }) { Text("Export text") }
                when {
                    review.accepted == null -> TextButton(onClick = owner::retrySaveResult,enabled = !savedState.busy) { Text("Try saving again") }
                    review.historySaved && review.accepted.association == SavedImportStore.Association.saved -> Text("Saved to history",Modifier.padding(12.dp))
                    data.settings.noHistory -> Text("History is off.",Modifier.padding(12.dp))
                    else -> TextButton(onClick = owner::saveSavedToHistory,enabled = !savedState.busy) { Text(
                        if(review.historySaved) "Try saving again" else if(review.accepted.association == SavedImportStore.Association.notSaved) "Save to history" else "Check history") }
                }
            }
        }
    }
}

private fun savedStatus(state: SavedImportStore.State) = when(state) {
    SavedImportStore.State.staging -> "Saving…"
    SavedImportStore.State.committed -> "Saved"
    SavedImportStore.State.queued -> "Waiting…"
    SavedImportStore.State.running -> "Transcribing…"
    SavedImportStore.State.failed -> "Transcription failed"
    SavedImportStore.State.canceled -> "Canceled"
    SavedImportStore.State.interrupted -> "Interrupted"
    SavedImportStore.State.deleting -> "Deleting…"
}
