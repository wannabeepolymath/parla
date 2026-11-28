package dev.parla.android

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AccessibilityConsentTest {
    /** Schema-5 data as 1.3.1 wrote it: consent flag set, no version field. */
    private fun legacy(granted: Boolean = true) = JSONObject(LocalDataCodec.encode(LocalData(Settings(accessibilityConsentGranted = granted))))
        .also { it.getJSONObject("settings").remove("accessibilityConsentVersion") }.toString()

    @Test fun agreementToThe131DisclosureIsNotConsentToTheCurrentOne() {
        val upgraded = LocalDataCodec.decode(legacy()).settings
        assertTrue(upgraded.accessibilityConsentGranted)
        assertEquals(1, upgraded.accessibilityConsentVersion)
        assertFalse(upgraded.accessibilityConsentCurrent())
        assertFalse(Settings().accessibilityConsentCurrent())
    }

    @Test fun agreeingSavesTheCurrentVersionAndSurvivesReload() {
        val agreed = LocalDataCodec.decode(legacy()).settings.withAccessibilityConsent(true)
        assertEquals(CURRENT_A11Y_CONSENT, agreed.accessibilityConsentVersion)
        assertTrue(agreed.accessibilityConsentCurrent())
        assertTrue(LocalDataCodec.decode(LocalDataCodec.encode(LocalData(agreed))).settings.accessibilityConsentCurrent())
        // No thanks withdraws consent and never upgrades the agreed version.
        val declined = LocalDataCodec.decode(legacy()).settings.withAccessibilityConsent(false)
        assertFalse(declined.accessibilityConsentCurrent())
        assertEquals(1, declined.accessibilityConsentVersion)
        assertFalse(agreed.withAccessibilityConsent(false).accessibilityConsentCurrent())
    }

    @Test fun aLaterDisclosureVersionRepromptsAndUnknownVersionsStillLoad() {
        val agreed = Settings().withAccessibilityConsent(true)
        assertFalse(agreed.accessibilityConsentCurrent(CURRENT_A11Y_CONSENT + 1))
        val newer = JSONObject(LocalDataCodec.encode(LocalData(agreed))).also { it.getJSONObject("settings").put("accessibilityConsentVersion", CURRENT_A11Y_CONSENT + 1) }
        assertFalse(LocalDataCodec.decode(newer.toString()).settings.accessibilityConsentCurrent())
        for (bad in listOf<Any>(0, -1, "2", true)) {
            val json = JSONObject(LocalDataCodec.encode(LocalData(agreed))).also { it.getJSONObject("settings").put("accessibilityConsentVersion", bad) }
            assertTrue(bad.toString(), runCatching { LocalDataCodec.decode(json.toString()) }.isFailure)
        }
    }
}
