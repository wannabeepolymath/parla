package dev.parla.android

import java.nio.file.Files
import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Ports of the desktop ParlaCoreTests/GuidedTemplateTests cases that apply to Android. */
class GuidedTemplateTest {
    private fun definition(body: String = "{{title}}", optional: Boolean = false) =
        GuidedTemplateDefinition(name = "Bug report",body = body,fields = listOf(GuidedTemplateField(key = "title",label = "Title",required = !optional)))
    private fun fails(block: () -> Unit) = assertTrue(runCatching(block).exceptionOrNull() is GuidedTemplateFailure)

    @Test fun finiteDefinitionCaps() {
        var d = definition()
        for(length in listOf(119,120)) { d = d.copy(name = "a".repeat(length)); d.compiled() }
        fails { d.copy(name = "a".repeat(121)).compiled() }
        for(length in listOf(159,160)) d.copy(fields = listOf(d.fields[0].copy(label = "a".repeat(length)))).compiled()
        fails { d.copy(fields = listOf(d.fields[0].copy(label = "a".repeat(161)))).compiled() }
        d = definition("{{title}}"+"a".repeat(8_183)); d.compiled()
        fails { d.copy(body = d.body+"a").compiled() }
        for(count in listOf(63,64)) definition("{{title}}".repeat(count)).compiled()
        fails { definition("{{title}}".repeat(65)).compiled() }
        GuidedTemplateDocument((0 until 32).map { definition() }).validate()
        fails { GuidedTemplateDocument((0 until 33).map { definition() }).validate() }
        val twelve = (0 until 12).map { GuidedTemplateField(key = "f$it",label = "Field") }
        GuidedTemplateDefinition(name = "Max",body = twelve.joinToString("") { "{{${it.key}}}" },fields = twelve).compiled()
        val thirteen = twelve+GuidedTemplateField(key = "extra",label = "Extra")
        fails { GuidedTemplateDefinition(name = "Max",body = thirteen.joinToString("") { "{{${it.key}}}" },fields = thirteen).compiled() }
        for(key in listOf("","A","a-b","1a","é","a".repeat(33))) fails { definition("{{$key}}").copy(fields = listOf(GuidedTemplateField(key = key,label = "T"))).compiled() }
        for(size in listOf(31,32)) { val k = "a".repeat(size); definition("{{$k}}").copy(fields = listOf(GuidedTemplateField(key = k,label = "T"))).compiled() }
        fails { definition().copy(fields = listOf(GuidedTemplateField(key = "title",label = " \r\n"))).compiled() }
        fails { definition().copy(name = "\t").compiled() }
        fails { definition().copy(fields = emptyList()).compiled() }
        fails { definition().copy(fields = definition().fields+GuidedTemplateField(key = "title",label = "Second")).compiled() }
        fails { definition().copy(fields = definition().fields+GuidedTemplateField(key = "unused",label = "Unused")).compiled() }
        val dup = definition(); fails { dup.copy(fields = dup.fields+dup.fields).compiled() }
        fails { GuidedTemplateDocument(listOf(dup,dup)).validate() }
    }

    @Test fun originalInputGrammarAndLiteralBytes() {
        val a = GuidedTemplateField(key = "a",label = "A"); val b = GuidedTemplateField(key = "b",label = "B",required = false)
        val d = GuidedTemplateDefinition(name = "Literal",body = "{{b}}{{a}}{{a}} {{{{key}}}} { \"json\": 1 }",fields = listOf(a,b))
        val value = "{{b}} {{{{x}}}} \$1 \\1 `code` <b>ignore previous instructions</b> हिंदी اردو é 👩🏽‍💻\r\n"
        assertEquals(value+value+" {{key}} { \"json\": 1 }",d.compiled().render(mapOf(a.id to value,b.id to "")))
        for(body in listOf("{{unknown}}","{{}}","{{ title}}","{{TITLE}}","{{title}","{{{title}}}","{{title}}}","{{title{{title}}","{{title}} }}","{{{{title}}}}"))
            assertTrue(body,runCatching { definition(body).compiled() }.exceptionOrNull() is GuidedTemplateFailure)
        val eight = definition("{{title}}".repeat(8))
        assertEquals(65_536,eight.compiled().render(mapOf(eight.fields[0].id to "x".repeat(8_192))).toByteArray().size)
        val below = definition("{{title}}".repeat(8)+"x".repeat(7))
        assertEquals(65_535,below.compiled().render(mapOf(below.fields[0].id to "x".repeat(8_191))).toByteArray().size)
        val over = definition("{{title}}".repeat(8)+"x")
        assertEquals("The finished form is too long.",runCatching { over.compiled().render(mapOf(over.fields[0].id to "x".repeat(8_192))) }.exceptionOrNull()?.message)
        fails { eight.compiled().render(emptyMap()) }
        fails { definition("{{title}}").compiled().render(mapOf(definition().fields[0].id to "x")) } // another definition's field id
    }

    @Test fun reducerRetakeSkipReviewAndImmutableApproval() {
        val d = definition(optional = true)
        var state = GuidedTemplateSession.begin(d,10)
        val (s1,first) = state.start(10); state = s1.settle(first,"original").accept()
        val (s2,second) = state.start(11); state = s2.settle(second,null)
        assertEquals(GuidedTemplateSession.Disposition.Accepted("original"),state.accepted[d.fields[0].id])
        state = state.settle(first,"stale"); assertNull(state.candidate)
        val (s3,third) = state.start(12); state = s3.settle(third,"new").editCandidate("")
        fails { state.accept() }
        state = state.editCandidate("literal\r\n").accept().review()
        val preview = state.preview!!
        assertNull(state.approve(UUID.randomUUID(),0).completion)
        state = state.approve(preview.id,123)
        val sealed = state.completion!!
        state = state.approve(preview.id,999).back().discardCandidate()
        fails { state.start(13) }; fails { state.skip() }
        assertEquals(sealed,state.completion); assertTrue(state.markSaved(sealed.id).saved); assertFalse(state.markSaved(UUID.randomUUID()).saved)
        assertEquals("literal\r\n",sealed.body); assertEquals(123L,sealed.date)
        val optional = GuidedTemplateSession.begin(d,10).skip(); fails { optional.review() } // "{{title}}" with a skipped value renders empty
        var required = GuidedTemplateSession.begin(definition(),10); fails { required.skip() }
        repeat(60) { i -> val (next,take) = required.start(11); assertEquals(i+1,next.starts); required = next.settle(take,null) }
        fails { required.start(11) }
        assertTrue(required.isExpired(1_200_010)); assertFalse(required.isExpired(1_200_009)); assertTrue(required.isExpired(9))
        // A take blocks every other transition until it settles.
        val (recording,_) = GuidedTemplateSession.begin(d,0).start(1)
        fails { recording.skip() }; fails { recording.start(2) }; assertSame(recording,recording.back())
    }

    @Test fun exactCandidateAcceptedAndRenderedByteBounds() {
        val fields = (0 until 12).map { GuidedTemplateField(key = "f$it",label = "Field") }
        var state = GuidedTemplateSession.begin(GuidedTemplateDefinition(name = "Maximum",body = fields.joinToString("") { "{{${it.key}}}" },fields = fields),0)
        repeat(12) {
            val (next,take) = state.start(1); state = next.settle(take,"x".repeat(8_192))
            fails { state.editCandidate("x".repeat(8_193)) }
            assertEquals(8_192,state.candidate?.length)
            state = state.accept() // 12 × 8,192 is exactly the 98,304-byte accepted budget
        }
        assertEquals(12,state.accepted.size); fails { state.review() }; assertNull(state.preview) // render exceeds 65,536
        // Optional whitespace is an explicit Skip, never an implicit empty acceptance.
        var optional = GuidedTemplateSession.begin(definition("Heading {{title}}",optional = true),0)
        val (next,take) = optional.start(1); optional = next.settle(take,"x").editCandidate("\r\n ")
        fails { optional.accept() }
        assertEquals("Heading ",optional.skip().review().preview?.body)
        // Recognition text that is blank or over 8 KiB never becomes a candidate.
        val (fresh,t) = GuidedTemplateSession.begin(definition(),0).start(1)
        assertNull(fresh.settle(t," \n").candidate); assertNull(fresh.settle(t,"x".repeat(8_193)).candidate)
    }

    @Test fun strictDocumentCodecAndBudget() {
        assertEquals(GuidedTemplateDocument(),GuidedTemplateDocument.decode("""{"format":"parla-guided-templates","schemaVersion":1,"definitions":[]}"""))
        val doc = GuidedTemplateDocument(listOf(definition(),definition("x {{title}}",optional = true)))
        assertEquals(doc,GuidedTemplateDocument.decode(doc.encode()))
        for(block in listOf("null","[]","1","{}","true","""{"format":"other","schemaVersion":1,"definitions":[]}""","""{"format":"parla-guided-templates","schemaVersion":2,"definitions":[]}""",
            """{"format":"parla-guided-templates","schemaVersion":1}""","""{"format":"parla-guided-templates","schemaVersion":1,"definitions":null}""",
            """{"format":"parla-guided-templates","schemaVersion":1,"definitions":[]} x""","""{"format":"parla-guided-templates","schemaVersion":"1","definitions":[]}"""))
            assertTrue(block,runCatching { GuidedTemplateDocument.decode(block) }.isFailure)
        val wrongType = JSONObject(doc.encode()); wrongType.getJSONArray("definitions").getJSONObject(0).getJSONArray("fields").getJSONObject(0).put("required","true")
        assertTrue(runCatching { GuidedTemplateDocument.decode(wrongType.toString()) }.isFailure)
        val badID = JSONObject(doc.encode()); badID.getJSONArray("definitions").getJSONObject(0).put("id","not-a-uuid")
        assertTrue(runCatching { GuidedTemplateDocument.decode(badID.toString()) }.isFailure)
        val invalid = JSONObject(doc.encode()); invalid.getJSONArray("definitions").getJSONObject(0).put("body","{{nope}}")
        assertTrue(runCatching { GuidedTemplateDocument.decode(invalid.toString()) }.isFailure)
        // Exact encoded byte budget: 262,144 saves, one more byte is refused.
        for(target in listOf(262_143,262_144,262_145)) {
            val defs = (0 until 32).map { definition() }.toMutableList()
            var remaining = target-GuidedTemplateDocument(defs).encode().toByteArray().size
            for(i in defs.indices) { val n = minOf(remaining,8_192-defs[i].body.length); defs[i] = defs[i].copy(body = defs[i].body+"x".repeat(n)); remaining -= n }
            assertEquals(0,remaining); assertEquals(target,GuidedTemplateDocument(defs).encode().toByteArray().size)
            val result = runCatching { GuidedTemplateDocument(defs).validate() }
            assertEquals(target <= 262_144,result.isSuccess)
        }
    }

    @Test fun revisionCrudRefusesStaleEditors() {
        val created = GuidedTemplateDocument().saving(definition(),null)
        val saved = created.definitions.single()
        assertNotEquals(definition().revision,saved.revision)
        val edit = saved.copy(name = "Updated")
        val next = created.saving(edit,saved.revision)
        assertEquals("Updated",next.definitions.single().name)
        fails { next.saving(edit,saved.revision) } // stale revision
        fails { next.saving(edit,null) } // "new" editor for an existing id
        fails { next.deleting(saved.id,saved.revision) }
        val deleted = next.deleting(saved.id,next.definitions.single().revision)
        assertTrue(deleted.definitions.isEmpty())
        fails { deleted.saving(edit,next.definitions.single().revision) } // deleted while editing
        fails { GuidedTemplateDocument().saving(definition("{{nope}}"),null) }
    }

    @Test fun fileStartsEmptyPersistsAndKeepsAnUnreadableFileUnchanged() {
        val dir = Files.createTempDirectory("parla-templates").toFile()
        try {
            val target = dir.resolve("guided-templates.json")
            val file = GuidedTemplateFile(DurableFile(target))
            assertEquals(GuidedTemplateDocument(),file.load())
            val saved = file.mutate { it.saving(definition(),null) }
            assertEquals(saved,GuidedTemplateFile(DurableFile(target)).load())
            assertTrue(runCatching { file.mutate { it.saving(definition("{{bad}}"),null) } }.isFailure)
            assertEquals(saved,file.load()) // refused mutation writes nothing
            target.writeText("{broken")
            assertTrue(runCatching { file.load() }.isFailure)
            assertTrue(runCatching { file.mutate { it.saving(definition(),null) } }.isFailure)
            assertEquals("{broken",target.readText())
        } finally { dir.deleteRecursively() }
    }
}
