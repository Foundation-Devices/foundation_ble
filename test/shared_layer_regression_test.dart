import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'shared layer stays free of services imports and platform branching',
    () async {
      final root = Directory('lib/src');
      final dartFiles = root
          .listSync(recursive: true)
          .whereType<File>()
          .where((File file) => file.path.endsWith('.dart'));

      for (final file in dartFiles) {
        final normalizedPath = file.path.replaceAll('\\', '/');
        if (normalizedPath.contains('/method_channel/')) {
          continue;
        }

        final contents = await file.readAsString();
        expect(
          contents.contains("package:flutter/services.dart"),
          isFalse,
          reason: normalizedPath,
        );
        expect(
          contents.contains('defaultTargetPlatform'),
          isFalse,
          reason: normalizedPath,
        );
        expect(
          contents.contains('TargetPlatform.'),
          isFalse,
          reason: normalizedPath,
        );
      }
    },
  );
}
