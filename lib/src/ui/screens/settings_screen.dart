import 'package:core_lock/core_lock.dart';
import 'package:core_theme/core_theme.dart';
import 'package:core_ui/core_ui.dart';
import 'package:flutter/material.dart';

import '../../services.dart';
import 'memories_screen.dart';
import 'models_screen.dart';
import 'performance_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

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
          const SectionHeader(title: 'Assistant'),
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
          const SectionHeader(title: 'Voice'),
          const _VoiceStatus(),
          const SectionHeader(title: 'Appearance'),
          AppearanceSetting(controller: s.appearance),
          const SectionHeader(title: 'Privacy'),
          AppLockSettings(controller: s.lock),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Aithra runs its model on this phone. It connects to the internet '
            'only to download model files from Hugging Face. Chats, photos '
            'and memories are encrypted with a key kept in Android Keystore, '
            'and are never backed up to the cloud.',
            style: AppTextStyles.bodySmall.copyWith(
              color: c.textSecondary,
              height: 1.5,
            ),
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
        final installed = speech.languageInstalled;
        final subtitle = onDevice == null
            ? 'Checking…'
            : !onDevice
            ? 'On-device recognition unavailable; using the system recognizer offline when possible'
            : installed == false
            ? 'Speech model for your language is not downloaded'
            : 'On-device speech recognition ready';
        return SettingsTile(
          icon: Icons.mic_none_rounded,
          title: 'Speech recognition',
          subtitle: subtitle,
          showChevron: installed == false,
          onTap: installed == false
              ? speech.downloadLanguage
              : speech.openSettings,
        );
      },
    );
  }
}
