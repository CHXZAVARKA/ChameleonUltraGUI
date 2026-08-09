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

  String native({bool? complete = true, TagType? tag}) {
    return CardSave(
      uid: '01020304',
      name: 'Mini',
      tag: tag ?? TagType.mifareMini,
      extraData: CardSaveExtra(mifareClassicDumpComplete: complete),
      data: blocks,
    ).toJson();
  }

  String proxmark({
    Map<String, String>? sourceBlocks,
    String? cardSize,
  }) {
    return jsonEncode({
      'Created': 'proxmark3',
      'FileType': 'mfcard',
      'Card': {
        'UID': '01020304',
        'SAK': '09',
        'ATQA': '0400',
        if (cardSize != null) 'CardSize': cardSize,
      },
      'blocks': sourceBlocks ??
          {
            for (var block = 0; block < blocks.length; block++)
              '$block': blockHex[block],
          },
    });
  }

  String flipper({
    List<String>? sourceBlocks,
    String deviceType = 'Mifare Classic',
    String cardType = 'Mini',
  }) {
    return [
      'Filetype: Flipper NFC device',
      'Device type: $deviceType',
      'UID: 01 02 03 04',
      'SAK: 09',
      'ATQA: 00 04',
      'Mifare Classic type: $cardType',
      ...?sourceBlocks,
      if (sourceBlocks == null)
        for (var block = 0; block < blocks.length; block++)
          'Block $block: ${blockHex[block]}',
    ].join('\n');
  }

  String mct({List<String>? lines}) {
    return (lines ??
            [
              for (var sector = 0; sector < 5; sector++) ...[
                '+Sector: $sector',
                for (var block = sector * 4; block < sector * 4 + 4; block++)
                  blockHex[block],
              ],
            ])
        .join('\n');
  }

  Uint8List text(String source) => Uint8List.fromList(utf8.encode(source));

  test('imports every existing single-card MIFARE Classic format', () {
    final sources = <String, Uint8List>{
      'raw BIN': Uint8List.fromList(blocks.expand((block) => block).toList()),
      'native GUI JSON': text(native()),
      'Proxmark3 JSON': text(proxmark(cardSize: 'Mini')),
      'Flipper NFC': text(flipper()),
      'MCT': text('${mct()}\n'),
    };

    for (final MapEntry(key: name, value: source) in sources.entries) {
      final imported = importMifareClassicImage(source);
      expect(imported.bytes, hasLength(320), reason: name);
      expect(imported.geometry.blockCount, 20, reason: name);
      expect(imported.bytes.sublist(0, 4), [1, 2, 3, 4], reason: name);
    }
  });

  test('checks structured formats before raw BIN fallback', () {
    final folder = jsonEncode({
      'format': 'chameleon-ultra-gui-folder',
      'version': 1,
    });
    final paddedFolder = folder.padRight(320);
    expect(utf8.encode(paddedFolder), hasLength(320));

    expect(
      () => importMifareClassicImage(text(paddedFolder)),
      throwsFormatException,
    );
  });

  test('native JSON requires proven completeness and exact Classic data', () {
    final legacyJson = jsonDecode(native()) as Map<String, dynamic>;
    (legacyJson['extra'] as Map<String, dynamic>)
        .remove('mifareClassicDumpComplete');
    final malformedJson = jsonDecode(native()) as Map<String, dynamic>;
    (malformedJson['data'] as List<dynamic>)[3] = List<int>.filled(15, 0);

    final rejected = [
      jsonEncode(legacyJson),
      native(complete: false),
      native(tag: TagType.mifare1K),
      jsonEncode(malformedJson),
    ];
    for (final source in rejected) {
      expect(
        () => importMifareClassicImage(text(source)),
        throwsFormatException,
      );
    }
  });

  test('rejects malformed, partial, and contradictory Proxmark3 JSON', () {
    final malformed = {
      for (var block = 0; block < blocks.length; block++)
        '$block': block == 8 ? blockHex[block].substring(2) : blockHex[block],
    };
    final partial = {
      for (var block = 0; block < blocks.length; block++)
        if (block != 8) '$block': blockHex[block],
    };
    final outOfOrder = {
      '1': blockHex[1],
      '0': blockHex[0],
      for (var block = 2; block < blocks.length; block++)
        '$block': blockHex[block],
    };

    for (final source in [
      proxmark(sourceBlocks: malformed),
      proxmark(sourceBlocks: partial),
      proxmark(sourceBlocks: outOfOrder),
      proxmark(cardSize: '1K'),
    ]) {
      expect(
        () => importMifareClassicImage(text(source)),
        throwsFormatException,
      );
    }
  });

  test('rejects duplicate keys in the raw Proxmark3 blocks object', () {
    final source = proxmark(cardSize: 'Mini').replaceFirst(
      '"blocks":{"0":',
      '"blocks":{"7":"${blockHex[7]}","0":',
    );
    expect(
      (jsonDecode(source) as Map<String, dynamic>)['blocks'],
      hasLength(20),
    );

    expect(
      () => importMifareClassicImage(text(source)),
      throwsFormatException,
    );
  });

  test('rejects malformed, partial, and contradictory Flipper NFC', () {
    final validLines = [
      for (var block = 0; block < blocks.length; block++)
        'Block $block: ${blockHex[block]}',
    ];
    final malformed = [...validLines]..[8] = 'Block 8: ?';
    final partial = validLines.where((line) => !line.startsWith('Block 8:'));
    final outOfOrder = [...validLines]
      ..[0] = validLines[1]
      ..[1] = validLines[0];

    for (final source in [
      flipper(sourceBlocks: malformed),
      flipper(sourceBlocks: partial.toList()),
      flipper(sourceBlocks: outOfOrder),
      flipper(cardType: '1K'),
      flipper(deviceType: 'NTAG'),
    ]) {
      expect(
        () => importMifareClassicImage(text(source)),
        throwsFormatException,
      );
    }
  });

  test('rejects malformed, partial, and contradictory MCT data', () {
    final validLines = mct().split('\n');
    final malformed = [...validLines]..[2] = 'not-a-block';
    final partial = [...validLines]..removeAt(2);
    final contradictory = [...validLines]..[5] = '+Sector: 2';

    for (final lines in [malformed, partial, contradictory]) {
      expect(
        () => importMifareClassicImage(text(mct(lines: lines))),
        throwsFormatException,
      );
    }
  });

  test('rejects non-Classic and unknown-byte text exports', () {
    final nonClassic = CardSave(
      uid: '01020304',
      name: 'Not Classic',
      tag: TagType.ultralight,
      extraData: CardSaveExtra(mifareClassicDumpComplete: true),
      data: List.generate(16, (_) => Uint8List(4)),
    ).toJson();
    final unknownFlipper = flipper(
      sourceBlocks: ['Block 0: 01020304????????????????????????'],
    );

    for (final source in [nonClassic, unknownFlipper]) {
      expect(
        () => importMifareClassicImage(text(source)),
        throwsFormatException,
      );
    }
  });
}

String _hex(Uint8List bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
