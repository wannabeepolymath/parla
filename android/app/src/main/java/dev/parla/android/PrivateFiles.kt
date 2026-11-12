package dev.parla.android

import java.io.File
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.*
import java.nio.file.StandardOpenOption.*
import java.nio.file.attribute.BasicFileAttributes
import java.nio.file.attribute.PosixFilePermissions
import java.util.UUID

internal fun syncDirectory(directory: File) { FileChannel.open(directory.toPath(),READ).use { it.force(true) } }

/** Only app-private, regular, singly linked leaves. Unknown files are never swept. */
internal class PrivateFiles(val root: File) {
    private val path = root.toPath().toAbsolutePath().normalize()
    private val identity: Any?
    init {
        Files.createDirectories(path)
        // System aliases above the private folder are allowed; the folder itself must not be a link.
        require(!Files.isSymbolicLink(path)) { "Private folder aliases are refused." }
        Files.setPosixFilePermissions(path, PosixFilePermissions.fromString("rwx------"))
        identity = Files.readAttributes(path,BasicFileAttributes::class.java,NOFOLLOW_LINKS).fileKey()
    }
    fun checkRoot() {
        val a = Files.readAttributes(path,BasicFileAttributes::class.java,NOFOLLOW_LINKS)
        require(a.isDirectory && a.fileKey() == identity) { "Private folder changed." }
    }
    fun file(name: String): File {
        checkRoot(); require(Regex("[A-Za-z0-9._-]{1,120}").matches(name) && name !in setOf(".","..")) { "Unexpected private filename." }
        return path.resolve(name).toFile()
    }
    fun attributes(file: File, maximum: Long): BasicFileAttributes {
        require(file.toPath().toAbsolutePath().normalize().parent == path) { "Outside private folder." }
        checkRoot()
        val a = Files.readAttributes(file.toPath(),BasicFileAttributes::class.java,NOFOLLOW_LINKS)
        require(a.isRegularFile && a.size() in 0..maximum) { "Private file is unsafe or oversized." }
        // Both Android's Linux provider and JVM Unix test hosts expose nlink.
        require((Files.getAttribute(file.toPath(),"unix:nlink",NOFOLLOW_LINKS) as Number).toLong() == 1L) { "Private file aliases are refused." }
        return a
    }
    fun exists(file: File) = Files.exists(file.toPath(),NOFOLLOW_LINKS)
    fun create(name: String): File = file(name).also {
        Files.createFile(it.toPath(),PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")))
    }
    fun channel(file: File, maximum: Long, write: Boolean = false): FileChannel {
        val before = attributes(file,maximum)
        val c = if(write) FileChannel.open(file.toPath(),READ,WRITE,NOFOLLOW_LINKS) else FileChannel.open(file.toPath(),READ,NOFOLLOW_LINKS)
        try {
            require(attributes(file,maximum).fileKey() == before.fileKey() && c.size() == before.size()) { "Private file changed." }
            return c
        } catch(t: Throwable) { c.close(); throw t }
    }
    fun read(file: File, maximum: Int): ByteArray = channel(file,maximum.toLong()).use { c ->
        val b = ByteBuffer.allocate(c.size().toInt()); while(b.hasRemaining()) require(c.read(b) >= 0); b.array()
    }
    fun syncDirectory() = syncDirectory(root)
    fun publish(temp: File, destination: File) {
        attributes(temp,Long.MAX_VALUE)
        if(exists(destination)) attributes(destination,Long.MAX_VALUE)
        require(destination.parentFile == root.absoluteFile) { "Outside private folder." }
        Files.move(temp.toPath(),destination.toPath(),ATOMIC_MOVE,REPLACE_EXISTING); syncDirectory()
    }
    fun atomic(destination: File, bytes: ByteArray, commit: (() -> Unit) -> Unit = { it() }) {
        val temp = create("journal-${UUID.randomUUID()}.tmp")
        try {
            channel(temp,0,true).use { c -> val b = ByteBuffer.wrap(bytes); while(b.hasRemaining()) c.write(b); c.force(true) }
            commit { publish(temp,destination) }
        } finally { if(exists(temp)) remove(temp) }
    }
    fun remove(file: File) {
        if(!exists(file)) return
        attributes(file,Long.MAX_VALUE); Files.delete(file.toPath()); syncDirectory()
    }
    fun names(maximum: Int = 256): List<String> {
        checkRoot()
        return Files.newDirectoryStream(path).use { entries ->
            val names = mutableListOf<String>(); for(entry in entries) { require(names.size < maximum) { "Private folder file limit reached." }; names += entry.fileName.toString() }; names
        }
    }
}
