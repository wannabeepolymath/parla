package dev.parla.android

import android.content.Context
import java.io.File
import java.nio.ByteBuffer
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject

internal class TransferPermit {
    private var canceled = false
    private var abort: (() -> Unit)? = null
    @Synchronized fun check() { if(canceled) throw CancellationException("Transfer paused") }
    @Synchronized fun commit(work: () -> Unit) { check(); work() }
    @Synchronized fun revoke() { canceled = true; abort?.invoke() }
    @Synchronized fun attach(action: (() -> Unit)?) { abort = action; if(canceled) action?.invoke() }
}
internal data class TransferRequest(val model: SpeechModel, val start: Long, val end: Long, val validator: String?, val full: Boolean)
internal data class TransferResponse(val status: Int, val headers: Map<String,String>) {
    fun header(name: String) = headers.entries.firstOrNull { it.key.equals(name,true) }?.value
}
/** Synchronous contract: fetch returns/throws only after its file writer has closed. */
internal fun interface ModelTransport {
    fun fetch(request: TransferRequest, chunk: File, permit: TransferPermit): TransferResponse
}
internal class CatalogHttpTransport : ModelTransport {
    private val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
        .readTimeout(30,TimeUnit.SECONDS).callTimeout(1,TimeUnit.HOURS).build()
    override fun fetch(request: TransferRequest, chunk: File, permit: TransferPermit): TransferResponse {
        var url = request.model.url
        repeat(6) { redirect ->
            permit.check(); require(allowed(url)) { "Model redirect refused." }
            val builder = Request.Builder().url(url).header("Accept-Encoding","identity")
            if(!request.full) builder.header("Range","bytes=${request.start}-${request.end}")
            if(request.start > 0) request.validator?.let { builder.header("If-Range",it) }
            // Fresh client/request; provider Authorization, cookies and credentials never enter here.
            val call = http.newCall(builder.build()); permit.attach(call::cancel)
            try {
                call.execute().use { response ->
                    if(response.code in setOf(301,302,303,307,308)) {
                        require(redirect < 5) { "Too many model redirects." }
                        url = response.header("Location")?.let { response.request.url.resolve(it)?.toString() } ?: error("Missing model redirect.")
                    } else {
                        require(response.code in setOf(200,206,416)) { "Model server returned HTTP ${response.code}." }
                        val body = response.body ?: error("Empty model response.")
                        val limit = when(response.code) { 206 -> request.end-request.start+1; 416 -> 0; else -> request.model.bytes }
                        require(body.contentLength() in -1..limit) { "Model response exceeds pinned size." }
                        val files = PrivateFiles(chunk.parentFile!!)
                        files.channel(chunk,0,true).use { out ->
                            body.byteStream().use { input ->
                                val buffer = ByteArray(64*1024); var count = 0L
                                while(true) {
                                    permit.check(); val n = input.read(buffer); if(n < 0) break
                                    count += n; require(count <= limit) { "Model response exceeds pinned size." }
                                    val b = ByteBuffer.wrap(buffer,0,n); while(b.hasRemaining()) out.write(b)
                                }
                            }; out.force(true)
                        }
                        return TransferResponse(response.code,response.headers.names().associateWith { response.header(it).orEmpty() })
                    }
                }
            } finally { permit.attach(null) }
        }
        error("Model redirect refused.")
    }
    companion object {
        fun allowed(url: String): Boolean = runCatching {
            val u = java.net.URI(url); val h = u.host?.lowercase().orEmpty()
            u.scheme == "https" && u.rawUserInfo == null && u.port in setOf(-1,443) && (h == "huggingface.co" || h.endsWith(".huggingface.co") || h.endsWith(".hf.co"))
        }.getOrDefault(false)
    }
}
internal data class TransferValidator(val kind: String, val value: String) {
    fun valid() = when(kind) {
        "etag" -> value.length in 2..256 && value.first() == '"' && value.last() == '"' && value.drop(1).dropLast(1).all { it == '!' || it in '#'..'~' }
        "modified" -> date(value) != null
        else -> false
    }
    companion object {
        private fun date(s: String?): java.time.Instant? = runCatching {
            require(s?.length == 29)
            val d = ZonedDateTime.parse(s,DateTimeFormatter.RFC_1123_DATE_TIME)
            require(DateTimeFormatter.ofPattern("EEE, dd MMM yyyy HH:mm:ss 'GMT'",java.util.Locale.US).format(d) == s)
            d.toInstant()
        }.getOrNull()
        fun response(r: TransferResponse): TransferValidator? {
            r.header("ETag")?.let { return TransferValidator("etag",it).takeIf(TransferValidator::valid) }
            val modified = r.header("Last-Modified") ?: return null
            val m = date(modified) ?: return null; val now = date(r.header("Date")) ?: return null
            return TransferValidator("modified",modified).takeIf { now.epochSecond-m.epochSecond >= 60 }
        }
    }
}
internal data class TransferCheckpoint(val id: String, val url: String, val size: Long, val hash: String, val stage: String, val offset: Long, val validator: TransferValidator?, val generation: String) {
    fun matches(m: SpeechModel) = id == m.id && url == m.url && size == m.bytes && hash == m.sha256
    fun encode() = JSONObject().put("version",1).put("id",id).put("url",url).put("size",size).put("hash",hash).put("stage",stage).put("offset",offset).put("generation",generation)
        .put("validator",validator?.let { JSONObject().put("kind",it.kind).put("value",it.value) }).toString().toByteArray()
}
internal class TransferStorage(directory: File, private val catalog: List<SpeechModel>) {
    val files by lazy { PrivateFiles(directory) }
    var fault: (String) -> Unit = {}
    fun journal(m: SpeechModel) = files.file("${m.id}.transfer.json")
    fun read(m: SpeechModel): TransferCheckpoint? {
        require(m in catalog)
        if(!files.exists(journal(m))) return null
        val j = JSONObject(files.read(journal(m),4096).toString(Charsets.UTF_8))
        require(j.get("version") is Int && j.getInt("version") == 1)
        require(listOf("size","offset").all { j.get(it) is Int || j.get(it) is Long })
        val v = j.optJSONObject("validator")?.let { TransferValidator(it.getString("kind"),it.getString("value")).also { v -> require(v.valid()) } }
        val c = TransferCheckpoint(j.getString("id"),j.getString("url"),j.getLong("size"),j.getString("hash"),j.getString("stage"),j.getLong("offset"),v,j.getString("generation"))
        require(c.matches(m) && c.offset in 0..m.bytes && Regex("part-[0-9a-f-]{36}").matches(c.stage)) { "Checkpoint identity is invalid; installed model preserved." }
        UUID.fromString(c.stage.removePrefix("part-")); UUID.fromString(c.generation)
        if(files.exists(files.file(c.stage))) require(files.attributes(files.file(c.stage),m.bytes).size() >= c.offset) { "Checkpoint is incomplete; installed model preserved." }
        else require(c.offset == m.bytes) { "Partial model missing; installed model preserved." }
        return c
    }
    fun save(c: TransferCheckpoint, m: SpeechModel, permit: TransferPermit, previousGeneration: String? = c.generation) {
        fault("manifest")
        files.atomic(journal(m),c.encode()) { publish ->
            permit.commit {
                require(read(m)?.generation == previousGeneration) { "Transfer generation changed before publication." }
                publish()
            }
        }
    }
    private fun cleanupScratch(permit: TransferPermit) {
        // Only after the previous writer drains, on an explicit action. Preserve unknown/invalid provenance.
        val referenced = catalog.mapNotNull { read(it)?.stage }.toSet()
        val scratch = Regex("(?:chunk-[0-9a-f-]{36}\\.tmp|journal-[0-9a-f-]{36}\\.tmp|part-[0-9a-f-]{36})")
        val maximum = catalog.maxOf { it.bytes }
        for(name in files.names()) if(scratch.matches(name) && name !in referenced) {
            val file = files.file(name); files.attributes(file,if(name.startsWith("journal-")) 4096 else maximum)
            permit.commit { files.remove(file) }
        }
    }
    fun prepare(m: SpeechModel, generation: String, permit: TransferPermit): TransferCheckpoint {
        cleanupScratch(permit)
        val old = read(m)
        if(old != null) {
            val c = old.copy(generation = generation)
            if(files.exists(files.file(c.stage))) files.channel(files.file(c.stage),m.bytes,true).use { it.truncate(c.offset); it.force(true) }
            save(c,m,permit,old.generation); return c
        }
        files.names(16) // bounded directory admission
        val stage = files.create("part-${UUID.randomUUID()}")
        val c = TransferCheckpoint(m.id,m.url,m.bytes,m.sha256,stage.name,0,null,generation)
        try { save(c,m,permit,null) } catch(t: Throwable) { files.remove(stage); throw t }
        return c
    }
    fun reset(c: TransferCheckpoint, m: SpeechModel, p: TransferPermit): TransferCheckpoint {
        // Publish zero first. A crash can leave only an uncommitted tail, never a false durable prefix.
        val empty = c.copy(offset = 0,validator = null); save(empty,m,p)
        p.commit { files.channel(files.file(c.stage),m.bytes,true).use { it.truncate(0); it.force(true) } }; return empty
    }
    fun append(c: TransferCheckpoint, m: SpeechModel, chunk: File, count: Long, validator: TransferValidator?, p: TransferPermit): TransferCheckpoint {
        p.check(); require(read(m)?.generation == c.generation) { "Transfer generation changed." }
        files.channel(files.file(c.stage),m.bytes,true).use { out ->
            out.truncate(c.offset); out.position(c.offset)
            files.channel(chunk,m.bytes).use { input ->
                val b = ByteBuffer.allocate(64*1024); var copied = 0L
                while(true) { p.check(); b.clear(); val n = input.read(b); if(n < 0) break; copied += n; require(copied <= count); b.flip(); while(b.hasRemaining()) out.write(b) }
                require(copied == count)
            }; fault("synchronize"); out.force(true)
        }
        val next = c.copy(offset = c.offset+count,validator = validator); save(next,m,p); return next
    }
    fun finish(m: SpeechModel) { files.remove(journal(m)) }
    fun discard(m: SpeechModel) {
        val c = read(m) ?: return
        files.remove(files.file(c.stage)); finish(m)
    }
}
data class ModelTransfer(val id: String = "", val bytes: Long = 0, val active: Boolean = false, val message: String = "", val paused: Boolean = false, val pausable: Boolean = true)
class ModelManager internal constructor(
    val directory: File,
    private val transport: ModelTransport = CatalogHttpTransport(),
    dispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val catalog: List<SpeechModel> = ModelCatalog.all,
    private val chunkBytes: Long = 8L*1024*1024,
    private val install: suspend (File,File,SpeechModel,TransferPermit) -> Unit = { part,dest,m,p ->
        withContext(NonCancellable) { NativeTasks.run { ModelCatalog.verify(part,m); p.commit { PrivateFiles(dest.parentFile!!).publish(part,dest) } } }
    },
) {
    internal val storage = TransferStorage(directory,catalog)
    private val scope = CoroutineScope(SupervisorJob()+dispatcher)
    private val state = MutableStateFlow(ModelTransfer())
    val transfer = state.asStateFlow()
    private val rowState = MutableStateFlow<Map<String,ModelTransfer>>(emptyMap())
    val rows = rowState.asStateFlow()
    private var task: Job? = null
    private var permit: TransferPermit? = null
    private var generation: String? = null
    private var discardOnExit = false
    private var deleting = false
    init {
        require(chunkBytes > 0 && catalog.size in 1..3 && catalog.map { it.id }.distinct().size == catalog.size)
        require(catalog.all { Regex("[a-zA-Z0-9._-]{1,64}").matches(it.id) && it.bytes > 0 && Regex("[0-9a-f]{64}").matches(it.sha256) })
        for(m in catalog) try { storage.read(m)?.let { publish(ModelTransfer(m.id,it.offset,message = "Paused after interruption. Resume explicitly.",paused = true)) } }
        catch(_: Exception) { publish(ModelTransfer(m.id,message = "Checkpoint unavailable. Installed model preserved; repair private transfer storage before retrying.")) }
    }
    @Synchronized private fun publish(row: ModelTransfer) { state.value = row; rowState.value = rowState.value + (row.id to row) }
    fun file(model: SpeechModel): File { require(model in catalog); return File(directory,model.filename) }
    fun selected(settings: Settings) = catalog.firstOrNull { it.id == settings.localModel }
    @Synchronized fun download(model: SpeechModel) {
        if(deleting || generation != null || task?.isCompleted == false || model !in catalog) return
        val p = TransferPermit(); val g = UUID.randomUUID().toString()
        generation = g; permit = p; discardOnExit = false
        publish(ModelTransfer(model.id,rows.value[model.id]?.bytes ?: 0,true,"Connecting…"))
        var failure: String? = null; var installed = false
        val work = scope.launch(start = CoroutineStart.LAZY) {
            try { transfer(model,g,p); installed = true }
            catch(_: CancellationException) { failure = "Paused. Installed model preserved." }
            catch(_: Exception) { failure = "Transfer failed validation or storage/network access. Installed model preserved. Resume retries from the last checkpoint; Discard removes only partial bytes." }
        }
        task = work
        work.invokeOnCompletion {
            synchronized(this@ModelManager) {
                // Sole settlement point, including cancellation before coroutine entry. Ownership remains
                // reserved through actual completion, so a concurrent Discard cannot fall between two finalizers.
                if(generation == g) settle(model,p,installed,failure ?: "Paused before transfer started. Resume explicitly.")
            }
        }
        work.start()
    }
    private fun settle(m: SpeechModel, p: TransferPermit, installed: Boolean, failure: String?) {
        if(permit !== p) return
        var message = if(installed) "SHA-256 verified and installed. Select explicitly." else failure.orEmpty()
        if(discardOnExit) try { storage.discard(m); message = "Partial transfer discarded. Installed model preserved." } catch(_: Exception) { message = "Could not discard private checkpoint. Installed model preserved." }
        val c = runCatching { storage.read(m) }.getOrNull()
        publish(ModelTransfer(m.id,if(installed) m.bytes else c?.offset ?: 0,false,message,c != null))
        generation = null; permit = null; discardOnExit = false
    }
    @Synchronized fun pause() {
        if(generation == null) return
        permit?.revoke(); task?.cancel()
        if(state.value.active) publish(state.value.copy(message = "Pausing · waiting for writer/native exit…"))
    }
    fun cancel() = pause()
    @Synchronized fun discard(model: SpeechModel) {
        if(deleting) return
        if(generation != null || task?.isCompleted == false) { if(state.value.id == model.id) { discardOnExit = true; pause() }; return }
        try { storage.discard(model); publish(ModelTransfer(model.id,message = "Partial transfer discarded. Installed model preserved.")) }
        catch(_: Exception) { publish(ModelTransfer(model.id,message = "Could not discard checkpoint. Unsafe files were preserved.")) }
    }
    private suspend fun transfer(m: SpeechModel, g: String, p: TransferPermit) {
        p.check()
        var c = storage.prepare(m,g,p)
        if(!storage.files.exists(storage.files.file(c.stage))) {
            withContext(NonCancellable) { NativeTasks.run { ModelCatalog.verify(file(m),m); p.check(); storage.finish(m) } }; return
        }
        require(directory.usableSpace > (m.bytes-c.offset)+minOf(m.bytes,chunkBytes)+32L*1024*1024) { "Insufficient model storage." }
        var restarted = false; var full = false
        while(c.offset < m.bytes) {
            p.check()
            if(c.offset > 0 && c.validator == null) { require(!restarted); c = storage.reset(c,m,p); restarted = true; full = true }
            val start = c.offset; val end = start+minOf(chunkBytes,m.bytes-start)-1
            val chunk = storage.files.create("chunk-${UUID.randomUUID()}.tmp")
            try {
                val r = transport.fetch(TransferRequest(m,start,end,if(start > 0) c.validator?.value else null,full),chunk,p)
                p.check()
                require(r.header("Content-Encoding")?.lowercase() in setOf(null,"identity") && r.header("Content-Type")?.lowercase()?.contains("multipart") != true)
                val n = storage.files.attributes(chunk,m.bytes).size()
                r.header("Content-Length")?.let { require(it.toLongOrNull() == n) }
                val validator = TransferValidator.response(r)
                when(r.status) {
                    206 -> require(!full && r.header("Content-Range") == "bytes $start-$end/${m.bytes}" && n == end-start+1 && (start == 0L || c.validator != null && validator == c.validator))
                    200 -> { require(n == m.bytes); if(start > 0) c = storage.reset(c,m,p) }
                    416 -> { require(r.header("Content-Range") == "bytes */${m.bytes}" && n == 0L && !restarted); c = storage.reset(c,m,p); restarted = true; full = true; continue }
                    else -> error("Unexpected model response")
                }
                c = storage.append(c,m,chunk,n,validator,p)
                synchronized(this) { if(generation == g) publish(ModelTransfer(m.id,c.offset,true,"Downloading · durable checkpoint saved")) }
            } finally { storage.files.remove(chunk) }
        }
        p.check()
        synchronized(this) { if(generation == g) publish(ModelTransfer(m.id,m.bytes,true,"Verifying SHA-256 and installing…")) }
        try { install(storage.files.file(c.stage),file(m),m,p) }
        catch(e: CancellationException) { throw e }
        catch(e: Exception) {
            p.check()
            // Invalid completed bytes are reset, so an explicit retry can actually fetch replacement bytes.
            if(storage.files.exists(storage.files.file(c.stage)) && runCatching { ModelCatalog.verify(storage.files.file(c.stage),m) }.isFailure) storage.reset(c,m,p)
            throw e
        }
        p.check(); storage.finish(m)
    }
    suspend fun waitForExit() { task?.join() }
    suspend fun delete(model: SpeechModel) {
        synchronized(this) {
            check(!deleting && generation == null && task?.isCompleted != false) { "Wait for the model operation to finish." }
            deleting = true
            publish(ModelTransfer(model.id,active = true,message = "Deleting · waiting for native readers to exit…",pausable = false))
        }
        var removed = false
        try {
            withContext(NonCancellable) { NativeTasks.run { storage.files.remove(file(model)); removed = true } }
        } finally {
            synchronized(this) {
                val c = runCatching { storage.read(model) }.getOrNull()
                publish(ModelTransfer(model.id,c?.offset ?: 0,message = if(removed) "Installed model deleted. Selection unchanged." else "Model deletion failed. Check private storage.",paused = c != null))
                deleting = false
            }
        }
    }
    companion object {
        @Volatile private var instance: ModelManager? = null
        fun get(context: Context) = instance ?: synchronized(this) { instance ?: ModelManager(File(context.noBackupFilesDir,"speech-models")).also { instance = it } }
    }
}
