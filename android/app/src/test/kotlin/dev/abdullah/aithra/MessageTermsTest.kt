package dev.abdullah.aithra

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MessageTermsTest {
    @Test
    fun indexesShortPrefixesOfEachWord() {
        assertEquals(
            setOf("fe", "fer", "ferr", "sa", "sai", "sail", "at", "ni", "nin", "nine"),
            MessageTerms.indexTerms("Ferry: sail at NINE, a"),
        )
    }

    @Test
    fun aQueryWordIsLookedUpByItsIndexedPrefix() {
        assertEquals("harb", MessageTerms.lookupTerm("harbour"))
        assertEquals("ha", MessageTerms.lookupTerm("ha"))
        // The lookup term of every query word is among the indexed terms of
        // a message where that word starts a word.
        val terms = MessageTerms.indexTerms("The harbour at dusk")
        for (q in MessageTerms.words("HARBOU du")) assertTrue(MessageTerms.lookupTerm(q) in terms)
    }

    @Test
    fun matchNeedsEveryQueryWordAsAWordPrefix() {
        val text = "When does the ferry sail? Ask the harbour master."
        assertEquals(14..18, MessageTerms.match(text, MessageTerms.words("FERRY har")))
        // "erry" is inside a word, not at its start.
        assertNull(MessageTerms.match(text, MessageTerms.words("erry")))
        assertNull(MessageTerms.match(text, MessageTerms.words("ferry train")))
        // Candidates sharing the indexed prefix but not the whole word.
        assertNull(MessageTerms.match("Ferret racing", MessageTerms.words("ferry")))
    }

    @Test
    fun matchesLettersBeyondAscii() {
        val text = "Café in Zürich, 東京 later"
        assertEquals(8..13, MessageTerms.match(text, MessageTerms.words("zür")))
        assertEquals(16..17, MessageTerms.match(text, MessageTerms.words("東京")))
    }

    @Test
    fun aQueryWithoutWordsMatchesNothing() {
        assertNull(MessageTerms.match("anything", MessageTerms.words("? !")))
    }
}
