import 'dart:async';

import 'package:core_lock/core_lock.dart';
import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/templates.dart';
import '../platform/native.dart';
import '../ui/aithra_type.dart';
import '../ui/widgets/aithra_mark.dart';
import '../ui/widgets/markdown_view.dart';
import '../ui/widgets/message_bubble.dart';
import '../ui/widgets/template_chip.dart';
import 'ask_controller.dart';

/// Shows the Ask sheet as soon as the selection and the theme are known;
/// everything else loads behind it.
Future<void> runAsk(NativeBridge native) async {
  final results = await Future.wait([
    native.askRequest(),
    AppearanceController.load(),
  ]);
  final request = results[0] as ({String text, bool readOnly});
  final controller = AskController(
    native,
    request.text,
    readOnly: request.readOnly,
  );
  runApp(
    AskApp(
      controller: controller,
      appearance: results[1] as AppearanceController,
    ),
  );
  await controller.start();
}

class AskApp extends StatelessWidget {
  const AskApp({required this.controller, required this.appearance, super.key});

  final AskController controller;
  final AppearanceController appearance;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: appearance,
    builder: (context, _) => MaterialApp(
      title: 'Ask Aithra',
      debugShowCheckedModeBanner: false,
      color: Colors.transparent,
      theme: aithraTheme(Brightness.light),
      darkTheme: aithraTheme(Brightness.dark),
      themeMode: appearance.mode,
      builder: (context, child) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final lock = controller.lock;
          return lock == null
              ? child!
              : AppLockGate(
                  controller: lock,
                  appMark: const AithraMark(size: 56),
                  child: child!,
                );
        },
      ),
      home: AskSheet(controller: controller),
    ),
  );
}

/// A sheet over the app the text was selected in: the selection, the
/// chips, and the answer with what to do with it.
class AskSheet extends StatefulWidget {
  const AskSheet({required this.controller, super.key});

  final AskController controller;

  @override
  State<AskSheet> createState() => _AskSheetState();
}

class _AskSheetState extends State<AskSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: AppMotion.base,
  );
  late final Animation<Offset> _rise = Tween(
    begin: const Offset(0, 1),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _in, curve: AppMotion.emphasized));
  final _question = TextEditingController();
  final _questionFocus = FocusNode();

  /// Which follow-up row is open under the chips: Rewrite's tones or the
  /// Ask… field.
  String? _open;
  bool _copied = false;

  AskController get _c => widget.controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _in.value = 1;
    } else if (_in.isDismissed) {
      _in.forward();
    }
  }

  @override
  void dispose() {
    _in.dispose();
    _question.dispose();
    _questionFocus.dispose();
    super.dispose();
  }

  void _pick(PromptTemplate t) {
    HapticFeedback.selectionClick();
    if (t.id == 'rewrite' || t.id == 'ask') {
      setState(() => _open = _open == t.id ? null : t.id);
      if (_open == 'ask') _questionFocus.requestFocus();
      return;
    }
    setState(() => _open = t.id.startsWith('rewrite.') ? 'rewrite' : null);
    unawaited(_c.ask(t));
  }

  void _sendQuestion() {
    final q = _question.text.trim();
    if (q.isEmpty) return;
    _questionFocus.unfocus();
    unawaited(_c.ask(textTemplates.last, question: q));
  }

  Future<void> _pickLanguage() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _LanguagePicker(languages: _c.languages),
    );
    if (picked == null) return;
    _c.setLanguage(picked);
    final t = _c.template;
    if (t != null && t.translates) unawaited(_c.ask(t));
  }

  Future<void> _copy() async {
    await _c.copy();
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: _c.close,
              child: FadeTransition(
                opacity: _in,
                child: const ColoredBox(color: Color(0x66000000)),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SlideTransition(
              position: _rise,
              child: Padding(
                padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight:
                        (media.size.height - media.viewInsets.bottom) * 0.9,
                    maxWidth: 640,
                  ),
                  child: ListenableBuilder(
                    listenable: _c,
                    builder: (context, _) => _sheet(context),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sheet(BuildContext context) {
    final c = SuiteColors.of(context);
    final ready = _c.lock != null;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppSpacing.radiusXl),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 24,
            offset: Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.sm,
            AppSpacing.gutter,
            AppSpacing.md,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: c.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              _header(c),
              const SizedBox(height: AppSpacing.smd),
              if (ready) ...[
                _Selection(text: _c.selection),
                const SizedBox(height: AppSpacing.md),
                if (_c.blocker case final b?)
                  _Blocked(blocker: b, onOpen: () => _c.native.askOpenChat())
                else ...[
                  _chips(),
                  if (_open == 'rewrite') ...[
                    const SizedBox(height: AppSpacing.sm),
                    _tones(),
                  ],
                  if (_open == 'ask') ...[
                    const SizedBox(height: AppSpacing.sm),
                    _questionField(c),
                  ],
                  if (_c.template?.translates ?? false) ...[
                    const SizedBox(height: AppSpacing.sm),
                    _languageRow(c),
                  ],
                  Flexible(child: _answer(c)),
                  _actions(c),
                ],
              ] else
                const SizedBox(height: 96),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(SuiteColors c) => Row(
    children: [
      const AithraMark(size: 26),
      const SizedBox(width: AppSpacing.sm),
      Text(
        'Ask Aithra',
        style: AithraType.title.copyWith(color: c.textPrimary),
      ),
      const Spacer(),
      IconButton(
        tooltip: 'Close',
        icon: Icon(Icons.close_rounded, color: c.textSecondary),
        onPressed: _c.close,
      ),
    ],
  );

  Widget _chips() => Wrap(
    spacing: AppSpacing.sm,
    runSpacing: AppSpacing.sm,
    children: [
      for (final t in [...textTemplates, ...userTemplates(_c.shortcuts)])
        TemplateChip(
          template: t,
          selected:
              _open == t.id ||
              (_open == null && _c.template?.id == t.id) ||
              (t.id == 'rewrite' &&
                  (_c.template?.id.startsWith('rewrite.') ?? false)),
          enabled: _c.canAsk,
          onTap: () => _pick(t),
        ),
    ],
  );

  Widget _tones() => Wrap(
    spacing: AppSpacing.sm,
    runSpacing: AppSpacing.sm,
    children: [
      for (final t in rewriteTones)
        TemplateChip(
          template: t,
          selected: _c.template?.id == t.id,
          enabled: _c.canAsk,
          dense: true,
          onTap: () => _pick(t),
        ),
    ],
  );

  Widget _questionField(SuiteColors c) => Container(
    decoration: BoxDecoration(
      color: c.surfaceAlt,
      borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
    ),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: _question,
            focusNode: _questionFocus,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _sendQuestion(),
            style: AithraType.body.copyWith(color: c.textPrimary),
            decoration: InputDecoration(
              hintText: 'Ask about this text',
              hintStyle: AithraType.body.copyWith(color: c.textTertiary),
              isDense: true,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                13,
                AppSpacing.xs,
                13,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(6),
          child: IconButton.filled(
            tooltip: 'Ask',
            iconSize: 20,
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            padding: EdgeInsets.zero,
            onPressed: _c.canAsk ? _sendQuestion : null,
            icon: const Icon(Icons.arrow_upward_rounded),
          ),
        ),
      ],
    ),
  );

  Widget _languageRow(SuiteColors c) => Row(
    children: [
      Text(
        'Into',
        style: AithraType.bodySmall.copyWith(color: c.textSecondary),
      ),
      const SizedBox(width: AppSpacing.xs),
      TextButton.icon(
        onPressed: _pickLanguage,
        iconAlignment: IconAlignment.end,
        icon: const Icon(Icons.expand_more_rounded, size: 18),
        label: Text(_c.language),
      ),
    ],
  );

  Widget _answer(SuiteColors c) {
    if (_c.phase == AskPhase.idle && _c.error == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: SingleChildScrollView(
        child: ValueListenableBuilder<String>(
          valueListenable: _c.answer,
          builder: (context, text, _) {
            if (_c.error case final e?) {
              return Text(
                e,
                style: AithraType.bodySmall.copyWith(color: c.negative),
              );
            }
            if (text.isEmpty) {
              return _c.phase == AskPhase.done
                  ? const SizedBox.shrink()
                  : const Align(
                      alignment: Alignment.centerLeft,
                      child: TypingDots(),
                    );
            }
            return MarkdownView(text);
          },
        ),
      ),
    );
  }

  Widget _actions(SuiteColors c) {
    if (_c.phase == AskPhase.preparing || _c.phase == AskPhase.streaming) {
      return Padding(
        padding: const EdgeInsets.only(top: AppSpacing.smd),
        child: Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            onPressed: _c.stop,
            icon: const Icon(Icons.stop_rounded, size: 18),
            label: const Text('Stop'),
          ),
        ),
      );
    }
    if (_c.phase != AskPhase.done || _c.result.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.smd),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.xs,
        children: [
          TextButton.icon(
            onPressed: _copy,
            icon: Icon(
              _copied ? Icons.check_rounded : Icons.content_copy_rounded,
              size: 18,
            ),
            label: Text(_copied ? 'Copied' : 'Copy'),
          ),
          TextButton.icon(
            onPressed: _c.continueInChat,
            icon: const Icon(Icons.forum_outlined, size: 18),
            label: const Text('Continue in chat'),
          ),
          if (!_c.readOnly)
            FilledButton.icon(
              onPressed: _c.replace,
              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
              label: const Text('Replace'),
            ),
        ],
      ),
    );
  }
}

/// The selected text, quoted, a few lines of it.
class _Selection extends StatelessWidget {
  const _Selection({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.smd,
        AppSpacing.sm + 2,
        AppSpacing.smd,
        AppSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border(left: BorderSide(color: c.accent, width: 3)),
      ),
      child: Text(
        text.trim(),
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: AithraType.bodySmall.copyWith(color: c.textSecondary),
      ),
    );
  }
}

/// Why the sheet cannot answer, with the way into the app.
class _Blocked extends StatelessWidget {
  const _Blocked({required this.blocker, required this.onOpen});

  final AskBlocker blocker;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final message = switch (blocker) {
      AskBlocker.setup => 'Open Aithra once to set it up, then ask from here.',
      AskBlocker.noModel =>
        'Aithra has no model on this phone yet. Download one in the app.',
      AskBlocker.untuned =>
        'Aithra is still getting its model ready for this phone. Open the '
            'app to finish.',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(message, style: AithraType.body.copyWith(color: c.textSecondary)),
        const SizedBox(height: AppSpacing.smd),
        FilledButton(onPressed: onOpen, child: const Text('Open Aithra')),
      ],
    );
  }
}

/// Every language the phone knows, the user's own first, with a filter.
class _LanguagePicker extends StatefulWidget {
  const _LanguagePicker({required this.languages});

  final List<({String tag, String name})> languages;

  @override
  State<_LanguagePicker> createState() => _LanguagePickerState();
}

class _LanguagePickerState extends State<_LanguagePicker> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    final shown = [
      for (final l in widget.languages)
        if (l.name.toLowerCase().contains(_filter.toLowerCase())) l,
    ];
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: TextField(
                autofocus: true,
                onChanged: (v) => setState(() => _filter = v),
                decoration: const InputDecoration(
                  hintText: 'Language',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: shown.length,
                itemBuilder: (context, i) => ListTile(
                  title: Text(
                    shown[i].name,
                    style: AithraType.body.copyWith(color: c.textPrimary),
                  ),
                  onTap: () => Navigator.pop(context, shown[i].name),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
