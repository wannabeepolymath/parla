package dev.parla.android

import java.io.File
import java.io.InputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import kotlinx.coroutines.CancellationException

data class SpeechModel(val id: String, val name: String, val bytes: Long, val sha256: String) {
    val filename get() = "ggml-$id.bin"
    val url get() = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$filename"
}
object ModelCatalog {
    val all = listOf(
        SpeechModel("base.en","Base (English)",147964211,"a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"),
        SpeechModel("small.en-q5_1","Small (English, quantized)",190098681,"bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30"),
        SpeechModel("large-v3-turbo-q5_0","Large v3 Turbo (quantized)",574041195,"394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"))
    fun verify(file: File, model: SpeechModel) {
        require(Files.isRegularFile(file.toPath(),java.nio.file.LinkOption.NOFOLLOW_LINKS) && (Files.getAttribute(file.toPath(),"unix:nlink",java.nio.file.LinkOption.NOFOLLOW_LINKS) as Number).toLong() == 1L && file.length() == model.bytes) { "This speech model is missing or damaged. Download it again in Models." }
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val first = stream.readNBytes(512)
            val prefix = first.toString(Charsets.UTF_8).trim().lowercase()
            require(listOf("<!doctype","<html","<head","<?xml").none { prefix.startsWith(it) }) { "Download returned a web page, not a model." }
            hash.update(first); val buf = ByteArray(1024*1024)
            while(true) { val n = stream.read(buf); if(n < 0) break; hash.update(buf,0,n) }
        }
        val actual = hash.digest().joinToString("") { "%02x".format(it) }
        require(actual == model.sha256) { "The download could not be verified. Any installed model is kept. Download again." }
    }
    /** Same-directory atomic rename. Failure never deletes the previous usable model. */
    fun install(part: File, dest: File, model: SpeechModel, allowed: () -> Boolean = { true }) {
        verify(part,model)
        if(!allowed()) throw CancellationException("Install canceled")
        Files.move(part.toPath(),dest.toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING)
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
