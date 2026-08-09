import 'dart:convert';
import 'dart:typed_data';

import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/mifare_classic/import_image.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final blocks = List.generate(20, (block) {
    final bytes = Uint8List(16);
    if (block == 0) {
      bytes.setRange(0, 4, [1, 2, 3, 4]);
    }
    return bytes;
  });
  final blockHex = blocks.map(_hex).toList();

  test('imports every supported single-card MIFARE Classic format', () {
    final native = CardSave(
      uid: '01020304',
      name: 'Mini',
      tag: TagType.mifareMini,
      extraData: CardSaveExtra(mifareClassicDumpComplete: true),
      data: blocks,
    ).toJson();
    final proxmark = jsonEncode({
      'Created': 'proxmark3',
      'Card': {'UID': '01020304', 'SAK': '09', 'ATQA': '0400'},
      'blocks': {
        for (var block = 0; block < blocks.length; block++)
          '$block': blockHex[block],
      },
    });
    final flipper = [
      'Filetype: Flipper NFC device',
      'UID: 01 02 03 04',
      'SAK: 09',
      'ATQA: 0004',
      for (var block = 0; block < blocks.length; block++)
        'Block $block: ${blockHex[block]}',
    ].join('\n');
    final mct = [
      for (var sector = 0; sector < 5; sector++) ...[
        '+Sector: $sector',
        for (var block = sector * 4; block < sector * 4 + 4; block++)
          blockHex[block],
      ],
    ].join('\n');

    final sources = <String, Uint8List>{
      'raw BIN': Uint8List.fromList(blocks.expand((block) => block).toList()),
      'native GUI JSON': Uint8List.fromList(utf8.encode(native)),
      'Proxmark3 JSON': Uint8List.fromList(utf8.encode(proxmark)),
      'Flipper NFC': Uint8List.fromList(utf8.encode(flipper)),
      'MCT': Uint8List.fromList(utf8.encode(mct)),
    };

    for (final MapEntry(key: name, value: source) in sources.entries) {
      final imported = importMifareClassicImage(source);
      expect(imported.bytes, hasLength(320), reason: name);
      expect(imported.geometry.blockCount, 20, reason: name);
      expect(imported.bytes.sublist(0, 4), [1, 2, 3, 4], reason: name);
    }
  });

  test('rejects folders, partial dumps, and non-Classic cards', () {
    final folder = jsonEncode({
      'format': 'chameleon-ultra-gui-folder',
      'version': 1,
    });
    final partialNative = CardSave(
      uid: '01020304',
      name: 'Partial Mini',
      tag: TagType.mifareMini,
      extraData: CardSaveExtra(mifareClassicDumpComplete: false),
      data: blocks,
    ).toJson();
    final nonClassic = CardSave(
      uid: '01020304',
      name: 'Not Classic',
      tag: TagType.ultralight,
      data: List.generate(16, (_) => Uint8List(4)),
    ).toJson();
    final unknownFlipper = [
      'Filetype: Flipper NFC device',
      'UID: 01 02 03 04',
      'SAK: 09',
      'ATQA: 0004',
      'Block 0: 01020304????????????????????????',
    ].join('\n');

    for (final source in [folder, partialNative, nonClassic, unknownFlipper]) {
      expect(
        () => importMifareClassicImage(Uint8List.fromList(utf8.encode(source))),
        throwsFormatException,
      );
    }
  });
}

String _hex(Uint8List bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
