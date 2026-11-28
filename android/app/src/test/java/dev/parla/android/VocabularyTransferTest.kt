package dev.parla.android

import org.junit.Assert.*
import org.junit.Test

class VocabularyTransferTest {
    private val mine = LocalData(dictionary = listOf("Parla", "Kubernetes"), snippets = listOf(Snippet("s1", "sig", "Best, D")), replacements = listOf(LiteralReplacement("teh", "the")))
    private fun file(json: String) = json.toByteArray(Charsets.UTF_8)
    private fun message(block: () -> Unit) = runCatching(block).exceptionOrNull()?.message.orEmpty()
    // Exactly what desktop JSONEncoder [.prettyPrinted, .sortedKeys] writes.
    private val desktop = """
        {
          "format" : "parla-vocabulary",
          "replacements" : [
            {
              "replacement" : "the",
              "source" : "teh"
            }
          ],
          "snippets" : {
            "addr" : "1 Main St\/Apt \"2\"\n"
          },
          "version" : 1,
          "words" : [
            "Parla",
            "नमस्ते 👋"
          ]
        }
    """.trimIndent()

    @Test fun desktopFileDecodesAndAndroidEncodesTheSameLayout() {
        val doc = VocabularyDocument.decode(file(desktop))
        assertEquals(listOf("Parla", "नमस्ते 👋"), doc.words)
        assertEquals(mapOf("addr" to "1 Main St/Apt \"2\"\n"), doc.snippets)
        assertEquals(listOf(LiteralReplacement("teh", "the")), doc.replacements)
        assertEquals(desktop, doc.encode().toString(Charsets.UTF_8))
        assertEquals(doc, VocabularyDocument.decode(doc.encode()))
        val empty = VocabularyDocument(emptyList(), emptyMap(), emptyList())
        assertEquals(empty, VocabularyDocument.decode(empty.encode()))
        // Export carries vocabulary only: nothing from settings, history or presets.
        val exported = VocabularyDocument.of(mine.copy(settings = Settings(provider = "custom", providers = mapOf("custom" to ProviderConfig("https://secret.example/v1", "m"))), history = listOf(HistoryEntry(raw = "private", text = "private")))).encode().toString(Charsets.UTF_8)
        assertFalse(exported.contains("secret")); assertFalse(exported.contains("private"))
    }

    @Test fun refusesSettingsDumpsForeignFilesAndOversizedInput() {
        assertEquals("This is a settings file. Choose an exported vocabulary file.", message { VocabularyDocument.decode(file(desktop.replace("\"version\" : 1,", "\"version\" : 1, \"apiKey\" : \"sk\","))) })
        assertEquals("This is a settings file. Choose an exported vocabulary file.", message { VocabularyDocument.decode(file("""{"settings":{},"dictionary":[]}""")) })
        val foreign = "This file isn’t a Parla vocabulary file."
        assertEquals(foreign, message { VocabularyDocument.decode(file(desktop.replace("\"version\" : 1", "\"version\" : 2"))) })
        assertEquals(foreign, message { VocabularyDocument.decode(file(desktop.replace("parla-vocabulary", "other"))) })
        assertEquals(foreign, message { VocabularyDocument.decode(file(desktop.replace("\"source\" : \"teh\"", "\"source\" : \"teh\", \"extra\" : 1"))) })
        assertEquals(foreign, message { VocabularyDocument.decode(file(desktop.replace("\"Parla\",", "null,"))) })
        assertEquals(foreign, message { VocabularyDocument.decode(file("not json")) })
        assertEquals(foreign, message { VocabularyDocument.decode(file("$desktop []")) })
        assertEquals("This file is too large (over 1 MB).", message { VocabularyDocument.decode(ByteArray(VocabularyDocument.MAX_FILE_BYTES + 1)) })
        assertEquals("A word in this file is empty or too long.", message { VocabularyDocument.decode(file(desktop.replace("\"Parla\"", "\"  \""))) })
        assertEquals("A snippet in this file is too long.", message { VocabularyDocument.decode(file(desktop.replace("\"addr\"", "\"${"x".repeat(257)}\""))) })
    }

    @Test fun previewCountsDuplicatesAndConflictsAndMergeKeepsExistingEntries() {
        val incoming = VocabularyDocument(listOf("parla", "New  word", "new word"), mapOf("SIG" to "other", "addr" to "1 Main"), listOf(LiteralReplacement("teh", "THE"), LiteralReplacement("recieve", "receive")))
        val preview = VocabularyImport.preview(incoming.encode(), mine)
        assertEquals(listOf("parla", "New word"), preview.incoming.words)
        assertEquals(1, preview.duplicates)
        assertEquals(listOf("Word: parla", "Snippet: SIG", "Replacement: teh"), preview.conflicts)
        val merged = preview.result(mine, VocabularyImport.Mode.merge, confirmedReplace = false)
        assertEquals(listOf("Parla", "Kubernetes", "New word"), merged.dictionary)
        assertEquals(listOf("sig", "addr"), merged.snippets.map { it.trigger }); assertEquals("s1", merged.snippets.first().id)
        assertEquals(listOf(LiteralReplacement("teh", "the"), LiteralReplacement("recieve", "receive")), merged.replacements)
    }

    @Test fun replaceRequiresExplicitConfirmationAndAFreshPreview() {
        val preview = VocabularyImport.preview(VocabularyDocument(listOf("Only"), emptyMap(), emptyList()).encode(), mine)
        assertEquals("Confirm before replacing your vocabulary.", message { preview.result(mine, VocabularyImport.Mode.replace, confirmedReplace = false) })
        val replaced = preview.result(mine, VocabularyImport.Mode.replace, confirmedReplace = true)
        assertEquals(listOf("Only"), replaced.dictionary); assertTrue(replaced.snippets.isEmpty()); assertTrue(replaced.replacements.isEmpty())
        val changed = mine.copy(dictionary = mine.dictionary + "Edited since preview")
        assertEquals("Your vocabulary changed. Choose the file again.", message { preview.result(changed, VocabularyImport.Mode.replace, confirmedReplace = true) })
    }

    @Test fun importRespectsAndroidStorageLimitsAndUniqueReplacements() {
        val many = VocabularyDocument(List(1000) { "word$it" }, emptyMap(), emptyList())
        assertTrue(message { VocabularyImport.preview(many.encode(), mine).result(mine, VocabularyImport.Mode.merge, false) }.contains("1,000"))
        assertEquals(1000, VocabularyImport.preview(many.encode(), mine).result(mine, VocabularyImport.Mode.replace, true).dictionary.size)
        val twice = VocabularyDocument(emptyList(), emptyMap(), listOf(LiteralReplacement("a", "b"), LiteralReplacement("a", "c")))
        assertEquals("This file has the same replacement twice.", message { VocabularyImport.preview(twice.encode(), mine) })
    }
}
