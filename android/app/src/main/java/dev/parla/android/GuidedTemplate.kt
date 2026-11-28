package dev.parla.android

import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener

/** Desktop GuidedTemplate.swift: same grammar, bounds and messages. Values are appended verbatim and never reparsed. */
internal class GuidedTemplateFailure(message: String) : IllegalArgumentException(message)

private fun utf8(text: String) = text.toByteArray(Charsets.UTF_8)

internal data class GuidedTemplateField(val id: UUID = UUID.randomUUID(), val key: String, val label: String, val required: Boolean = true)

internal data class GuidedTemplateDefinition(val id: UUID = UUID.randomUUID(), val revision: UUID = UUID.randomUUID(), val name: String, val body: String, val fields: List<GuidedTemplateField>) {
    fun compiled(): GuidedTemplateProgram {
        if(!text(name,120) || utf8(body).size > 8_192 || fields.size !in 1..12 || fields.map { it.id }.toSet().size != fields.size
            || fields.map { it.key }.toSet().size != fields.size || !fields.all { key(it.key) && text(it.label,160) })
            throw GuidedTemplateFailure("Check the template name and fields.")
        return GuidedTemplateProgram(body,fields)
    }
    companion object {
        fun text(text: String, limit: Int) = utf8(text).size <= limit && text.isNotBlank()
        fun key(key: String): Boolean {
            val b = utf8(key)
            return b.size in 1..32 && b[0] in 97..122 && b.drop(1).all { it in 97..122 || it in 48..57 || it.toInt() == 95 }
        }
    }
}

/** Compiles only the original UTF-8 body. `{{{{` and `}}}}` are literal `{{` and `}}`. */
internal class GuidedTemplateProgram(body: String, fields: List<GuidedTemplateField>) {
    sealed interface Segment { data class Literal(val text: String) : Segment; data class Field(val id: UUID) : Segment }
    val segments: List<Segment>
    init {
        val bytes = utf8(body); val keys = fields.associate { it.key to it.id }
        var index = 0; val literal = java.io.ByteArrayOutputStream(); val result = mutableListOf<Segment>(); val used = mutableSetOf<UUID>(); var occurrences = 0
        fun matches(text: String): Boolean { val t = utf8(text); return index+t.size <= bytes.size && t.indices.all { bytes[index+it] == t[it] } }
        fun flush() { if(literal.size() > 0) { result += Segment.Literal(literal.toByteArray().toString(Charsets.UTF_8)); literal.reset() } }
        while(index < bytes.size) {
            when {
                matches("{{{{") -> { literal.write(123); literal.write(123); index += 4 }
                matches("}}}}") -> { literal.write(125); literal.write(125); index += 4 }
                matches("{{") -> {
                    flush(); index += 2
                    val start = index
                    while(index < bytes.size && bytes[index].toInt() != 123 && bytes[index].toInt() != 125) index++
                    if(!matches("}}")) throw GuidedTemplateFailure("A {{ in the text isn't closed.")
                    val key = bytes.copyOfRange(start,index).toString(Charsets.UTF_8)
                    val id = keys[key]
                    if(!GuidedTemplateDefinition.key(key) || id == null) throw GuidedTemplateFailure("The text uses a key that isn't a field.")
                    if(index+2 != bytes.size && bytes[index+2].toInt() == 125) throw GuidedTemplateFailure("The text has an extra }.")
                    index += 2; occurrences++
                    if(occurrences > 64) throw GuidedTemplateFailure("Use 64 or fewer {{key}} placeholders.")
                    result += Segment.Field(id); used += id
                }
                matches("}}") -> throw GuidedTemplateFailure("A }} in the text has no matching {{.")
                else -> { literal.write(bytes[index].toInt()); index++ }
            }
        }
        flush()
        if(used != fields.map { it.id }.toSet()) throw GuidedTemplateFailure("Put every field's {{key}} in the text.")
        segments = result
    }
    fun render(values: Map<UUID,String>): String {
        val output = StringBuilder(); var count = 0
        for(segment in segments) {
            val text = when(segment) {
                is Segment.Literal -> segment.text
                is Segment.Field -> values[segment.id] ?: throw GuidedTemplateFailure("Accept or skip every field.")
            }
            val size = utf8(text).size
            if(size > 65_536-count) throw GuidedTemplateFailure("The finished form is too long.")
            count += size; output.append(text)
        }
        return output.toString().also { if(!GuidedTemplateDefinition.text(it,65_536)) throw GuidedTemplateFailure("Completed form is empty.") }
    }
}

/** Desktop `parla-guided-templates` version 1. Starts empty: no sample forms. */
internal data class GuidedTemplateDocument(val definitions: List<GuidedTemplateDefinition> = emptyList()) {
    fun validate() {
        if(definitions.size > 32 || definitions.map { it.id }.toSet().size != definitions.size) throw GuidedTemplateFailure("This template file can't be read.")
        definitions.forEach { it.compiled() }
        if(utf8(encode()).size > MAX_BYTES) throw GuidedTemplateFailure("Templates are too large to save.")
    }
    /** New revision on every save; a stale editor (changed or deleted since it opened) is refused. */
    fun saving(candidate: GuidedTemplateDefinition, expectedRevision: UUID?): GuidedTemplateDocument {
        candidate.compiled()
        val index = definitions.indexOfFirst { it.id == candidate.id }
        val saved = candidate.copy(revision = UUID.randomUUID())
        val next = if(index >= 0) {
            if(expectedRevision != definitions[index].revision) throw GuidedTemplateFailure("Template changed. Reopen the editor.")
            definitions.toMutableList().also { it[index] = saved }
        } else {
            if(expectedRevision != null) throw GuidedTemplateFailure("Template was deleted. Reopen the editor.")
            definitions+saved
        }
        return GuidedTemplateDocument(next).also { it.validate() }
    }
    fun deleting(id: UUID, expectedRevision: UUID): GuidedTemplateDocument {
        if(definitions.none { it.id == id && it.revision == expectedRevision }) throw GuidedTemplateFailure("Template changed or was deleted.")
        return GuidedTemplateDocument(definitions.filterNot { it.id == id }).also { it.validate() }
    }
    fun encode(): String = JSONObject().put("format",FORMAT).put("schemaVersion",1).put("definitions",JSONArray(definitions.map { d ->
        JSONObject().put("id",d.id.toString()).put("revision",d.revision.toString()).put("name",d.name).put("body",d.body)
            .put("fields",JSONArray(d.fields.map { JSONObject().put("id",it.id.toString()).put("key",it.key).put("label",it.label).put("required",it.required) }))
    })).toString()
    companion object {
        const val FORMAT = "parla-guided-templates"
        const val MAX_BYTES = 262_144
        /** Strict: wrong format, version, types or any invalid definition rejects the whole document. */
        fun decode(json: String): GuidedTemplateDocument {
            val parser = JSONTokener(json)
            val root = parser.nextValue() as? JSONObject ?: throw GuidedTemplateFailure("This template file can't be read.")
            fun <T> get(o: JSONObject, key: String, type: Class<T>): T = o.opt(key).let { if(type.isInstance(it)) type.cast(it) else throw GuidedTemplateFailure("This template file can't be read.") }
            fun uuid(o: JSONObject, key: String) = runCatching { UUID.fromString(get(o,key,String::class.java)) }.getOrElse { throw GuidedTemplateFailure("This template file can't be read.") }
            if(parser.nextClean() != '\u0000' || get(root,"format",String::class.java) != FORMAT || get(root,"schemaVersion",Int::class.javaObjectType) != 1)
                throw GuidedTemplateFailure("This template file can't be read.")
            val rows = get(root,"definitions",JSONArray::class.java)
            return GuidedTemplateDocument((0 until rows.length()).map { i ->
                val d = rows.opt(i) as? JSONObject ?: throw GuidedTemplateFailure("This template file can't be read.")
                val fields = get(d,"fields",JSONArray::class.java)
                GuidedTemplateDefinition(uuid(d,"id"),uuid(d,"revision"),get(d,"name",String::class.java),get(d,"body",String::class.java),(0 until fields.length()).map { j ->
                    val f = fields.opt(j) as? JSONObject ?: throw GuidedTemplateFailure("This template file can't be read.")
                    GuidedTemplateField(uuid(f,"id"),get(f,"key",String::class.java),get(f,"label",String::class.java),get(f,"required",Boolean::class.javaObjectType))
                })
            }).also { it.validate() }
        }
    }
}

/** Private `guided-templates.json`, separate from settings. An unreadable file is kept unchanged and blocks writes. */
internal class GuidedTemplateFile(private val file: DurableFile) {
    fun load(): GuidedTemplateDocument {
        val bytes = file.read(GuidedTemplateDocument.MAX_BYTES+1) ?: return GuidedTemplateDocument()
        if(bytes.size > GuidedTemplateDocument.MAX_BYTES) throw GuidedTemplateFailure("This template file can't be read.")
        return GuidedTemplateDocument.decode(bytes.toString(Charsets.UTF_8))
    }
    /** Re-reads before writing, so a mutation always applies to the saved document. */
    @Synchronized fun mutate(change: (GuidedTemplateDocument) -> GuidedTemplateDocument): GuidedTemplateDocument =
        change(load()).also { file.write(utf8(it.encode())) }
}

/** Desktop GuidedTemplateSession: RAM-only reducer. The screen's owner alone records and recognizes. */
internal data class GuidedTemplateSession(
    val definition: GuidedTemplateDefinition, val program: GuidedTemplateProgram, val began: Long,
    val id: UUID = UUID.randomUUID(), val index: Int = 0, val starts: Int = 0, val fieldRevision: UUID = UUID.randomUUID(),
    val accepted: Map<UUID,Disposition> = emptyMap(), val take: Take? = null, val candidate: String? = null,
    val preview: Preview? = null, val completion: Completion? = null, val saved: Boolean = false,
) {
    sealed interface Disposition { data class Accepted(val text: String) : Disposition; data object Skipped : Disposition }
    data class Take(val session: UUID, val template: UUID, val revision: UUID, val field: UUID, val fieldRevision: UUID, val attempt: UUID = UUID.randomUUID())
    data class Preview(val id: UUID, val body: String)
    data class Completion(val id: UUID, val date: Long, val body: String)
    val field get() = definition.fields[index]
    val allAnswered get() = accepted.size == definition.fields.size
    fun isExpired(now: Long) = now < began || now-began >= LIFETIME_MS
    fun start(now: Long): Pair<GuidedTemplateSession,Take> {
        if(take != null || completion != null || isExpired(now) || starts >= 60) throw GuidedTemplateFailure("Can't record right now. Start a new form.")
        val value = Take(id,definition.id,definition.revision,field.id,fieldRevision)
        return copy(preview = null,candidate = null,starts = starts+1,take = value) to value
    }
    /** A stale take is ignored. Blank or oversized recognition leaves no candidate. */
    fun settle(value: Take, text: String?) = if(take != value) this
        else copy(take = null,candidate = text?.takeIf { GuidedTemplateDefinition.text(it,8_192) })
    fun editCandidate(text: String): GuidedTemplateSession {
        if(take != null || completion != null || candidate == null || utf8(text).size > 8_192) throw GuidedTemplateFailure("This text is too long.")
        return copy(candidate = text)
    }
    fun accept(): GuidedTemplateSession {
        val value = candidate
        if(take != null || completion != null || value == null || !GuidedTemplateDefinition.text(value,8_192)) throw GuidedTemplateFailure("Record or type something first.")
        val next = accepted+(field.id to Disposition.Accepted(value))
        if(next.values.sumOf { if(it is Disposition.Accepted) utf8(it.text).size else 0 } > 98_304) throw GuidedTemplateFailure("The fields are too long.")
        return copy(accepted = next).advanced()
    }
    fun skip(): GuidedTemplateSession {
        if(take != null || completion != null || field.required) throw GuidedTemplateFailure("Required fields cannot be skipped.")
        return copy(accepted = accepted+(field.id to Disposition.Skipped)).advanced()
    }
    private fun advanced() = copy(candidate = null,preview = null,fieldRevision = UUID.randomUUID(),index = if(index+1 < definition.fields.size) index+1 else index)
    fun back() = if(take != null || completion != null) this else copy(index = maxOf(0,index-1),candidate = null,preview = null,fieldRevision = UUID.randomUUID())
    fun discardCandidate() = if(take != null || completion != null) this else copy(candidate = null,preview = null)
    fun review(): GuidedTemplateSession {
        if(take != null || completion != null || !allAnswered) throw GuidedTemplateFailure("Accept or skip every field first.")
        return copy(preview = Preview(UUID.randomUUID(),program.render(accepted.mapValues { (_,v) -> if(v is Disposition.Accepted) v.text else "" })))
    }
    fun approve(review: UUID, date: Long): GuidedTemplateSession {
        val p = preview
        return if(take != null || completion != null || p == null || p.id != review) this else copy(completion = Completion(UUID.randomUUID(),date,p.body))
    }
    fun markSaved(result: UUID) = if(completion?.id == result) copy(saved = true) else this
    companion object {
        const val LIFETIME_MS = 1_200_000L
        fun begin(definition: GuidedTemplateDefinition, now: Long) = GuidedTemplateSession(definition,definition.compiled(),now)
    }
}
