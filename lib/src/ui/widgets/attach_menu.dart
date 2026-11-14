import 'dart:async';

import 'package:core_theme/core_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/chat_session.dart';
import '../../docs/documents.dart';
import '../../services.dart';
import '../aithra_type.dart';
import 'composer.dart';

/// The composer's "+": photos, the camera and files. Photos need a model
/// that understands images; files work with every model.
class AttachButton extends StatelessWidget {
  const AttachButton({
    required this.controller,
    required this.canAttachImages,
    required this.enabled,
    super.key,
  });

  final ComposerController controller;
  final bool canAttachImages;
  final bool enabled;

  Future<void> _open(BuildContext context) async {
    HapticFeedback.selectionClick();
    final source = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => _AttachSheet(canAttachImages: canAttachImages),
    );
    if (source == null || !context.mounted) return;
    if (source == 'files') {
      await _pickFile(context);
    } else {
      await _pickImage(context, camera: source == 'camera');
    }
  }

  Future<void> _pickImage(BuildContext context, {required bool camera}) async {
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

  Future<void> _pickFile(BuildContext context) async {
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
        controller.docs.value = [
          ...controller.docs.value,
          DocInfo.fromMap(row),
        ];
      }
    } on PlatformException catch (e) {
      if (context.mounted) _toast(context, e.message ?? e.code);
    } finally {
      await progress.cancel();
      controller.reading.value = null;
    }
  }

  static void _toast(BuildContext context, String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Add photos and files',
    iconSize: 24,
    icon: const Icon(Icons.add_rounded),
    onPressed: enabled ? () => _open(context) : null,
  );
}

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
