package dev.parla.android

import android.content.Context
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

/**
 * Port of the desktop SavedAudioImportStore: one bounded ledger of explicitly kept import copies and their
 * accepted transcripts. 10 jobs, 20 MiB per source, 1 MiB per result, a 256 MiB logical quota, 7-day expiry.
 * The ledger is published (fsync + atomic rename) before and after every payload write, so a crash leaves
 * either a known staging/deleting job or an orphan this store can prove it wrote. Unknown files are never swept.
 * ponytail: no tombstone files or borrow handles; the ledger's deleting state and one in-process active job cover a single-process app.
 */
internal class SavedImportStore(directory: File, private val clock: () -> Long = System::currentTimeMillis) {
    enum class State { staging, committed, queued, running, failed, canceled, interrupted, deleting }
    enum class Association { notSaved, savingIntent, saved, unknown }
    data class Result(val id: String, val attempt: Long, val bytes: Long, val hash: String, val date: Long, val model: String, val language: String, val association: Association)
    data class Job(val id: String, val label: String, val created: Long, val sourceBytes: Long, val sourceHash: String, val state: State, val attempt: Long, val result: Result?) {
        val expires get() = created + TTL_MS
    }
    data class Row(val id: String, val label: String, val created: Long, val expires: Long, val sourceBytes: Long, val state: State, val result: Result?, val sourceAvailable: Boolean)
    data class Token(val job: String, val attempt: Long)
    class Failure(message: String) : Exception(message)

    private val files by lazy { PrivateFiles(directory) }
    private var jobs: List<Job>? = null
    private var active: String? = null
    private val rowsValue = MutableStateFlow<List<Row>>(emptyList())
    val rows = rowsValue.asStateFlow()
    private val failureValue = MutableStateFlow<String?>(null)
    val failure = failureValue.asStateFlow()

    private fun fail(message: String): Nothing = throw Failure(message)
    private fun sourceName(id: String) = "$id.source"
    private fun resultName(id: String, result: String) = "$id.$result.txt"
    private fun current(): List<Job> = jobs ?: fail(failureValue.value ?: UNAVAILABLE)
    private fun job(id: String) = current().firstOrNull { it.id == id } ?: fail("This saved file is no longer available.")
    private fun publish(next: List<Job>) {
        val bytes = encode(next).toByteArray()
        if(bytes.size > MAX_LEDGER) fail("Saved files are full. Delete one first.")
        if(charge(next) > QUOTA) fail("Saved files are full. Delete one first.")
        files.atomic(files.file(MANIFEST), bytes)
        jobs = next; refresh()
    }
    private fun replace(job: Job) = publish(current().map { if(it.id == job.id) job else it })
    private fun refresh() {
        rowsValue.value = jobs.orEmpty().map { j ->
            val available = j.state != State.staging && j.state != State.deleting && runCatching { files.attributes(files.file(sourceName(j.id)), MAX_SOURCE.toLong()).size() == j.sourceBytes }.getOrDefault(false)
            Row(j.id, j.label, j.created, j.expires, j.sourceBytes,
                if((j.state == State.queued || j.state == State.running) && j.id != active) State.interrupted else j.state, j.result, available)
        }
    }
    private fun remove(name: String) { files.remove(files.file(name)) }

    /** Loads, recovers interrupted writes and deletions, and removes expired jobs. A refusal keeps every file. */
    @Synchronized fun load(): List<Row> {
        try {
            val names = files.names()
            val loaded = if(MANIFEST in names) decode(files.read(files.file(MANIFEST), MAX_LEDGER).toString(Charsets.UTF_8)) else emptyList()
            val now = clock()
            // A clock earlier than a saved job's creation would extend its expiry; refuse instead.
            if(loaded.any { now < it.created }) fail("Your device clock changed. Saved files are kept; check the date and time.")
            val ids = loaded.associateBy { it.id }
            for(name in names) {
                if(name == MANIFEST) continue
                val (owner, kind) = name.split('.', limit = 2).let { it[0] to it.getOrElse(1) { "" } }
                val job = ids[owner]
                val referenced = job != null && (name == sourceName(owner) && job.state != State.staging || job.result?.let { name == resultName(owner, it.id) } == true)
                when {
                    referenced -> Unit
                    // The atomic writer's own temporary file, or a payload of a job this ledger still owns.
                    JOURNAL.matches(name) || job != null && (kind == "source" || RESULT.matches(kind)) -> remove(name)
                    else -> fail(UNKNOWN)
                }
            }
            jobs = loaded
            // A failed removal stays durably deleting and is retried by maintenance().
            for(j in loaded) if(j.state == State.staging || j.state == State.deleting || now >= j.expires) runCatching { erase(j.id) }
            failureValue.value = null
        } catch(e: Exception) {
            jobs = null; failureValue.value = (e as? Failure)?.message ?: UNKNOWN
        }
        refresh(); return rowsValue.value
    }

    /** Explicit "Save a copy and transcribe": durably copies [source], then starts the first attempt. */
    @Synchronized fun admit(source: File, label: String): Token {
        val all = current()
        if(active != null || all.any { it.state == State.staging || it.state == State.deleting }) fail("Wait for the current saved file to finish.")
        if(all.size >= MAX_JOBS) fail("You can keep up to $MAX_JOBS files. Delete one first.")
        val size = source.length()
        if(size !in 1..MAX_SOURCE.toLong()) fail("Use a file under 20 MB.")
        val bytes = source.readBytes().also { if(it.size.toLong() != size) fail("The file changed. Choose it again.") }
        val job = Job(UUID.randomUUID().toString(), cleanLabel(label), clock(), size, digest(bytes), State.staging, 0, null)
        publish(all + job)
        try { files.atomic(files.file(sourceName(job.id)), bytes) } catch(e: Exception) { runCatching { erase(job.id) }; fail("Couldn’t save a copy. Free storage and try again.") }
        replace(job.copy(state = State.committed))
        return begin(job.id)
    }
    /** One attempt at a time; a newer attempt makes any older token stale. */
    @Synchronized fun begin(id: String): Token {
        val j = job(id)
        if(active != null) fail("Wait for the current transcription to finish.")
        if(j.state == State.staging || j.state == State.deleting || clock() >= j.expires) fail("This saved file is no longer available.")
        val next = j.copy(state = State.queued, attempt = j.attempt + 1)
        replace(next); active = id; refresh()
        return Token(id, next.attempt)
    }
    private fun owned(token: Token): Job = job(token.job).also {
        if(it.attempt != token.attempt || it.state == State.deleting || clock() >= it.expires) fail("This saved file changed. Try again.")
    }
    @Synchronized fun running(token: Token) = replace(owned(token).copy(state = State.running))
    /** The verified private copy; its size and digest must still match the ledger. */
    @Synchronized fun source(token: Token): File {
        val j = owned(token); val file = files.file(sourceName(j.id))
        val bytes = files.read(file, MAX_SOURCE)
        if(bytes.size.toLong() != j.sourceBytes || digest(bytes) != j.sourceHash) fail("The saved copy is damaged. Delete it.")
        return file
    }
    @Synchronized fun finish(token: Token, canceled: Boolean) {
        release(token)
        val j = jobs?.firstOrNull { it.id == token.job } ?: return
        if(j.attempt == token.attempt && j.state != State.deleting && j.state != State.committed) runCatching { replace(j.copy(state = if(canceled) State.canceled else State.failed)) }
        refresh()
    }
    /** Storage-only and idempotent for the same [resultID]: retrying never re-runs recognition. */
    @Synchronized fun saveResult(token: Token, resultID: String, text: String, model: String, language: String, date: Long): Result {
        // Recognition is over either way; a failed write is shown as interrupted and retried from RAM.
        try {
            val j = owned(token)
            val bytes = text.toByteArray()
            if(bytes.isEmpty() || bytes.size > MAX_RESULT || text.isBlank()) fail("This transcript is empty or too long to keep.")
            j.result?.takeIf { it.id == resultID }?.let { return it }
            val result = Result(UUID.fromString(resultID).toString(), token.attempt, bytes.size.toLong(), digest(bytes), date, model, language, Association.notSaved)
            files.atomic(files.file(resultName(j.id, result.id)), bytes)
            replace(j.copy(state = State.committed, result = result))
            j.result?.let { old -> runCatching { remove(resultName(j.id, old.id)) } }
            return result
        } finally { release(token); refresh() }
    }
    /** Only the current attempt's own exit frees the job; a stale token never releases a newer attempt. */
    private fun release(token: Token) { if(active == token.job && jobs?.firstOrNull { it.id == token.job }?.attempt == token.attempt) active = null }
    @Synchronized fun openResult(id: String): Pair<Result, String> {
        val j = job(id); val r = j.result ?: fail("This saved file has no transcript yet.")
        if(j.state == State.deleting || clock() >= j.expires) fail("This saved file is no longer available.")
        val bytes = files.read(files.file(resultName(id, r.id)), MAX_RESULT)
        if(bytes.size.toLong() != r.bytes || digest(bytes) != r.hash) fail("The saved transcript is damaged. Delete it.")
        return r to bytes.toString(Charsets.UTF_8)
    }
    @Synchronized fun association(id: String, resultID: String, state: Association): Result {
        val j = job(id); val r = j.result?.takeIf { it.id == resultID } ?: fail("This transcript changed. Open it again.")
        val next = r.copy(association = state); replace(j.copy(result = next)); return next
    }
    /** Deleting is durable intent first, then payload removal, then the job leaves the ledger. */
    @Synchronized fun delete(id: String) {
        if(active == id) fail("Cancel the transcription first.")
        erase(id)
    }
    private fun erase(id: String) {
        val j = job(id)
        if(j.state != State.deleting) replace(j.copy(state = State.deleting))
        remove(sourceName(id)); j.result?.let { remove(resultName(id, it.id)) }
        publish(current().filterNot { it.id == id })
    }
    /** Expired jobs are removed whenever the screen opens; a running job is left to finish. */
    @Synchronized fun maintenance() {
        val now = clock()
        current().filter { (now >= it.expires || it.state == State.deleting) && it.id != active }.forEach { runCatching { erase(it.id) } }
        refresh()
    }

    companion object {
        const val MAX_JOBS = 10
        const val MAX_SOURCE = 20 * 1024 * 1024
        const val MAX_RESULT = 1024 * 1024
        const val MAX_LEDGER = 65_536
        const val QUOTA = 256L * 1024 * 1024
        const val TTL_MS = 7 * 86_400_000L
        private const val MANIFEST = "manifest.json"
        private const val UNAVAILABLE = "Saved files are unavailable right now."
        private const val UNKNOWN = "Saved files couldn’t be checked. They were kept. Try again later."
        private val JOURNAL = Regex("journal-[0-9a-f-]{36}\\.tmp")
        private val RESULT = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.txt")
        private val UUID_TEXT = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
        private val HASH = Regex("[0-9a-f]{64}")

        fun digest(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        /** Mac charge: ledger copies, owner, lock, ten tombstone reserves and one candidate, plus every source and accepted result. */
        fun charge(jobs: List<Job>): Long = 2L * 65_536 + 4096 + 10 * 4096 + 1_048_576 + jobs.sumOf { it.sourceBytes + (it.result?.bytes ?: 0) }
        fun cleanLabel(label: String): String {
            val clean = label.map { if(it.isISOControl()) ' ' else it }.joinToString("").trim().ifEmpty { "Audio file" }
            var out = clean; while(out.toByteArray().size > 640) out = out.dropLast(1)
            return out
        }

        fun encode(jobs: List<Job>): String = JSONObject().put("schema", 1).put("jobs", JSONArray(jobs.map { j ->
            JSONObject().put("id", j.id).put("label", j.label).put("created", j.created).put("sourceBytes", j.sourceBytes).put("sourceHash", j.sourceHash)
                .put("state", j.state.name).put("attempt", j.attempt).put("result", j.result?.let { r ->
                    JSONObject().put("id", r.id).put("attempt", r.attempt).put("bytes", r.bytes).put("hash", r.hash).put("date", r.date)
                        .put("model", r.model).put("language", r.language).put("association", r.association.name)
                } ?: JSONObject.NULL)
        })).toString()

        /** Strict: wrong types, unknown states, duplicates or out-of-bounds values refuse the whole ledger. */
        fun decode(json: String): List<Job> {
            val root = JSONObject(json)
            require(root.length() == 2 && root.get("schema") == 1)
            val array = root.getJSONArray("jobs"); require(array.length() <= MAX_JOBS)
            fun JSONObject.long(key: String): Long = (get(key) as? Number)?.takeIf { it is Int || it is Long }?.toLong() ?: error("Invalid $key")
            fun JSONObject.text(key: String): String = get(key) as? String ?: error("Invalid $key")
            val jobs = (0 until array.length()).map { i ->
                val o = array.getJSONObject(i); require(o.length() == 8)
                val result = o.get("result").let { if(it == JSONObject.NULL) null else (it as JSONObject).let { r ->
                    require(r.length() == 8)
                    Result(r.text("id"), r.long("attempt"), r.long("bytes"), r.text("hash"), r.long("date"), r.text("model"), r.text("language"), Association.valueOf(r.text("association")))
                } }
                Job(o.text("id"), o.text("label"), o.long("created"), o.long("sourceBytes"), o.text("sourceHash"), State.valueOf(o.text("state")), o.long("attempt"), result)
            }
            require(jobs.map { it.id }.distinct().size == jobs.size && charge(jobs) <= QUOTA)
            for(j in jobs) {
                require(UUID_TEXT.matches(j.id) && j.label.isNotEmpty() && j.label.toByteArray().size <= 640 && j.created >= 0 && j.sourceBytes in 1..MAX_SOURCE && HASH.matches(j.sourceHash) && j.attempt >= 0 && j.state != State.interrupted)
                j.result?.let { r -> require(UUID_TEXT.matches(r.id) && r.attempt in 1..j.attempt && r.bytes in 1..MAX_RESULT && HASH.matches(r.hash) && r.date in j.created until j.expires &&
                    r.model.length <= 128 && r.language.length <= 64) }
            }
            return jobs
        }

        @Volatile private var instance: SavedImportStore? = null
        fun get(context: Context): SavedImportStore = instance ?: synchronized(this) {
            instance ?: SavedImportStore(File(context.noBackupFilesDir, "saved-imports")).also { it.load(); instance = it }
        }
    }
}
