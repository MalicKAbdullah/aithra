package dev.abdullah.aithra

/**
 * The words of message text for the blind search index (see ChatDb).
 *
 * Each word is indexed by its prefixes of 2 to [PREFIX] characters, each
 * stored only as a keyed hash. A query word is looked up by its first
 * [PREFIX] characters, which finds every message with a word starting that
 * way; the few candidates are then decrypted and [match] decides, so the
 * index stays small and short while results are exact.
 */
object MessageTerms {
    /** Longest indexed prefix: long enough to be selective, short enough to leak little. */
    const val PREFIX = 4

    private val word = Regex("[\\p{L}\\p{N}]+")

    /** Distinct words of at least two characters, lower-cased. */
    fun words(text: String): List<String> =
        word.findAll(text).map { it.value.lowercase() }.filter { it.length >= 2 }.distinct().toList()

    /** Every indexed prefix of [text]'s words. */
    fun indexTerms(text: String): Set<String> =
        words(text).flatMapTo(HashSet()) { w -> (2..minOf(w.length, PREFIX)).map { w.substring(0, it) } }

    /** The index term a query word is looked up by. */
    fun lookupTerm(queryWord: String) = if (queryWord.length > PREFIX) queryWord.substring(0, PREFIX) else queryWord

    /**
     * Where [text] matches [queryWords] (each a prefix of some word in it,
     * ignoring case): the range of the earliest matching word, or null when
     * any query word has no match.
     */
    fun match(text: String, queryWords: List<String>): IntRange? {
        if (queryWords.isEmpty()) return null
        val found = word.findAll(text).toList()
        var first: IntRange? = null
        for (q in queryWords) {
            val hit = found.firstOrNull { it.value.lowercase().startsWith(q) } ?: return null
            if (first == null || hit.range.first < first.first) first = hit.range
        }
        return first
    }
}
