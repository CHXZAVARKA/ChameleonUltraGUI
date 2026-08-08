import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('write tool and slot workflows use the session-bound RF entrypoint', () {
    const migratedWorkflows = [
      'lib/gui/component/mifare/standard_write.dart',
      'lib/gui/component/slot_changer.dart',
      'lib/gui/menu/dialogs/slot/edit.dart',
      'lib/gui/menu/dialogs/slot/export.dart',
      'lib/gui/menu/dialogs/slot/settings.dart',
      'lib/gui/menu/tools/hf_sniffing.dart',
      'lib/gui/menu/tools/lf_sniffing.dart',
      'lib/gui/menu/tools/t55xx_password_cleaner.dart',
      'lib/gui/page/slot_manager.dart',
      'lib/gui/page/write_card.dart',
      'lib/helpers/mifare_classic/write/base.dart',
    ];

    for (final path in migratedWorkflows) {
      final source = File(path).readAsStringSync();
      expect(
        source,
        isNot(contains('ConnectedDeviceSession.capture')),
        reason:
            '$path must not capture a session outside the shared entrypoint',
      );
      expect(
        source,
        isNot(contains('rfOperations.runForeground')),
        reason:
            '$path must acquire foreground RF through the shared entrypoint',
      );
      expect(
        source,
        contains('runSessionBoundForeground'),
        reason: '$path must use the shared session-bound RF entrypoint',
      );
    }
  });
}
