import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production foreground RF uses the session-bound entrypoint', () {
    final violations = <String>[];

    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))) {
      if (file.readAsStringSync().contains('.rfOperations.runForeground(')) {
        violations.add(file.path);
      }
    }

    expect(violations, isEmpty);
  });

  test('Read Card delegates continuous scan lifecycle to one abstraction', () {
    final source = File('lib/gui/page/read_card.dart').readAsStringSync();

    expect(source, isNot(contains('Timer.periodic')));
    expect(source, isNot(contains('class _ContinuousScanToken')));
    expect(
      RegExp(r'ContinuousScanController\s*\(').allMatches(source).length,
      2,
    );
  });
}
