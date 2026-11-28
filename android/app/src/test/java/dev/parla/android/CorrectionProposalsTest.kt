package dev.parla.android

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class CorrectionProposalsTest {
    private fun propose(before: String, after: String, inserted: String = before, dictionary: List<String> = emptyList()) =
        DictionaryLearner.propose(inserted, before, after, dictionary, now = 7)

    @Test fun oneRespelledWordParlaWroteBecomesAProposal() {
        assertEquals(CorrectionProposal("Shunade", "Sinead", 7), propose("Meet Shunade at noon.", "Meet Sinead at noon."))
        // Case, punctuation and curly quotes are not edits.
        assertEquals("Sinead", propose("“Meet Shunade,” she said.", "\"Meet Sinead,\" She said.")?.to)
        assertEquals("Kubernetes", propose("Deploy to Cubernetes today", "Deploy to Kubernetes today")?.to)
    }

    @Test fun anythingOtherThanASingleWordFixIsIgnored() {
        assertNull(propose("Meet Shunade at noon.", "Meet Shunade at noon."))            // nothing changed
        assertNull(propose("Meet Shunade at noon.", "Meet Sinead at noon today."))       // insertion
        assertNull(propose("Meet Shunade at noon.", "Meet at noon."))                    // deletion
        assertNull(propose("Meet Shunade at noon.", "Greet Sinead at noon."))            // two words
        assertNull(propose("Meet Shunade at noon.", "Meet whatever at noon."))           // a different word, not a respelling
        assertNull(propose("", "Sinead"))
    }

    @Test fun theChangedWordMustBeOneParlaInserted() {
        assertNull(propose("Old Shunade text. Hello there", "Old Sinead text. Hello there", inserted = "Hello there"))
        assertNotNull(propose("Old text. Hello Shunade", "Old text. Hello Sinead", inserted = "Hello Shunade"))
    }

    @Test fun onlyPlainWordsOfUsefulLengthThatAreNotKnownAlready() {
        assertNull(propose("Call ab now", "Call ac now"))                                  // too short
        assertNull(propose("Say ${"a".repeat(25)} now", "Say ${"a".repeat(24)}b now"))     // too long
        assertNull(propose("Port 8080 open", "Port 8081 open"))                            // numbers
        assertNull(propose("Mail bob@x.io now", "Mail bob@y.io now"))                      // not word-like
        assertNull(propose("Meet Shunade at noon.", "Meet Sinead at noon.", dictionary = listOf("sinead")))
        assertNull(propose("Meet Shunade at noon.", "Meet Sinead at noon.", dictionary = listOf("SHUNADE")))
        assertEquals("O'Brien", propose("Ask O'Brian now", "Ask O'Brien now")?.to)
        assertEquals("José", propose("Ask Jose now", "Ask José now")?.to)
    }

    @Test fun bookDedupesKeepsOneNoFinalAndCapsPending() {
        val dir = Files.createTempDirectory("proposals").toFile()
        try {
            val file = DurableFile(File(dir, "p.json"))
            val book = ProposalBook(file)
            val p = CorrectionProposal("Shunade", "Sinead", 1)
            assertTrue(book.add(p))
            assertFalse(book.add(p.copy(from = "SHUNADE", to = "sinead")))
            book.resolve(p, dismiss = true)
            assertTrue(book.pending.value.isEmpty())
            assertFalse(book.add(p))
            // Persisted: a new reader sees the dismissal.
            assertFalse(ProposalBook(file).add(p))
            val added = CorrectionProposal("Cubernetes", "Kubernetes", 2)
            assertTrue(book.add(added)); book.resolve(added, dismiss = false); assertTrue(book.add(added))
            repeat(ProposalBook.CAP + 5) { assertTrue(book.add(CorrectionProposal("word$it", "werd$it", it.toLong()))) }
            assertEquals(ProposalBook.CAP, book.pending.value.size)
            assertEquals("werd${ProposalBook.CAP + 4}", book.pending.value.last().to)
            assertEquals(book.pending.value, ProposalBook(file).pending.value)
        } finally { dir.deleteRecursively() }
    }
}
