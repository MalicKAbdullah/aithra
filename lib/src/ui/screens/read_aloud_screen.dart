import 'package:core_theme/core_theme.dart';
import 'package:core_ui/core_ui.dart';
import 'package:flutter/material.dart';

import '../../services.dart';
import '../aithra_type.dart';
import '../widgets/section_label.dart';

/// An installed offline TextToSpeech voice.
class TtsVoice {
  const TtsVoice(this.name, this.language, this.label);

  factory TtsVoice.fromMap(Map<String, Object?> m) => TtsVoice(
    m['name']! as String,
    m['language']! as String,
    m['label']! as String,
  );

  final String name;

  /// BCP 47.
  final String language;

  /// The language's display name.
  final String label;
}

/// How replies are read aloud: whether every reply is, in which language
/// and voice, and how fast.
class ReadAloudScreen extends StatefulWidget {
  const ReadAloudScreen({super.key});

  @override
  State<ReadAloudScreen> createState() => _ReadAloudScreenState();
}

class _ReadAloudScreenState extends State<ReadAloudScreen> {
  late final Future<List<TtsVoice>> _voices = context.services.native
      .ttsVoices()
      .then((list) => list.map(TtsVoice.fromMap).toList());

  static const _sample =
      'Hi, I am Aithra. This is how I sound when I read a reply.';

  @override
  void dispose() {
    final read = context.services.readAloud;
    if (read.isReading(_sample)) read.stop();
    super.dispose();
  }

  /// Languages with at least one voice, by display name.
  static Map<String, String> _languages(List<TtsVoice> voices) => {
    for (final v in voices) v.language: v.label,
  };

  /// "English (United Kingdom) · voice 2": engines name voices with codes,
  /// so voices are numbered within their language.
  static String voiceLabel(List<TtsVoice> voices, TtsVoice v) {
    final same = voices.where((x) => x.language == v.language).toList();
    return same.length == 1
        ? v.label
        : '${v.label} · voice ${same.indexOf(v) + 1}';
  }

  Future<void> _pickLanguage(List<TtsVoice> voices) async {
    final s = context.services.settings;
    final languages = _languages(voices);
    final picked = await showModalBottomSheet<(String?,)>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _Picker(
        title: 'Language',
        options: [
          (
            value: null,
            title: 'Match each reply',
            subtitle: 'Each reply is read in the language it is written in',
          ),
          for (final e in languages.entries)
            (value: e.key, title: e.value, subtitle: null),
        ],
        selected: s.ttsLanguage,
      ),
    );
    if (picked == null) return;
    final language = picked.$1;
    await s.update((x) {
      x.ttsLanguage = language;
      // A voice in another language would never be used.
      final voice = voices.where((v) => v.name == x.ttsVoice).firstOrNull;
      if (language != null && voice?.language != language) x.ttsVoice = null;
    });
  }

  Future<void> _pickVoice(List<TtsVoice> voices) async {
    final s = context.services.settings;
    final language = s.ttsLanguage;
    final offered = [
      for (final v in voices)
        if (language == null || v.language == language) v,
    ];
    final picked = await showModalBottomSheet<(String?,)>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _Picker(
        title: 'Voice',
        options: [
          (
            value: null,
            title: 'Automatic',
            subtitle: "The speech engine's usual voice for each language",
          ),
          for (final v in offered)
            (value: v.name, title: voiceLabel(voices, v), subtitle: null),
        ],
        selected: s.ttsVoice,
      ),
    );
    if (picked == null) return;
    await s.update((x) => x.ttsVoice = picked.$1);
  }

  void _preview(List<TtsVoice> voices) {
    final s = context.services;
    if (s.readAloud.isReading(_sample)) {
      s.readAloud.stop();
      return;
    }
    final voice = voices
        .where((v) => v.name == s.settings.ttsVoice)
        .firstOrNull;
    // The sample is in English; it is spoken with the chosen voice, or in
    // the chosen language, so that is what the user hears.
    s.readAloud.read(
      _sample,
      _sample,
      language: voice?.language ?? s.settings.ttsLanguage,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    final c = SuiteColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Read aloud')),
      body: FutureBuilder<List<TtsVoice>>(
        future: _voices,
        builder: (context, snapshot) {
          final voices = snapshot.data ?? const <TtsVoice>[];
          return ListenableBuilder(
            listenable: Listenable.merge([s.settings, s.readAloud]),
            builder: (context, _) {
              final st = s.settings;
              final languageName = st.ttsLanguage == null
                  ? 'Match each reply'
                  : _languages(voices)[st.ttsLanguage] ?? st.ttsLanguage!;
              final voice = voices
                  .where((v) => v.name == st.ttsVoice)
                  .firstOrNull;
              return ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutter,
                  0,
                  AppSpacing.gutter,
                  AppSpacing.xxl,
                ),
                children: [
                  const SectionLabel('Replies', first: true),
                  RowGroup(
                    separatorIndent: 66,
                    children: [
                      SettingsTile(
                        icon: Icons.volume_up_outlined,
                        title: 'Read replies aloud',
                        subtitle: st.speakReplies
                            ? 'Each reply is spoken as it is written'
                            : 'Replies are read aloud only when you ask',
                        onTap: () =>
                            st.update((x) => x.speakReplies = !x.speakReplies),
                        trailing: Switch(
                          value: st.speakReplies,
                          onChanged: (v) =>
                              st.update((x) => x.speakReplies = v),
                        ),
                      ),
                    ],
                  ),
                  const SectionLabel('Voice'),
                  RowGroup(
                    separatorIndent: 66,
                    children: [
                      SettingsTile(
                        icon: Icons.translate_rounded,
                        title: 'Language',
                        subtitle: languageName,
                        onTap: voices.isEmpty
                            ? null
                            : () => _pickLanguage(voices),
                      ),
                      SettingsTile(
                        icon: Icons.record_voice_over_outlined,
                        title: 'Voice',
                        subtitle: voice == null
                            ? 'Automatic'
                            : voiceLabel(voices, voice),
                        onTap: voices.isEmpty ? null : () => _pickVoice(voices),
                      ),
                    ],
                  ),
                  const SectionLabel('Speed'),
                  Container(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.md,
                      AppSpacing.sm,
                      AppSpacing.sm,
                      AppSpacing.sm,
                    ),
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                    ),
                    child: Row(
                      children: [
                        Text(
                          '${_rate(st.ttsRate)}×',
                          style: AithraType.number.copyWith(
                            color: c.textPrimary,
                          ),
                        ),
                        Expanded(
                          child: Slider(
                            value: st.ttsRate,
                            min: 0.5,
                            max: 2,
                            divisions: 6,
                            label: '${_rate(st.ttsRate)}×',
                            onChanged: (v) => st.update((x) => x.ttsRate = v),
                          ),
                        ),
                        IconButton(
                          tooltip: s.readAloud.isReading(_sample)
                              ? 'Stop'
                              : 'Play a sample',
                          icon: Icon(
                            s.readAloud.isReading(_sample)
                                ? Icons.stop_rounded
                                : Icons.play_arrow_rounded,
                          ),
                          onPressed: () => _preview(voices),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    snapshot.hasData && voices.isEmpty
                        ? 'No offline voices are installed. Add one in '
                              "Android's text-to-speech settings."
                        : 'Only voices installed on this phone are used, so '
                              'nothing you read leaves it.',
                    style: AithraType.bodySmall.copyWith(color: c.textTertiary),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  static String _rate(double r) =>
      r == r.roundToDouble() ? r.toStringAsFixed(0) : '$r';
}

typedef _Option = ({String? value, String title, String? subtitle});

/// A single-choice list in a bottom sheet; pops with the chosen value
/// wrapped in a record, so "none" (null) can be chosen too.
class _Picker extends StatelessWidget {
  const _Picker({
    required this.title,
    required this.options,
    required this.selected,
  });

  final String title;
  final List<_Option> options;
  final String? selected;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, scroll) => SafeArea(
        child: ListView(
          controller: scroll,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                AppSpacing.md,
                AppSpacing.gutter,
                AppSpacing.sm,
              ),
              child: Text(
                title,
                style: AithraType.h2.copyWith(color: c.textPrimary),
              ),
            ),
            for (final o in options)
              ListTile(
                title: Text(o.title),
                subtitle: o.subtitle == null ? null : Text(o.subtitle!),
                trailing: o.value == selected
                    ? Icon(Icons.check_rounded, color: c.accent)
                    : null,
                onTap: () => Navigator.pop(context, (o.value,)),
              ),
          ],
        ),
      ),
    );
  }
}
