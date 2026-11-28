package dev.parla.android

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test

class DiagnosticsTest {
    @Test fun timingRecordHasAFixedContentFreeFormat() {
        assertEquals("1970-01-01T00:00:01.250Z #3 cleanup_end +1520ms dur=812ms fallback provider=openai_compatible",
            TimingEvent(1250, 3, TimingStage.cleanup_end, 1520, 812, TimingOutcome.fallback, ProviderCategory.openai_compatible).format())
        assertEquals("1970-01-01T00:00:00Z #1 record_start +0ms ok", TimingEvent(0, 1, TimingStage.record_start, 0).format())
        assertEquals(ProviderCategory.other, ProviderCategory.of("https://example.com/my-secret"))
    }

    @Test fun spanRecordsDurationsAndFailureOutcomes() {
        val events = mutableListOf<TimingEvent>()
        var now = 100L
        val timing = TimingSession(sink = { events += it }, clock = { now }, wall = { 0 })
        timing.span(TimingStage.record_start, TimingStage.record_stop) { now += 40 }
        runCatching { timing.span(null, TimingStage.insertion) { now += 5; throw MicrophoneSilencedException() } }
        runCatching { timing.span(null, TimingStage.insertion) { throw IllegalStateException("dictated words") } }
        assertEquals(listOf("+0ms ok", "+40ms dur=40ms ok", "+45ms dur=5ms mic_silenced", "+45ms dur=0ms failed"),
            events.map { it.format().substringAfter("_start ").substringAfter("_stop ").substringAfter("insertion ") })
        assertFalse(events.any { it.format().contains("dictated") })
    }

    @Test fun dictationTimingsNeverContainTextOrKeys() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            server.enqueue(MockResponse().setResponseCode(500).setBody("echo: tell Sam the vault code"))
            val events = mutableListOf<TimingEvent>()
            val data = LocalData(Settings(provider = "custom", providers = mapOf("custom" to ProviderConfig(server.url("/v1").toString(), "m"))))
            DictationFlow(Pipeline(ApiClient(OkHttpClient()))).run(PendingOperation(), data, AppCategory.chat, false, 0,
                transcribe = { "tell Sam the vault code" }, key = { "sk-test-secret" }, save = { _, _ -> true },
                deliver = { _, authorize -> authorize(); DictationFlow.INSERTED }, stage = { _, _ -> },
                timing = TimingSession(sink = { events += it }))
            assertEquals(listOf(TimingStage.transcription_start, TimingStage.transcription_end, TimingStage.cleanup_start,
                TimingStage.cleanup_end, TimingStage.insertion), events.map { it.stage })
            val cleanup = events.single { it.stage == TimingStage.cleanup_end }
            assertEquals(TimingOutcome.fallback, cleanup.outcome)
            assertEquals(ProviderCategory.custom, cleanup.provider)
            assertEquals(TimingOutcome.ok, events.last().outcome)
            val log = Diagnostics.export(events)
            for (secret in listOf("Sam", "vault", "sk-test", "secret", "127.0.0.1", "localhost", "chat")) assertFalse(secret, log.contains(secret))
            RecoveryVault.clear()
        }
    }

    @Test fun localOnlyCleanupIsMarkedLocal() = runBlocking {
        val events = mutableListOf<TimingEvent>()
        DictationFlow().run(PendingOperation(), LocalData(Settings(outputMode = "raw")), AppCategory.unknown, false, 0,
            transcribe = { "words" }, key = { error("raw mode needs no key") }, save = { _, _ -> true },
            deliver = { _, _ -> "The text field changed." }, stage = { _, _ -> }, timing = TimingSession(sink = { events += it }))
        assertEquals(ProviderCategory.local, events.single { it.stage == TimingStage.cleanup_end }.provider)
        assertEquals(TimingOutcome.unconfirmed, events.last().outcome)
        RecoveryVault.clear()
    }
}
