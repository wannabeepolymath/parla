package dev.parla.android

import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Test

class ScratchpadTest {
    @Test fun aPendingDebouncedWriteCannotOverwriteTheFinalSave() {
        val dir = Files.createTempDirectory("parla-scratchpad").toFile()
        try {
            val pad = ScratchpadFile(DurableFile(dir.resolve("scratchpad.txt")))
            val debounced = pad.ticket() // text read by the 500 ms debounce
            val final = pad.ticket()     // text read later by stop/dispose
            pad.save("final text", final)
            pad.save("older text", debounced) // the IO write lands late
            assertEquals("final text", pad.load())
            pad.save("next edit", pad.ticket())
            assertEquals("next edit", pad.load())
        } finally { dir.deleteRecursively() }
    }
}
