import 'dart:typed_data';

import 'package:chameleonultragui/gui/menu/dialogs/slot/export.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'slot dump reads exact chunks for every supported Classic geometry',
    () async {
      const cases = {'Mini': 20, '1K': 64, '1K EV1': 72, '2K': 128, '4K': 256};

      for (final MapEntry(key: name, value: blockCount) in cases.entries) {
        final requests = <(int, int)>[];

        final dump = await readMifareClassicSlotDump(
          blockCount: blockCount,
          readBlocks: (firstBlock, requestedBlocks) async {
            requests.add((firstBlock, requestedBlocks));
            return Uint8List.fromList(
              List<int>.generate(
                requestedBlocks * 16,
                (offset) => (firstBlock * 16 + offset) & 0xFF,
              ),
            );
          },
        );

        expect(requests, [
          for (var firstBlock = 0; firstBlock < blockCount; firstBlock += 16)
            (firstBlock, (blockCount - firstBlock).clamp(0, 16)),
        ], reason: name);
        expect(dump.complete, isTrue, reason: name);
        expect(dump.blocks, hasLength(blockCount), reason: name);
        expect(
          dump.blocks.every((block) => block.length == 16),
          isTrue,
          reason: name,
        );
      }
    },
  );

  test(
    'short slot chunk clears completeness when a saved card is overwritten',
    () async {
      final dump = await readMifareClassicSlotDump(
        blockCount: 20,
        readBlocks: (firstBlock, blockCount) async {
          final expectedLength = blockCount * 16;
          return Uint8List.fromList(
            List<int>.filled(
              firstBlock == 16 ? expectedLength - 1 : expectedLength,
              0xA5,
            ),
          );
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
    },
  );

  test('oversized slot chunk cannot produce a complete dump', () async {
    final dump = await readMifareClassicSlotDump(
      blockCount: 20,
      readBlocks: (firstBlock, blockCount) async {
        final expectedLength = blockCount * 16;
        return Uint8List.fromList(
          List<int>.filled(
            firstBlock == 16 ? expectedLength + 1 : expectedLength,
            0x5A,
          ),
        );
      },
    );

    expect(dump.complete, isFalse);
    expect(dump.blocks, hasLength(20));
    expect(dump.blocks.every((block) => block.length == 16), isTrue);
  });
}
