package dev.parla.android

import org.junit.Assert.*
import org.junit.Test

class ScratchpadSpellingTest {
    private fun token(text: String, start: Int, end: Int = start) = runCatching { ScratchpadSpelling.token(text,start,end).text }.getOrNull()

    @Test fun caretOrExactSelectionNamesOneWholeWord() {
        val text = "I met jon today"
        assertEquals("jon",token(text,7)); assertEquals("jon",token(text,9)) // inside, and right after the word
        assertNull(token(text,6)) // before the word: the caret belongs to the space
        assertEquals("jon",token(text,6,9)); assertNull(token(text,6,8)); assertNull(token(text,5,9))
        assertNull(token("I met jo today",8)) // fewer than 3 characters
        assertNull(token("",0)); assertNull(token(text,0))
        assertEquals("jon",token("jon.",3)); assertEquals("jon",token("jon, hi",2)); assertEquals("jon",token("(jon)",2))
        assertEquals("café",token("a café here",4)) // combining mark stays inside its grapheme
        assertEquals("snake_case",token("x snake_case y",4))
    }

    @Test fun ambiguousCompoundsPoisonNeighborsAndBadTextAreRefused() {
        for(text in listOf("foo.bar","foo-bar","jon's","jon@mail","jon/a","jon:x","foo..bar","jon-"))
            assertNull(text,token(text,2))
        assertNull(token("a/jon",4)); assertNull(token("x.jon",4)); assertEquals("jon",token("x jon",4))
        assertEquals("foo",token("foo...",2)) // trailing periods only delimit
        assertNull(token("jon​",2)) // zero-width space neighbor
        assertNull(token("jo­n",1)) // soft hyphen inside the word
        assertNull(token("jon \uD800",1)) // lone surrogate anywhere in the document
        assertNull(token("a".repeat(129)+" x",3)) // longer than 128 units
        assertEquals("Tap into a word in the scratchpad first.",
            runCatching { ScratchpadSpelling.begin("jon "+"x".repeat(65_533),2,2,LocalData(dictionary = listOf("Jon")),0) }.exceptionOrNull()?.message)
    }

    @Test fun candidatesAreExactDictionarySpellingsInOrderWithoutTheOriginal() {
        val words = listOf("JON","jon","Jon","Jonathan","jön","J0N","Jo")
        assertEquals(ScratchpadSpelling.Choices(listOf("JON","Jon"),false),ScratchpadSpelling.candidates("jon",words))
        // Canonically equal spellings are offered once; the precomposed form came first.
        assertEquals(listOf("Caf\u00E9"),ScratchpadSpelling.candidates("cafe\u0301",listOf("Caf\u00E9","Cafe\u0301")).outputs)
        val many = listOf("JOn","JoN","jON","JOn ","Jon","JON","jOn","joN")
        val choices = ScratchpadSpelling.candidates("jon",many)
        assertEquals(listOf("JOn","JoN","jON","Jon","JON"),choices.outputs); assertTrue(choices.more)
        assertTrue(runCatching { ScratchpadSpelling.candidates("jon",List(10_001) { "x" }) }.isFailure)
        assertEquals("No dictionary spelling matches this word.",
            runCatching { ScratchpadSpelling.begin("hi jon",4,4,LocalData(dictionary = listOf("jon","Ada")),0) }.exceptionOrNull()?.message)
    }

    @Test fun aChoiceAppliesOnlyToTheSameTextSelectionAndDictionaryWithinThirtySeconds() {
        val data = LocalData(dictionary = listOf("Jon"))
        val text = "met jon today"
        val request = ScratchpadSpelling.begin(text,6,6,data,1_000)
        fun choose(candidate: String = "Jon", t: String = text, start: Int = 6, end: Int = 6, enabled: Boolean = true, d: LocalData = data, now: Long = 2_000) =
            ScratchpadSpelling.choose(request,candidate,t,start,end,enabled,d,now)
        assertEquals(ScratchpadSpelling.Edit(4,7,"Jon","met Jon today",7,7),choose())
        assertNull(choose(t = "met jon today!")); assertNull(choose(start = 5,end = 5)); assertNull(choose(enabled = false))
        assertNull(choose(d = data.copy(dictionary = listOf("Jon","Ada")))); assertNull(choose(d = data.copy(snippets = listOf(Snippet(trigger = "a",expansion = "b")))))
        assertNull(choose(now = 31_000)); assertNull(choose(now = 999)); assertNotNull(choose(now = 30_999))
        assertNull(choose(candidate = "JON")) // not offered
        // A selected word stays selected after the replacement.
        val selected = ScratchpadSpelling.begin(text,4,7,data,0)
        assertEquals(ScratchpadSpelling.Edit(4,7,"Jon","met Jon today",4,7),ScratchpadSpelling.choose(selected,"Jon",text,7,4,true,data,1))
    }
}
