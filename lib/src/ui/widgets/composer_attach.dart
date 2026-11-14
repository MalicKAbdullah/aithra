import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/chat_session.dart';
import '../../services.dart';
import 'composer.dart';
import 'recording_bar.dart';

/// The composer's attach slot.
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
    tooltip: 'Add image',
    iconSize: 22,
    constraints: const BoxConstraints.tightFor(
      width: composerButton,
      height: composerButton,
    ),
    padding: EdgeInsets.zero,
    icon: const Icon(Icons.add_photo_alternate_outlined),
    onPressed: enabled ? () => showAttachMenu(context, controller) : null,
  );
}

/// Asks where the photo comes from and adds it to [controller]'s pending
/// images. The "Ask about a photo" quick action opens this too.
Future<void> showAttachMenu(
  BuildContext context,
  ComposerController controller,
) async {
  final native = context.services.native;
  final source = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Photo library'),
            onTap: () => Navigator.pop(context, 'gallery'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Camera'),
            onTap: () => Navigator.pop(context, 'camera'),
          ),
        ],
      ),
    ),
  );
  if (source == null) return;
  final Uint8List? jpeg;
  try {
    jpeg = source == 'camera'
        ? await native.capturePhoto()
        : await native.pickImage();
  } on PlatformException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't add the photo: ${e.message}")),
      );
    }
    return;
  }
  if (jpeg == null) return;
  controller.images.value = [...controller.images.value, PendingImage(jpeg)];
}
