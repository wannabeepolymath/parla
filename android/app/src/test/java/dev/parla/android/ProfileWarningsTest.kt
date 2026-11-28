package dev.parla.android

import org.junit.Assert.*
import org.junit.Test

class ProfileWarningsTest {
    private fun profile(name: String, target: String, enabled: Boolean = true, style: String = "") = AppProfile(name = name,target = target,enabled = enabled,style = style)

    @Test fun duplicateTargetsAreExplainedOncePerExtraProfileIncludingDisabledOnes() {
        assertTrue(profileWarnings(listOf(profile("Chat","com.whatsapp"),profile("Mail","com.google.android.gm"))).isEmpty())
        val warnings = profileWarnings(listOf(profile("Off","com.whatsapp",enabled = false),profile("A","com.whatsapp"),profile("B","com.whatsapp"),profile("Mail","com.google.android.gm")))
        assertEquals(listOf("Two profiles target com.whatsapp. The first enabled one is used.","Two profiles target com.whatsapp. The first enabled one is used."),warnings)
        // Package names are case-sensitive on Android, exactly as forApp matches them.
        assertTrue(profileWarnings(listOf(profile("A","com.Slack"),profile("B","com.slack"))).isEmpty())
    }

    @Test fun testerUsesTheSameFirstEnabledExactMatchAsDictation() {
        val data = LocalData(Settings(style = "standard"),profiles = listOf(profile("Off","com.whatsapp",enabled = false,style = "formal"),profile("Casual","com.whatsapp",style = "conversational"),profile("Later","com.whatsapp",style = "formal")))
        assertEquals("Casual",data.profileFor("com.whatsapp")?.name)
        assertEquals("conversational",data.forApp("com.whatsapp").settings.style)
        assertNull(data.profileFor("com.whatsap")); assertNull(data.profileFor(""))
        assertSame(data,data.forApp("com.other")) // global settings, unchanged
    }
}
