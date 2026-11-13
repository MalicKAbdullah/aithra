package dev.abdullah.aithra

import java.util.Locale

/** Where the on-device model for a language stands, as Dart reads it. */
enum class ModelState(val wire: String) {
    INSTALLED("installed"),

    /** The recognizer has a download for it scheduled or running. */
    PENDING("pending"),

    /** Downloadable, not downloaded. */
    MISSING("missing"),

    /** The recognizer has no model for the language at all. */
    UNSUPPORTED("unsupported"),
}

/**
 * The tag to recognize [wanted] in and where its on-device model stands:
 * a tag exactly as the recognizer listed it, the phone's own tag when
 * listed, else another region of the same language (en-US for en-PK),
 * installed models first, then pending downloads, then downloadable ones.
 * Unicode extensions (`-u-…`) are ignored. [ModelState.UNSUPPORTED] keeps the phone's
 * tag.
 */
fun pickLanguage(
    wanted: Locale,
    installed: List<String>,
    pending: List<String>,
    supported: List<String>,
): Pair<String, ModelState> {
    val plain = wanted.stripExtensions()
    val tag = plain.toLanguageTag()
    fun sameLanguage(t: String) = Locale.forLanguageTag(t).language == plain.language
    for ((tags, state) in listOf(
        installed to ModelState.INSTALLED,
        pending to ModelState.PENDING,
        supported to ModelState.MISSING,
    )) {
        tags.firstOrNull { it.equals(tag, ignoreCase = true) }?.let { return it to state }
        tags.firstOrNull(::sameLanguage)?.let { return it to state }
    }
    return tag to ModelState.UNSUPPORTED
}
