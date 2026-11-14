import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/chat_session.dart';
import '../../docs/documents.dart';
import '../../services.dart';
import '../aithra_type.dart';
import 'composer.dart';
import 'recording_bar.dart';

/// The composer's "+": photos, the camera and files.
class ComposerAttachButton extends StatelessWidget {
  const ComposerAttachButton({
    required this.controller,
    required this.enabled,
    super.key,
  });

  final ComposerController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Add photos and files',
    iconSize: 24,
    constraints: const BoxConstraints.tightFor(
      width: composerButton,
      height: composerButton,
    ),
    padding: EdgeInsets.zero,
    icon: const Icon(Icons.add_rounded),
    onPressed: enabled ? () => showAttachMenu(context, controller) : null,
  );
}

/// Asks what to add (a photo, a camera shot or a file) and adds it to
/// [controller]. Photos need a model that understands images; files work
/// with every model. The "Ask about a photo" quick action opens this too.
Future<void> showAttachMenu(
  BuildContext context,
  ComposerController controller,
) async {
  HapticFeedback.selectionClick();
  final canAttachImages =
      context.services.assistant.activeModel?.vision ?? false;
  final source = await showModalBottomSheet<String>(
    context: context,
    builder: (sheet) => _AttachSheet(canAttachImages: canAttachImages),
  );
  if (source == null || !context.mounted) return;
  if (source == 'files') {
    await _pickFile(context, controller);
  } else {
    await _pickImage(context, controller, camera: source == 'camera');
  }
}

Future<void> _pickImage(
  BuildContext context,
  ComposerController controller, {
  required bool camera,
}) async {
  final native = context.services.native;
  final Uint8List? jpeg;
  try {
    jpeg = camera ? await native.capturePhoto() : await native.pickImage();
  } on PlatformException catch (e) {
    if (context.mounted) {
      _toast(context, "Couldn't add the photo: ${e.message}");
    }
    return;
  }
  if (jpeg == null) return;
  controller.images.value = [...controller.images.value, PendingImage(jpeg)];
}

Future<void> _pickFile(
  BuildContext context,
  ComposerController controller,
) async {
  final native = context.services.native;
  final progress = native.eventsOf('document').listen((e) {
    controller.reading.value = (
      done: e['done']! as int,
      total: e['total']! as int,
    );
  });
  try {
    final row = await native.pickDocument();
    if (row != null) {
      controller.docs.value = [...controller.docs.value, DocInfo.fromMap(row)];
    }
  } on PlatformException catch (e) {
    if (context.mounted) _toast(context, e.message ?? e.code);
  } finally {
    await progress.cancel();
    controller.reading.value = null;
  }
}

void _toast(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

class _AttachSheet extends StatelessWidget {
  const _AttachSheet({required this.canAttachImages});

  final bool canAttachImages;

  @override
  Widget build(BuildContext context) {
    final c = SuiteColors.of(context);
    const imageNote = 'Needs a model that understands images';
    Widget item(IconData icon, String title, String? subtitle, String? value) =>
        ListTile(
          enabled: value != null,
          leading: Icon(icon),
          title: Text(title),
          subtitle: subtitle == null
              ? null
              : Text(
                  subtitle,
                  style: AithraType.caption.copyWith(color: c.textTertiary),
                ),
          onTap: value == null ? null : () => Navigator.pop(context, value),
        );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            item(
              Icons.photo_library_outlined,
              'Photos',
              canAttachImages ? null : imageNote,
              canAttachImages ? 'gallery' : null,
            ),
            item(
              Icons.photo_camera_outlined,
              'Camera',
              canAttachImages ? null : imageNote,
              canAttachImages ? 'camera' : null,
            ),
            item(
              Icons.description_outlined,
              'Files',
              'PDF, Word, text and code',
              'files',
            ),
          ],
        ),
      ),
    );
  }
}
