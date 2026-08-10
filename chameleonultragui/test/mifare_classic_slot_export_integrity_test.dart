import 'dart:typed_data';

import 'package:chameleonultragui/gui/menu/dialogs/slot/export.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('slot dump validates each exact chunk including the final partial chunk',
      () async {
    final requests = <(int, int)>[];

    final dump = await readMifareClassicSlotDump(
      blockCount: 20,
      readBlocks: (firstBlock, blockCount) async {
        requests.add((firstBlock, blockCount));
        return Uint8List.fromList(List<int>.generate(
          blockCount * 16,
          (offset) => (firstBlock * 16 + offset) & 0xFF,
        ));
      },
    );

    expect(requests, [(0, 16), (16, 4)]);
    expect(dump.complete, isTrue);
    expect(dump.blocks, hasLength(20));
    expect(dump.blocks.every((block) => block.length == 16), isTrue);
    expect(dump.blocks[16][0], 0);
    expect(dump.blocks[19][15], 63);
  });

  test('short slot chunk stays incomplete when zero-filled data is overwritten',
      () async {
    final dump = await readMifareClassicSlotDump(
      blockCount: 20,
      readBlocks: (firstBlock, blockCount) async {
        final expectedLength = blockCount * 16;
        return Uint8List.fromList(List<int>.filled(
          firstBlock == 16 ? expectedLength - 1 : expectedLength,
          0xA5,
        ));
      },
    );

    expect(dump.complete, isFalse);
    expect(dump.blocks, hasLength(20));
    expect(dump.blocks.last.last, 0);

    final target = CardSave(
      uid: 'old',
      name: 'saved',
      tag: TagType.mifareMini,
      data: List.generate(20, (_) => Uint8List(16)),
      extraData: CardSaveExtra(mifareClassicDumpComplete: true),
    );
    final source = CardSave(
      uid: 'new',
      name: 'slot',
      tag: TagType.mifareMini,
      data: dump.blocks,
      extraData: CardSaveExtra(mifareClassicDumpComplete: dump.complete),
    );

    overwriteCardSaveFromSlot(target, source);

    expect(target.uid, 'new');
    expect(target.extraData.mifareClassicDumpComplete, isFalse);
  });
}
