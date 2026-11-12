package dev.parla.android

import java.io.File
import java.io.FileOutputStream
import java.io.IOException

/** AtomicFile-compatible recovery, with checked finalization instead of logged failures. */
internal class DurableFile(val baseFile: File, private val output: (File) -> FileOutputStream = { FileOutputStream(it) }) {
    private val pending = File(baseFile.path+".new")
    private val backup = File(baseFile.path+".bak")
    private fun recover() {
        if(backup.exists()) {
            if(baseFile.exists() && !baseFile.delete()) throw IOException("Could not replace original")
            if(!backup.renameTo(baseFile)) throw IOException("Could not restore backup")
        }
    }
    fun read(maximum: Int? = null): ByteArray? {
        recover()
        // A leftover .new is uncommitted; preserve it when there is no base, as AtomicFile does.
        if(baseFile.exists() && pending.exists() && !pending.delete()) throw IOException("Could not remove incomplete write")
        return if(baseFile.exists()) baseFile.inputStream().use { if(maximum == null) it.readBytes() else it.readNBytes(maximum) } else null
    }
    fun write(bytes: ByteArray) {
        recover()
        val directory = baseFile.parentFile!!
        if(!directory.isDirectory && !directory.mkdirs()) throw IOException("Could not create storage folder")
        try {
            output(pending).use { stream -> stream.write(bytes); stream.fd.sync() }
            if(!pending.renameTo(baseFile)) throw IOException("Could not publish durable write")
            syncDirectory(directory)
        } finally { pending.delete() }
    }
    fun delete() { baseFile.delete(); pending.delete(); backup.delete() }
}

internal class FileStateStorage(private val file: DurableFile) : StateStorage {
    override fun read() = file.read()?.toString(Charsets.UTF_8)
    override fun write(value: String) = file.write(value.toByteArray(Charsets.UTF_8))
    override fun preserveOriginal() {
        val original = file.baseFile
        if(original.exists()) original.copyTo(File(original.parentFile,"parla-data.pre-repair-${System.currentTimeMillis()}.json"),overwrite = false)
    }
}
