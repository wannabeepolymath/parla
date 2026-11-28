package dev.parla.android

import java.io.File
import java.io.InputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import kotlinx.coroutines.CancellationException

/**
 * [sha256] is a catalog pin and stays empty for an imported model: nothing is pinned for a user's own file.
 * [importID] (imported only) is a fresh UUID per import, so records bound to one file never apply to its replacement.
 */
data class SpeechModel(val id: String, val name: String, val bytes: Long, val sha256: String, val importID: String = "") {
    val imported get() = importID.isNotEmpty()
    val filename get() = if(imported) "model-$importID.bin" else "ggml-$id.bin"
    val url get() = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$filename"
    /** Model-bound identity for Safe Start records: the catalog pin, or the import's own identity. */
    val key get() = if(imported) "$IMPORTED_ID:$importID" else "$id:$sha256"
    companion object { const val IMPORTED_ID = "imported" }
}
object ModelCatalog {
    val all = listOf(
        SpeechModel("base.en","Base (English)",147964211,"a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"),
        SpeechModel("small.en-q5_1","Small (English, quantized)",190098681,"bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30"),
        SpeechModel("large-v3-turbo-q5_0","Large v3 Turbo (quantized)",574041195,"394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"))
    fun verify(file: File, model: SpeechModel) {
        if(model.imported) return ImportedModelFile.verify(file,model)
        require(Files.isRegularFile(file.toPath(),java.nio.file.LinkOption.NOFOLLOW_LINKS) && (Files.getAttribute(file.toPath(),"unix:nlink",java.nio.file.LinkOption.NOFOLLOW_LINKS) as Number).toLong() == 1L && file.length() == model.bytes) { "This speech model is missing or damaged. Download it again in Models." }
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val first = stream.readNBytes(512)
            require(!looksLikeMarkup(first)) { "Download returned a web page, not a model." }
            hash.update(first); val buf = ByteArray(1024*1024)
            while(true) { val n = stream.read(buf); if(n < 0) break; hash.update(buf,0,n) }
        }
        val actual = hash.digest().joinToString("") { "%02x".format(it) }
        require(actual == model.sha256) { "The download could not be verified. Any installed model is kept. Download again." }
    }
    /**
     * Mac verify-once: a full [verify] is trusted while the file's canonical path, length, mtime and model identity
     * stay the same. In memory only, so each process verifies once. [forget] on any model mutation or failed load.
     */
    private val trusted = java.util.concurrent.ConcurrentHashMap<String,String>()
    fun verifyOnce(file: File, model: SpeechModel) {
        val path = file.canonicalPath
        val stamp = "${file.length()}:${file.lastModified()}:${model.key}" // read before hashing: a change during it misses next time
        if(trusted[path] == stamp) return
        trusted.remove(path)
        verify(file,model)
        trusted[path] = stamp
    }
    fun forget(file: File? = null) { if(file == null) trusted.clear() else trusted.remove(file.canonicalPath) }
    fun looksLikeMarkup(head: ByteArray): Boolean {
        val prefix = head.copyOf(minOf(head.size,512)).toString(Charsets.UTF_8).trim().lowercase()
        return listOf("<!doctype","<html","<head","<?xml").any { prefix.startsWith(it) }
    }
    /** Same-directory atomic rename. Failure never deletes the previous usable model. */
    fun install(part: File, dest: File, model: SpeechModel, allowed: () -> Boolean = { true }) {
        verify(part,model)
        if(!allowed()) throw CancellationException("Install canceled")
        Files.move(part.toPath(),dest.toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING); forget()
    }
    fun copyDownload(input: InputStream, part: File, model: SpeechModel, canceled: () -> Boolean, progress: (Long) -> Unit) {
        var count = 0L
        part.outputStream().use { out ->
            val buf = ByteArray(64*1024)
            while(true) {
                if(canceled()) throw CancellationException("Download canceled")
                val n = input.read(buf); if(n < 0) break
                count += n; require(count <= model.bytes) { "Model response exceeds pinned size" }
                out.write(buf,0,n); progress(count)
            }
            out.fd.sync()
        }
        require(count == model.bytes) { "The model download is incomplete. Download again." }
    }
}
/**
 * A user's own whisper.cpp ggml file. Untrusted: Parla cannot say where it came from, so it is never
 * compared with (or given) a catalog pin. Its container header and size are checked before every load.
 */
internal object ImportedModelFile {
    const val MIN_BYTES = 8L*1024*1024 // the smallest published whisper model (tiny q5_1) is ~31 MB
    const val MAX_BYTES = 2_000_000_000L // large-v3-turbo f16 is 1.6 GB; anything larger will not run on a phone
    const val HEADER_BYTES = 48
    private const val MAGIC = 0x67676d6c // GGML_FILE_MAGIC
    /** The hparams whisper_model_load reads, in order, so a mismatched file fails here rather than in native code. */
    fun header(head: ByteArray): Boolean {
        if(head.size < HEADER_BYTES) return false
        val b = java.nio.ByteBuffer.wrap(head).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        fun h(i: Int) = b.getInt(4+4*i)
        val state = h(2); val ftype = h(10)
        return b.getInt(0) == MAGIC && h(0) in 51864..51866 && h(1) == 1500 && state in setOf(384,512,768,1024,1280) &&
            h(3) in 1..32 && h(4) in setOf(4,6,12,24,32) && h(5) == 448 && h(6) == state && h(7) == h(3) && h(8) in 1..32 &&
            h(9) in setOf(80,128) && ftype >= 0 && ftype/1000 <= 2 && ftype%1000 in 0..27 && ftype%1000 !in 4..6 // 4-6 abort in ggml_ftype_to_ggml_type
    }
    fun verify(file: File, model: SpeechModel) {
        val path = file.toPath(); val nofollow = java.nio.file.LinkOption.NOFOLLOW_LINKS
        require(Files.isRegularFile(path,nofollow) && (Files.getAttribute(path,"unix:nlink",nofollow) as Number).toLong() == 1L &&
            model.bytes in MIN_BYTES..MAX_BYTES && file.length() == model.bytes) { "Your imported model is missing or changed. Import it again in Models." }
        require(header(file.inputStream().use { it.readNBytes(HEADER_BYTES) })) { NOT_WHISPER }
    }
    /** Header first, so a wrong file is refused before gigabytes are copied. Returns the byte count after fsync. */
    fun copy(input: InputStream, part: File, canceled: () -> Boolean, min: Long = MIN_BYTES, max: Long = MAX_BYTES): Long {
        var count = 0L
        part.outputStream().use { out ->
            val head = input.readNBytes(HEADER_BYTES)
            require(!ModelCatalog.looksLikeMarkup(head)) { "This is a web page, not a model file." }
            require(header(head)) { NOT_WHISPER }
            out.write(head); count = head.size.toLong()
            val buf = ByteArray(64*1024)
            while(true) {
                if(canceled()) throw CancellationException("Import canceled")
                val n = input.read(buf); if(n < 0) break
                count += n; require(count <= max) { "This model is too large for a phone. Choose a file under 2 GB." }
                out.write(buf,0,n)
            }
            out.fd.sync()
        }
        require(count >= min) { "This file is too small to be a Whisper model." }
        return count
    }
    const val NOT_WHISPER = "This file is not a Whisper model Parla can use. Choose a whisper.cpp ggml .bin file."
}
