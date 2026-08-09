import 'dart:typed_data';

import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('saved cards accept every exact MIFARE Classic geometry', () {
    const cases = [
      (
        name: 'Mini',
        tag: TagType.mifareMini,
        type: MifareClassicType.mini,
        isEV1: false,
        blockCount: 20,
        imageSize: 320,
      ),
      (
        name: '1K',
        tag: TagType.mifare1K,
        type: MifareClassicType.m1k,
        isEV1: false,
        blockCount: 64,
        imageSize: 1024,
      ),
      (
        name: '1K EV1',
        tag: TagType.mifare1K,
        type: MifareClassicType.m1k,
        isEV1: true,
        blockCount: 72,
        imageSize: 1152,
      ),
      (
        name: '2K',
        tag: TagType.mifare2K,
        type: MifareClassicType.m2k,
        isEV1: false,
        blockCount: 128,
        imageSize: 2048,
      ),
      (
        name: '4K',
        tag: TagType.mifare4K,
        type: MifareClassicType.m4k,
        isEV1: false,
        blockCount: 256,
        imageSize: 4096,
      ),
    ];

    for (final geometryCase in cases) {
      for (final slotCount in {
        geometryCase.blockCount,
        256,
      }) {
        final card = CardSave(
          uid: '01 02 03 04',
          name: geometryCase.name,
          tag: geometryCase.tag,
          data: List.generate(
            slotCount,
            (block) =>
                block < geometryCase.blockCount ? Uint8List(16) : Uint8List(0),
          ),
          extraData: CardSaveExtra(mifareClassicDumpComplete: true),
        );

        for (final geometry in [
          MifareClassicGeometry.fromSavedCardData(card),
          MifareClassicGeometry.fromSavedCard(card),
        ]) {
          expect(
            (
              geometry?.type,
              geometry?.isEV1,
              geometry?.blockCount,
              geometry?.imageSize,
            ),
            (
              geometryCase.type,
              geometryCase.isEV1,
              geometryCase.blockCount,
              geometryCase.imageSize,
            ),
            reason: '${geometryCase.name} with $slotCount slots',
          );
        }
      }
    }
  });

  test('saved 1K card rejects non-empty blocks from a larger dump', () {
    final card = CardSave(
      uid: '01 02 03 04',
      name: '4K data marked as 1K',
      tag: TagType.mifare1K,
      data: List.generate(256, (_) => Uint8List(16)),
      extraData: CardSaveExtra(mifareClassicDumpComplete: true),
    );

    expect(
      (
        MifareClassicGeometry.fromSavedCardData(card),
        MifareClassicGeometry.fromSavedCard(card),
      ),
      (null, null),
    );
  });

  test('saved cards reject missing and malformed expected blocks', () {
    final cases = <(String, List<Uint8List>)>[
      (
        'missing block',
        List.generate(63, (_) => Uint8List(16)),
      ),
      (
        'empty expected block',
        List.generate(
          256,
          (block) => block < 64 && block != 12 ? Uint8List(16) : Uint8List(0),
        ),
      ),
      (
        'short block',
        List.generate(
          64,
          (block) => Uint8List(block == 12 ? 15 : 16),
        ),
      ),
      (
        'long block',
        List.generate(
          64,
          (block) => Uint8List(block == 12 ? 17 : 16),
        ),
      ),
      (
        'missing EV1 blocks',
        List.generate(68, (_) => Uint8List(16)),
      ),
    ];

    for (final (name, data) in cases) {
      final card = CardSave(
        uid: '01 02 03 04',
        name: name,
        tag: TagType.mifare1K,
        data: data,
        extraData: CardSaveExtra(mifareClassicDumpComplete: true),
      );

      expect(
        (
          MifareClassicGeometry.fromSavedCardData(card),
          MifareClassicGeometry.fromSavedCard(card),
        ),
        (null, null),
        reason: name,
      );
    }
  });

  test('saved cards reject data from every mismatched tag geometry', () {
    const cases = [
      (name: '1K data as Mini', tag: TagType.mifareMini, blockCount: 64),
      (name: 'Mini data as 1K', tag: TagType.mifare1K, blockCount: 20),
      (name: '2K data as 1K', tag: TagType.mifare1K, blockCount: 128),
      (name: '1K data as 2K', tag: TagType.mifare2K, blockCount: 64),
      (name: '4K data as 2K', tag: TagType.mifare2K, blockCount: 256),
      (name: '2K data as 4K', tag: TagType.mifare4K, blockCount: 128),
    ];

    for (final geometryCase in cases) {
      final card = CardSave(
        uid: '01 02 03 04',
        name: geometryCase.name,
        tag: geometryCase.tag,
        data: List.generate(
          geometryCase.blockCount,
          (_) => Uint8List(16),
        ),
        extraData: CardSaveExtra(mifareClassicDumpComplete: true),
      );

      expect(
        (
          MifareClassicGeometry.fromSavedCardData(card),
          MifareClassicGeometry.fromSavedCard(card),
        ),
        (null, null),
        reason: geometryCase.name,
      );
    }
  });
}
