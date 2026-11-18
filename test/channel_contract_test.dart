import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Method names in [source] matched by [pattern]'s first group.
Set<String> _names(String source, RegExp pattern) => {
  for (final m in pattern.allMatches(source)) m.group(1)!,
};

void main() {
  test('every method NativeBridge calls has a Kotlin handler', () {
    // A call is a quoted `area.action` name opening an argument list; a
    // handler is the same name opening a `when` branch.
    final called = _names(
      File('lib/src/platform/native.dart').readAsStringSync(),
      RegExp(r"\(\s*'([a-z][A-Za-z]*\.[a-z][A-Za-z]*)'"),
    );
    const kotlin = 'android/app/src/main/kotlin/dev/abdullah/aithra';
    final handled = {
      for (final file in ['NativeChannels.kt', 'AskActivity.kt'])
        ..._names(
          File('$kotlin/$file').readAsStringSync(),
          RegExp(r'"([a-z][A-Za-z]*\.[a-z][A-Za-z]*)"\s*->'),
        ),
    };
    expect(called, isNotEmpty);
    expect(called.difference(handled), isEmpty);
  });
}
