import 'dart:io';
import 'dart:typed_data';

import 'package:chameleonultragui/helpers/single_slot_backup_workflow.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('complete temporary write atomically replaces an existing backup',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'chameleon-atomic-backup-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final destination = File('${directory.path}/device-backup.json');
    await destination.writeAsBytes([9, 8, 7, 6], flush: true);
    final replacement = Uint8List.fromList(List.generate(64, (index) => index));

    await const AtomicSlotBackupFileWriter().write(
      destination.path,
      replacement,
    );

    expect(await destination.readAsBytes(), orderedEquals(replacement));
    expect(
      await directory.list().map((entry) => entry.path).toList(),
      [destination.path],
    );
  });

  test('partial temporary write never replaces an existing backup', () async {
    final directory = await Directory.systemTemp.createTemp(
      'chameleon-atomic-backup-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final destination = File('${directory.path}/device-backup.json');
    final previous = Uint8List.fromList([9, 8, 7, 6]);
    await destination.writeAsBytes(previous, flush: true);
    File? temporaryFile;
    final writer = AtomicSlotBackupFileWriter(
      writeTemporaryFile: (file, bytes) async {
        temporaryFile = file;
        await file.writeAsBytes(bytes.take(3).toList(), flush: true);
        throw StateError('simulated interrupted write');
      },
    );

    await expectLater(
      writer.write(
        destination.path,
        Uint8List.fromList(List.generate(64, (index) => index)),
      ),
      throwsStateError,
    );

    expect(await destination.readAsBytes(), orderedEquals(previous));
    expect(temporaryFile, isNotNull);
    expect(await temporaryFile!.exists(), isFalse);
    expect(
      await directory.list().map((entry) => entry.path).toList(),
      [destination.path],
    );
  });
}
