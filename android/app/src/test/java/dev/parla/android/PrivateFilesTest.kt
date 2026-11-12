package dev.parla.android

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PrivateFilesTest {
    @get:Rule val temporary = TemporaryFolder()
    private fun aliasedRoot(): File {
        val parent = temporary.newFolder("parent").canonicalFile
        val alias = File(temporary.root.canonicalFile,"alias")
        Files.createSymbolicLink(alias.toPath(),parent.toPath())
        return File(alias,"private")
    }
    @Test fun parentAliasPreservesCallerPathsAndFileOperations() {
        val root = aliasedRoot()
        val files = PrivateFiles(root)
        val destination = File(root,"saved")
        assertNotEquals(root.toPath(),root.toPath().toRealPath())
        assertEquals(destination,files.file("saved"))
        files.atomic(destination,"first".toByteArray())
        files.atomic(destination,"updated".toByteArray())
        assertEquals(7L,files.attributes(destination,7).size())
        assertEquals("updated",files.read(destination,7).toString(Charsets.UTF_8))
        assertEquals(listOf("saved"),files.names())
        files.remove(destination)
        assertTrue(files.names().isEmpty())
    }
    @Test fun privateFolderSymlinkIsRefused() {
        val target = temporary.newFolder("target").canonicalFile
        val root = File(temporary.root.canonicalFile,"private")
        Files.createSymbolicLink(root.toPath(),target.toPath())
        val error = assertThrows(IllegalArgumentException::class.java) { PrivateFiles(root) }
        assertEquals("Private folder aliases are refused.",error.message)
    }
    @Test fun privateFolderReplacedByDirectoryIsRefusedThroughParentAlias() {
        val root = aliasedRoot()
        val files = PrivateFiles(root)
        Files.move(root.toPath(),root.toPath().resolveSibling("original"))
        Files.createDirectory(root.toPath())
        val error = assertThrows(IllegalArgumentException::class.java) { files.checkRoot() }
        assertEquals("Private folder changed.",error.message)
    }
    @Test fun privateFolderReplacedBySymlinkIsRefusedThroughParentAlias() {
        val root = aliasedRoot()
        val files = PrivateFiles(root)
        val original = root.toPath().resolveSibling("original")
        Files.move(root.toPath(),original)
        Files.createSymbolicLink(root.toPath(),original)
        val error = assertThrows(IllegalArgumentException::class.java) { files.checkRoot() }
        assertEquals("Private folder changed.",error.message)
    }
}
