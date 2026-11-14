/// A prompt the user starts often, offered as a chip on a new chat and in
/// the Ask Aithra sheet. Tapping it puts [prompt] in the composer.
class PromptShortcut {
  const PromptShortcut(this.label, this.prompt);

  factory PromptShortcut.fromJson(Map<String, Object?> j) =>
      PromptShortcut(j['label']! as String, j['prompt']! as String);

  final String label;
  final String prompt;

  Map<String, Object?> toJson() => {'label': label, 'prompt': prompt};

  @override
  bool operator ==(Object other) =>
      other is PromptShortcut && other.label == label && other.prompt == prompt;

  @override
  int get hashCode => Object.hash(label, prompt);
}

/// What a new install offers until the user edits the list.
const List<PromptShortcut> defaultPromptShortcuts = [
  PromptShortcut('Explain', 'Explain this simply: '),
  PromptShortcut('Summarise', 'Summarise this in a few bullet points:\n\n'),
  PromptShortcut('Write an email', 'Write a short, friendly email to '),
  PromptShortcut('Brainstorm', 'Give me ten ideas for '),
  PromptShortcut(
    'Plan my day',
    'Help me plan my day. Here is what I need to do: ',
  ),
];
