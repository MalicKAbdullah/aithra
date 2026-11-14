import 'package:flutter/material.dart';

import '../data/prompt_shortcut.dart';

/// A fixed request the user picks from a chip: the Ask sheet over selected
/// text, chips over a shared text, over an attached photo or document. The
/// model does all the understanding; a template only says what was asked.
class PromptTemplate {
  const PromptTemplate(this.id, this.label, this.icon, this._build);

  final String id;
  final String label;
  final IconData icon;
  final String Function(String text, String language) _build;

  /// The message for [text] (the selection, or empty when the subject is
  /// an attachment), with [language] for templates that translate.
  String prompt(String text, {String language = ''}) => _build(text, language);

  bool get translates => id == 'translate' || id == 'image.translate';
}

/// [text] set apart from the instruction, so an instruction-like selection
/// is read as material, not as a request.
String quoted(String text) => '"""\n${text.trim()}\n"""';

/// Tones the Rewrite chip offers.
const rewriteTones = [
  PromptTemplate(
    'rewrite.clearer',
    'Clearer',
    Icons.auto_fix_high_rounded,
    _clearer,
  ),
  PromptTemplate(
    'rewrite.shorter',
    'Shorter',
    Icons.short_text_rounded,
    _shorter,
  ),
  PromptTemplate(
    'rewrite.friendlier',
    'Friendlier',
    Icons.sentiment_satisfied_rounded,
    _friendlier,
  ),
  PromptTemplate(
    'rewrite.formal',
    'More formal',
    Icons.business_center_outlined,
    _formal,
  ),
];

String _rewrite(String text, String tone) =>
    'Rewrite this to be $tone. Keep its meaning and its language. '
    'Reply with only the rewritten text.\n\n${quoted(text)}';

String _clearer(String text, String _) =>
    _rewrite(text, 'clearer and easier to read');

String _shorter(String text, String _) => _rewrite(text, 'shorter');

String _friendlier(String text, String _) =>
    _rewrite(text, 'warmer and friendlier');

String _formal(String text, String _) => _rewrite(text, 'more formal');

/// The chips over selected or shared text. Rewrite opens [rewriteTones]
/// and Ask… a question field instead of sending at once.
const textTemplates = [
  PromptTemplate(
    'explain',
    'Explain',
    Icons.lightbulb_outline_rounded,
    _explain,
  ),
  PromptTemplate('summarise', 'Summarise', Icons.notes_rounded, _summarise),
  PromptTemplate('translate', 'Translate', Icons.translate_rounded, _translate),
  PromptTemplate('rewrite', 'Rewrite', Icons.edit_note_rounded, _none),
  PromptTemplate('reply', 'Reply', Icons.reply_rounded, _reply),
  PromptTemplate('ask', 'Ask…', Icons.chat_bubble_outline_rounded, _none),
];

String _explain(String text, String _) =>
    'Explain this in simple terms.\n\n${quoted(text)}';

String _summarise(String text, String _) =>
    'Summarise this.\n\n${quoted(text)}';

String _translate(String text, String language) =>
    'Translate this into $language. Reply with only the translation.'
    '\n\n${quoted(text)}';

String _reply(String text, String _) =>
    'Write a reply to this message. Reply with only the reply.'
    '\n\n${quoted(text)}';

String _none(String text, String _) => text;

/// A question the user typed about [text] (the Ask… chip).
String askAbout(String question, String text) =>
    '${question.trim()}\n\n${quoted(text)}';

/// The chips over an attached photo or screenshot.
const imageTemplates = [
  PromptTemplate(
    'image.describe',
    'Describe',
    Icons.image_search_rounded,
    _describe,
  ),
  PromptTemplate(
    'image.text',
    'Extract text',
    Icons.document_scanner_outlined,
    _extractText,
  ),
  PromptTemplate(
    'image.translate',
    'Translate',
    Icons.translate_rounded,
    _translateImage,
  ),
  PromptTemplate(
    'image.screen',
    'Explain this screen',
    Icons.smartphone_rounded,
    _explainScreen,
  ),
];

String _describe(String _, String _) => 'Describe this image.';

String _extractText(String _, String _) =>
    'Write out all the text in this image exactly as it appears, in '
    'reading order. Reply with only the text.';

String _translateImage(String _, String language) =>
    'Translate the text in this image into $language.';

String _explainScreen(String _, String _) =>
    'This is a screenshot. Explain what is on this screen and what I can '
    'do here.';

/// The chips over an attached document; Summarise runs the full-document
/// summary (DocSummarizer) rather than a reply.
const documentTemplates = [
  PromptTemplate(
    'doc.summarise',
    'Summarise',
    Icons.notes_rounded,
    _summariseDoc,
  ),
  PromptTemplate(
    'doc.points',
    'Key points',
    Icons.format_list_bulleted_rounded,
    _keyPoints,
  ),
  PromptTemplate(
    'doc.questions',
    'Questions to ask',
    Icons.help_outline_rounded,
    _questions,
  ),
];

String _summariseDoc(String name, String _) => 'Summarise $name.';

String _keyPoints(String name, String _) => 'List the key points of $name.';

String _questions(String name, String _) =>
    'What questions does $name leave open, or should I ask about it?';

/// The user's prompt shortcuts as chips after the built-in ones, each
/// applied to the text; one named like a built-in chip is left to it.
List<PromptTemplate> userTemplates(List<PromptShortcut> shortcuts) => [
  for (final s in shortcuts)
    if (!textTemplates.any((t) => t.label == s.label))
      PromptTemplate(
        'user.${s.label}',
        s.label,
        Icons.bolt_rounded,
        (text, _) => '${s.prompt.trimRight()}\n\n${quoted(text)}',
      ),
];
