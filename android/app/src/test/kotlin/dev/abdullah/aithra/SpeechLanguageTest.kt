package dev.abdullah.aithra

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Locale

class SpeechLanguageTest {
    private fun pick(
        wanted: String,
        installed: List<String> = emptyList(),
        pending: List<String> = emptyList(),
        supported: List<String> = emptyList(),
    ) = pickLanguage(Locale.forLanguageTag(wanted), installed, pending, supported)

    @Test
    fun regionalPreferenceExtensionsAreIgnored() {
        assertEquals(
            "en-US" to ModelState.INSTALLED,
            pick("en-US-u-fw-mon-mu-celsius", installed = listOf("en-US"), supported = listOf("en-US", "de-DE")),
        )
    }

    @Test
    fun aRegionTheRecognizerLacksUsesTheInstalledRegion() {
        assertEquals(
            "en-US" to ModelState.INSTALLED,
            pick("en-JP", installed = listOf("en-US"), supported = listOf("en-US", "en-GB", "ja-JP")),
        )
    }

    @Test
    fun theRecognizersSpellingIsKept() {
        assertEquals("en-us" to ModelState.INSTALLED, pick("en-US", installed = listOf("en-us")))
    }

    @Test
    fun anotherRegionOfAnInstalledLanguageBeatsDownloadingTheExactOne() {
        assertEquals(
            "en-US" to ModelState.INSTALLED,
            pick("en-PK-u-mu-celsius", installed = listOf("en-US"), supported = listOf("en-GB", "en-PK", "en-US")),
        )
    }

    @Test
    fun aScheduledDownloadIsPending() {
        assertEquals(
            "fr-FR" to ModelState.PENDING,
            pick("fr-FR", installed = listOf("en-US"), pending = listOf("fr-FR"), supported = listOf("fr-FR")),
        )
    }

    @Test
    fun aDownloadableLanguageIsMissing() {
        assertEquals(
            "de-DE" to ModelState.MISSING,
            pick("de-AT-u-fw-mon", installed = listOf("en-US"), supported = listOf("de-DE", "en-US")),
        )
    }

    @Test
    fun aLanguageTheRecognizerLacksIsUnsupported() {
        assertEquals(
            "ur-PK" to ModelState.UNSUPPORTED,
            pick("ur-PK-u-nu-arabext", installed = listOf("en-US"), supported = listOf("en-US")),
        )
    }
}
