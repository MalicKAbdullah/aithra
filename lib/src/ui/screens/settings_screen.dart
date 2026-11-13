import 'package:core_lock/core_lock.dart';
import 'package:core_theme/core_theme.dart';
import 'package:core_ui/core_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services.dart';
import '../../voice/speech_service.dart';
import '../aithra_type.dart';
import '../widgets/section_label.dart';
import 'memories_screen.dart';
import 'models_screen.dart';
import 'performance_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  /// Separators start at the row text: 16 padding + 36 badge + 14 gap.
  static const double _indent = 66;

  void _push(BuildContext context, Widget screen) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final s = context.services;
    final c = SuiteColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          0,
          AppSpacing.gutter,
          AppSpacing.xxl,
        ),
        children: [
          const SectionLabel('Assistant', first: true),
          RowGroup(
            separatorIndent: _indent,
            children: [
              ListenableBuilder(
                listenable: s.assistant,
                builder: (context, _) {
                  final m = s.assistant.activeModel;
                  final b = m == null ? null : s.assistant.backendFor(m);
                  return SettingsTile(
                    icon: Icons.memory_rounded,
                    title: 'Models',
                    subtitle: m == null
                        ? 'No model downloaded'
                        : '${m.name}${b == null ? '' : ' · ${b.label}'}',
                    onTap: () => _push(context, const ModelsScreen()),
                  );
                },
              ),
              ListenableBuilder(
                listenable: s.memories,
                builder: (context, _) => SettingsTile(
                  icon: Icons.bookmark_outline_rounded,
                  title: 'Memories',
                  subtitle: '${s.memories.items.length} saved on this phone',
                  onTap: () => _push(context, const MemoriesScreen()),
                ),
              ),
              SettingsTile(
                icon: Icons.speed_rounded,
                title: 'Performance',
                subtitle: 'Speed test results and diagnostics',
                onTap: () => _push(context, const PerformanceScreen()),
              ),
            ],
          ),
          const SectionLabel('Voice and display'),
          RowGroup(
            separatorIndent: _indent,
            children: [
              const _VoiceStatus(),
              AppearanceSetting(controller: s.appearance),
            ],
          ),
          const SectionLabel('Privacy'),
          AppLockSettings(controller: s.lock),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Aithra runs its model on this phone. It connects to the internet '
            'only to download model files from Hugging Face. Chats, photos '
            'and memories are encrypted with a key kept in Android Keystore, '
            'and are never backed up to the cloud.',
            style: AithraType.bodySmall.copyWith(color: c.textTertiary),
          ),
        ],
      ),
    );
  }
}

class _VoiceStatus extends StatefulWidget {
  const _VoiceStatus();

  @override
  State<_VoiceStatus> createState() => _VoiceStatusState();
}

class _VoiceStatusState extends State<_VoiceStatus> {
  @override
  void initState() {
    super.initState();
    context.services.speech.checkStatus();
  }

  @override
  Widget build(BuildContext context) {
    final speech = context.services.speech;
    return ListenableBuilder(
      listenable: speech,
      builder: (context, _) {
        final onDevice = speech.onDeviceAvailable;
        final lang = speech.language ?? 'your language';
        final notice = speech.modelNotice;
        final subtitle = notice != null
            ? notice.text
            : onDevice == null
            ? 'Checking…'
            : !onDevice
            ? 'On-device recognition unavailable; using the system recognizer offline when possible'
            : switch (speech.model) {
                SpeechModel.checking || SpeechModel.unknown => 'Checking…',
                SpeechModel.installed =>
                  'On-device speech recognition ready · $lang',
                SpeechModel.pending =>
                  'Android is downloading the speech model for $lang',
                SpeechModel.missing =>
                  'Speech model for $lang is not downloaded · tap to download',
                SpeechModel.unsupported =>
                  'Android\'s on-device recognizer has no model for $lang',
              };
        final report = speech.report;
        return Column(
          children: [
            SettingsTile(
              icon: Icons.mic_none_rounded,
              title: 'Speech recognition',
              subtitle: subtitle,
              onTap:
                  speech.model == SpeechModel.missing && !speech.download.active
                  ? speech.downloadLanguage
                  : speech.openSettings,
            ),
            if (report != null)
              SettingsTile(
                icon: Icons.content_copy_rounded,
                title: 'Copy speech details',
                subtitle: 'Language sent: ${report.sent}',
                showChevron: false,
                onTap: () async {
                  await Clipboard.setData(
                    ClipboardData(text: report.toString()),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Speech details copied')),
                    );
                  }
                },
              ),
          ],
        );
      },
    );
  }
}
