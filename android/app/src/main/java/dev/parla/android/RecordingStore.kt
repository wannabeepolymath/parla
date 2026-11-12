package dev.parla.android

import android.content.Context
import java.io.File
import java.nio.ByteBuffer
import java.nio.file.attribute.BasicFileAttributes
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

internal data class AudioDescriptor(val id: String, val created: Long, val expires: Long?, val bytes: Long, val seconds: Double?, val reason: String?)
internal data class AudioRemoval(val removed: Int, val busy: Int, val failed: Int) {
    val message get() = "Removed $removed; busy/skipped $busy; failed $failed."
}
/** Process-owned leases outlive services/screens. No fallback settings may authorize audio use. */
internal class RecordingStore(
    directory: File,
    private val current: () -> LocalData?,
    private val clock: () -> Long = System::currentTimeMillis,
    private val maximumTotal: Long = 128L*1024*1024,
    private val remove: (File) -> Unit = { java.nio.file.Files.delete(it.toPath()) },
) {
    private val files by lazy { PrivateFiles(directory) }
    private data class Identity(val key: Any?, val bytes: Long, val modified: Long)
    internal class Lease internal constructor(val file: File, internal val token: UUID = UUID.randomUUID()) {
        @Volatile var revoked = false; internal set
    }
    private data class Owner(val lease: Lease, val identity: Identity)
    private val owners = mutableMapOf<String,Owner>()
    private val revisionValue = MutableStateFlow(0L)
    val revision = revisionValue.asStateFlow()
    private val errorValue = MutableStateFlow<String?>(null)
    val error = errorValue.asStateFlow()
    private val namePattern = Regex("recovery-[0-9]{13}-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.wav(?:\\.partial)?")
    private fun changed() { revisionValue.value++ }
    private fun failure(message: String) { if(errorValue.value != message) { errorValue.value = message; changed() } }
    private fun settings(): Settings = (current()?.settings ?: error("Repair current settings before saving or using recovery audio.")).also { require(it.recoveryAudioDays in 1..30) }
    private fun stamp(a: BasicFileAttributes) = Identity(a.fileKey(),a.size(),a.lastModifiedTime().toMillis())
    private fun owned(id: String): File {
        require(namePattern.matches(id)) { "Unexpected recovery filename." }
        UUID.fromString(id.substring(23,59))
        return files.file(id)
    }
    private fun date(id: String): Long = id.substring(9,22).toLong().also { require(it > 0 && it <= clock()+60_000) { "Invalid recording date." } }
    private fun metadata(file: File, allowExpired: Boolean = false): Pair<Identity,Double> {
        val s = settings()
        require(!file.name.endsWith(".partial") && !files.exists(files.file(file.name+".discard"))) { "Unfinished or canceled audio; delete explicitly." }
        val a = files.attributes(file,WavInput.MAX_BYTES.toLong())
        require(allowExpired || clock()-date(file.name) < s.recoveryAudioDays*86_400_000L) { "Recording expired." }
        val bytes = files.read(file,WavInput.MAX_BYTES)
        val samples = WavInput.parse(bytes,admitSpeech = false)
        require(stamp(files.attributes(file,WavInput.MAX_BYTES.toLong())) == stamp(a)) { "Recording changed." }
        return stamp(a) to samples.size/16000.0
    }
    /** Copy complete capture, synchronize, then publish atomically before recognition begins. */
    @Synchronized fun stash(source: File, privateSession: Boolean): Lease? {
        if(privateSession) return null
        var published: File? = null
        try {
            val s = settings(); if(!s.recoveryAudioEnabled) return null
            prune()
            require(source.absoluteFile.toPath().normalize() == source.toPath().toRealPath()) { "Capture aliases are refused." }
            val a = Files.readAttributes(source.toPath(),BasicFileAttributes::class.java,NOFOLLOW_LINKS)
            require(a.isRegularFile && a.size() in 44L..WavInput.MAX_BYTES.toLong() && (Files.getAttribute(source.toPath(),"unix:nlink",NOFOLLOW_LINKS) as Number).toLong() == 1L)
            val bytes = java.nio.channels.FileChannel.open(source.toPath(),java.nio.file.StandardOpenOption.READ,NOFOLLOW_LINKS).use { input ->
                val buffer = ByteBuffer.allocate(a.size().toInt()); while(buffer.hasRemaining()) require(input.read(buffer) >= 0); buffer.array()
            }
            require(stamp(Files.readAttributes(source.toPath(),BasicFileAttributes::class.java,NOFOLLOW_LINKS)) == stamp(a)) { "Capture changed." }
            WavInput.parse(bytes,admitSpeech = false)
            val names = files.names()
            // Unknown/unfinished leaves also count toward quota; never silently evict useful failed audio.
            val total = names.sumOf { files.attributes(files.file(it),maximumTotal).size() }
            require(names.size < 128 && total <= maximumTotal-bytes.size) { "Recovery quota reached (128MiB / 128 files). Delete or clear recordings; dictation can continue." }
            val file = owned("recovery-${clock()}-${UUID.randomUUID()}.wav")
            published = file
            val partial = files.create(file.name+".partial")
            try {
                files.channel(partial,0,true).use { out ->
                    val buffer = ByteBuffer.wrap(bytes); while(buffer.hasRemaining()) out.write(buffer); out.force(true)
                }
                files.publish(partial,file)
            } catch(t: Throwable) {
                // Interrupted writes have a dated, unavailable marker and remain explicitly deletable/expirable.
                if(files.exists(partial)) runCatching { files.remove(partial) }
                throw t
            }
            val lease = Lease(file); owners[file.name] = Owner(lease,stamp(files.attributes(file,WavInput.MAX_BYTES.toLong()))); changed(); return lease
        } catch(_: Exception) {
            published?.let { file -> if(files.exists(file)) {
                runCatching { removeOwned(file) }.onFailure { runCatching { files.atomic(files.file(file.name+".discard"),ByteArray(0)) } }
            } }
            failure("Recovery audio was not saved. Check current settings and free storage; the private quota is 128MiB / 128 files. Dictation can continue."); return null }
    }
    /** Durable cancellation intent blocks crash recovery without deleting a reader's leased bytes. */
    @Synchronized fun cancelCapture(lease: Lease) {
        if(owners[lease.file.name]?.lease !== lease) return
        try { files.atomic(files.file(lease.file.name+".discard"),ByteArray(0)); changed() }
        catch(_: Exception) { failure("Canceled audio could not be marked for purge. It will be retried after the reader exits; check Recovery audio.") }
    }
    private fun recordingNames(): List<String> = files.names().map { it.removeSuffix(".discard") }.filter { namePattern.matches(it) }.distinct()
    @Synchronized fun acquire(id: String): Lease {
        settings(); val file = owned(id)
        check(owners[id] == null) { "Recording is busy; wait for its reader to exit." }
        val meta = metadata(file)
        val lease = Lease(file); owners[id] = Owner(lease,meta.first); changed(); return lease
    }
    @Synchronized fun validate(lease: Lease) {
        settings()
        val owner = owners[lease.file.name]
        check(owner?.lease === lease && !lease.revoked) { "Recording use was stopped." }
        require(metadata(lease.file).first == owner.identity) { "Recording changed; refresh before using it." }
    }
    @Synchronized fun revoke(lease: Lease) { if(owners[lease.file.name]?.lease === lease) lease.revoked = true }
    /** Revoke never releases a busy file. Only the actual reader's exit may relinquish it. */
    @Synchronized fun release(lease: Lease) {
        if(owners[lease.file.name]?.lease !== lease) return
        owners.remove(lease.file.name); lease.revoked = true; changed()
    }
    /** Raw success disposes audio even when cleanup/delivery later fails. Disposal failure is separate from ASR. */
    @Synchronized fun resolve(lease: Lease?, recognized: Boolean, canceledOrPrivate: Boolean = false) {
        if(lease == null) return
        val owner = owners[lease.file.name] ?: return
        if(owner.lease !== lease) return
        try {
            if(recognized || canceledOrPrivate) {
                require(stamp(files.attributes(lease.file,WavInput.MAX_BYTES.toLong())) == owner.identity) { "Recording changed." }
                removeOwned(lease.file)
            }
        } catch(_: Exception) { failure(if(recognized) "Recognition succeeded, but audio disposal failed. Text remains available; delete the recording explicitly." else "Canceled/private audio purge failed. Delete the recording explicitly.") }
        finally { release(lease) }
    }
    @Synchronized fun descriptors(): List<AudioDescriptor> {
        prune()
        return try {
            recordingNames().sortedDescending().map { id ->
                val file = owned(id); val s = current()?.settings
                val created = runCatching { date(id) }.getOrDefault(0)
                val a = runCatching { files.attributes(file,WavInput.MAX_BYTES.toLong()) }.getOrNull()
                val meta = runCatching { metadata(file) }
                AudioDescriptor(id,created,s?.takeIf { created > 0 }?.let { created+it.recoveryAudioDays*86_400_000L },a?.size() ?: 0,meta.getOrNull()?.second,
                    if(owners[id] != null) "Busy: recording/recognition/playback owns this file." else if(meta.isFailure) "Unavailable: settings, expiry, unsafe file or invalid WAV. Delete explicitly." else null)
            }
        } catch(_: Exception) { failure("Recovery folder could not be read. Files were preserved."); emptyList() }
    }
    @Synchronized fun prune(): AudioRemoval {
        val s = current()?.settings
        var removed = 0; var busy = 0; var failed = 0
        try {
            for(id in recordingNames()) {
                val canceled = files.exists(files.file(id+".discard"))
                if(canceled || s != null && runCatching { clock()-date(id) >= s.recoveryAudioDays*86_400_000L }.getOrDefault(false)) {
                    if(owners[id] != null) { busy++; continue }
                    try { removeOwned(owned(id)); removed++ } catch(_: Exception) { failed++ }
                }
            }
        } catch(_: Exception) { failed++ }
        if(removed > 0) changed()
        if(failed > 0) failure("Some expired recovery audio could not be removed. Retry Delete/Clear.")
        return AudioRemoval(removed,busy,failed)
    }
    private fun removeOwned(file: File) {
        if(files.exists(file)) { files.attributes(file,Long.MAX_VALUE); remove(file) }
        val marker = files.file(file.name+".discard")
        if(files.exists(marker)) { files.attributes(marker,0); remove(marker) }
        files.syncDirectory()
    }
    @Synchronized fun delete(id: String): AudioRemoval {
        if(owners[id] != null) return AudioRemoval(0,1,0)
        return try { removeOwned(owned(id)); changed(); AudioRemoval(1,0,0) } catch(_: Exception) { AudioRemoval(0,0,1) }
    }
    @Synchronized fun clear(): AudioRemoval {
        var result = AudioRemoval(0,0,0)
        try {
            for(id in recordingNames()) {
                val next = delete(id); result = AudioRemoval(result.removed+next.removed,result.busy+next.busy,result.failed+next.failed)
            }
        } catch(_: Exception) { result = result.copy(failed = result.failed+1) }
        return result
    }
    companion object {
        @Volatile private var instance: RecordingStore? = null
        fun get(context: Context): RecordingStore = instance ?: synchronized(this) {
            instance ?: Store.get(context).let { store -> RecordingStore(File(context.noBackupFilesDir,"recordings"), { store.data.value.takeIf { store.ready && store.persistenceError.value == null } }) }.also { instance = it }
        }
    }
}

/** Cache cleanup excludes active owners across service recreation in the same process. */
internal object CaptureAudio {
    private val active = mutableSetOf<String>()
    @Synchronized fun reserve(directory: File): File {
        directory.mkdirs()
        return File(directory,"dictation-${UUID.randomUUID()}.wav").also { active += it.absolutePath }
    }
    @Synchronized fun release(file: File) { file.delete(); active -= file.absolutePath }
    @Synchronized fun sweep(directory: File) {
        directory.listFiles()?.filter { it.absolutePath !in active && Regex("dictation-[A-Za-z0-9-]+\\.wav").matches(it.name) && !java.nio.file.Files.isSymbolicLink(it.toPath()) && it.isFile }?.forEach { it.delete() }
    }
}
