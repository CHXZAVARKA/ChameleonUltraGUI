import 'dart:convert';
import 'dart:typed_data';

import 'package:chameleonultragui/helpers/card_save_converters.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';

class MifareClassicImportedImage {
  final Uint8List bytes;
  final MifareClassicGeometry geometry;

  MifareClassicImportedImage({
    required Uint8List bytes,
    required this.geometry,
  }) : bytes = Uint8List.fromList(bytes);
}

MifareClassicImportedImage importMifareClassicImage(Uint8List contents) {
  String? source;
  dynamic decodedJson;
  var isJson = false;
  var hasDuplicateProxmark3BlockKey = false;
  try {
    source = const Utf8Decoder().convert(contents);
    hasDuplicateProxmark3BlockKey = _hasDuplicateProxmark3BlockKey(source);
    try {
      decodedJson = jsonDecode(source);
      isJson = true;
    } catch (_) {
      // Existing non-JSON text exports are identified below.
    }
  } on FormatException {
    // Raw dumps can contain arbitrary bytes.
  }

  if (source != null) {
    if (isJson) {
      if (isCardFolderBundleJson(decodedJson)) {
        throw const FormatException('Card folders are not single-card dumps');
      }
      if (decodedJson is Map && decodedJson['Created'] == 'proxmark3') {
        if (hasDuplicateProxmark3BlockKey) {
          throw const FormatException('Duplicate Proxmark3 block');
        }
        return _importProxmark3(source, decodedJson);
      }
      if (decodedJson is Map && decodedJson['data'] is List) {
        return _importNative(source, decodedJson);
      }
      throw const FormatException('Unsupported card dump format');
    }

    final trimmed = source.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      throw const FormatException('Malformed JSON card dump');
    }
    final format = detectCardSaveTextFormat(source);
    switch (format) {
      case CardSaveTextFormat.proxmark3Json:
        throw const FormatException('Malformed Proxmark3 card dump');
      case CardSaveTextFormat.flipperNfc:
        return _importFlipper(source);
      case CardSaveTextFormat.mifareClassicTool:
        return _importMifareClassicTool(source);
      case CardSaveTextFormat.flipperRfid:
        throw const FormatException('Unsupported card dump format');
      case CardSaveTextFormat.nativeJson:
        break;
    }
  }

  final geometry = MifareClassicGeometry.fromImageSize(contents.length);
  if (geometry == null) {
    throw const FormatException('Unsupported card dump format');
  }
  return MifareClassicImportedImage(bytes: contents, geometry: geometry);
}

bool _hasDuplicateProxmark3BlockKey(String source) {
  final blocksObject = RegExp(r'"blocks"\s*:\s*\{').firstMatch(source);
  if (blocksObject == null) {
    return false;
  }

  final keys = <String>{};
  var depth = 1;
  var index = blocksObject.end;
  while (index < source.length && depth > 0) {
    final character = source[index];
    if (character == '"') {
      final stringStart = index;
      var escaped = false;
      index++;
      while (index < source.length) {
        final stringCharacter = source[index];
        if (!escaped && stringCharacter == '"') {
          break;
        }
        escaped = !escaped && stringCharacter == '\\';
        if (stringCharacter != '\\') {
          escaped = false;
        }
        index++;
      }
      if (index >= source.length) {
        return false;
      }

      if (depth == 1) {
        var following = index + 1;
        while (following < source.length &&
            RegExp(r'\s').hasMatch(source[following])) {
          following++;
        }
        if (following < source.length && source[following] == ':') {
          final key = jsonDecode(source.substring(stringStart, index + 1));
          if (key is String && !keys.add(key)) {
            return true;
          }
        }
      }
    } else if (character == '{' || character == '[') {
      depth++;
    } else if (character == '}' || character == ']') {
      depth--;
    }
    index++;
  }
  return false;
}

MifareClassicImportedImage _importNative(
  String source,
  Map<dynamic, dynamic> decoded,
) {
  final extra = decoded['extra'];
  if (extra is! Map || extra['mifareClassicDumpComplete'] != true) {
    throw const FormatException(
      'Native dump has no proven completeness marker',
    );
  }

  final card = cardSaveFromText(
    source,
    format: CardSaveTextFormat.nativeJson,
  );
  final geometry = MifareClassicGeometry.fromSavedCardData(card);
  if (geometry == null) {
    throw const FormatException(
      'Card dump is not a complete supported MIFARE Classic image',
    );
  }
  _validateNativeBlocks(decoded['data'] as List<dynamic>, geometry);
  return _importConvertedCard(card, geometry);
}

MifareClassicImportedImage _importProxmark3(
  String source,
  Map<dynamic, dynamic> decoded,
) {
  final cardMetadata = decoded['Card'];
  final rawBlocks = decoded['blocks'];
  if (cardMetadata is! Map || rawBlocks is! Map) {
    throw const FormatException('Malformed Proxmark3 card dump');
  }
  _requireHex(cardMetadata['UID'], allowedBytes: const {4, 7, 10});
  _requireHex(cardMetadata['SAK'], allowedBytes: const {1});
  _requireHex(cardMetadata['ATQA'], allowedBytes: const {2});

  final geometry = _validateIndexedBlocks(rawBlocks);
  final fileType = decoded['FileType'];
  if (fileType != null &&
      (fileType is! String || fileType.toLowerCase() != 'mfcard')) {
    throw const FormatException('Contradictory Proxmark3 card type');
  }
  _validateCapacityLabels(
    [
      decoded['CardSize'],
      cardMetadata['CardSize'],
      if (cardMetadata['MifareClassic'] is Map)
        (cardMetadata['MifareClassic'] as Map)['CardSize'],
    ],
    geometry,
  );

  final card = cardSaveFromText(
    source,
    format: CardSaveTextFormat.proxmark3Json,
  );
  return _importConvertedCard(card, geometry);
}

MifareClassicImportedImage _importFlipper(String source) {
  final blockEntries = <int, String>{};
  for (final line in const LineSplitter().convert(source)) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('Block')) {
      continue;
    }
    final match = RegExp(r'^Block\s+(\d+):\s*(.*)$').firstMatch(trimmed);
    if (match == null) {
      throw const FormatException('Malformed Flipper block');
    }
    final index = int.parse(match.group(1)!);
    if (blockEntries.containsKey(index)) {
      throw const FormatException('Duplicate Flipper block');
    }
    blockEntries[index] = match.group(2)!;
  }
  final geometry = _validateIndexedBlocks(blockEntries, integerKeys: true);
  _requireMetadataHex(source, 'UID', allowedBytes: const {4, 7, 10});
  _requireMetadataHex(source, 'SAK', allowedBytes: const {1});
  _requireMetadataHex(source, 'ATQA', allowedBytes: const {2});

  for (final value in _metadataValues(source, 'Device type')) {
    if (value.toLowerCase() != 'mifare classic') {
      throw const FormatException('Contradictory Flipper device type');
    }
  }
  _validateCapacityLabels(
    _metadataValues(source, 'Mifare Classic type'),
    geometry,
  );

  final card = cardSaveFromText(
    source,
    format: CardSaveTextFormat.flipperNfc,
  );
  return _importConvertedCard(card, geometry);
}

MifareClassicImportedImage _importMifareClassicTool(String source) {
  final canonicalLines = <String>[];
  var currentSector = -1;
  var blocksInSector = 0;
  var blockCount = 0;

  void finishSector() {
    if (currentSector < 0) {
      return;
    }
    final expected = mfClassicGetBlockCountBySector(currentSector);
    if (blocksInSector != expected) {
      throw const FormatException('Partial MCT sector');
    }
  }

  for (final line in const LineSplitter().convert(source)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    final sectorMatch = RegExp(r'^\+Sector:\s*(\d+)$').firstMatch(trimmed);
    if (sectorMatch != null) {
      finishSector();
      final sector = int.parse(sectorMatch.group(1)!);
      if (sector != currentSector + 1) {
        throw const FormatException('Non-contiguous MCT sectors');
      }
      currentSector = sector;
      blocksInSector = 0;
      canonicalLines.add('+Sector: $sector');
      continue;
    }
    if (currentSector < 0) {
      throw const FormatException('MCT data appears before sector 0');
    }
    _requireHex(trimmed, allowedBytes: const {16});
    blocksInSector++;
    blockCount++;
    canonicalLines.add(trimmed);
  }
  finishSector();
  final geometry = _geometryForBlockCount(blockCount);
  if (currentSector + 1 != geometry.sectorCount) {
    throw const FormatException('Contradictory MCT sector count');
  }

  final card = cardSaveFromText(
    canonicalLines.join('\n'),
    format: CardSaveTextFormat.mifareClassicTool,
  );
  return _importConvertedCard(card, geometry);
}

MifareClassicImportedImage _importConvertedCard(
  CardSave card,
  MifareClassicGeometry expectedGeometry,
) {
  final geometry = MifareClassicGeometry.fromSavedCardData(card);
  if (geometry == null || !_sameGeometry(geometry, expectedGeometry)) {
    throw const FormatException('Card type contradicts dump geometry');
  }
  for (var block = 0; block < geometry.blockCount; block++) {
    if (card.data[block].length != 16) {
      throw const FormatException('Card dump contains a malformed block');
    }
  }
  final bytes = mfClassicGetExportBytes(
    geometry.type,
    card.data,
    isEV1: geometry.isEV1,
  );
  if (bytes.length != geometry.imageSize) {
    throw const FormatException('Card dump has an invalid size');
  }
  return MifareClassicImportedImage(bytes: bytes, geometry: geometry);
}

MifareClassicGeometry _validateIndexedBlocks(
  Map<dynamic, dynamic> blocks, {
  bool integerKeys = false,
}) {
  if (blocks.isEmpty) {
    throw const FormatException('Card dump contains no blocks');
  }
  for (var index = 0; index < blocks.length; index++) {
    final key = integerKeys ? index : index.toString();
    if (blocks.keys.elementAt(index) != key || !blocks.containsKey(key)) {
      throw const FormatException('Card dump blocks are not contiguous');
    }
    _requireHex(blocks[key], allowedBytes: const {16});
  }
  final hasUnexpectedKey = integerKeys
      ? blocks.keys.any((key) => key is! int || key >= blocks.length)
      : blocks.keys.any((key) =>
          key is! String ||
          !RegExp(r'^\d+$').hasMatch(key) ||
          int.parse(key) >= blocks.length);
  if (hasUnexpectedKey) {
    throw const FormatException('Card dump contains unexpected block indices');
  }
  return _geometryForBlockCount(blocks.length);
}

void _validateNativeBlocks(
  List<dynamic> blocks,
  MifareClassicGeometry geometry,
) {
  if (blocks.length < geometry.blockCount) {
    throw const FormatException('Native dump is missing blocks');
  }
  for (var index = 0; index < blocks.length; index++) {
    final block = blocks[index];
    if (block is! List) {
      throw const FormatException('Native dump contains a malformed block');
    }
    final expectedLength = index < geometry.blockCount ? 16 : 0;
    if (block.length != expectedLength ||
        block.any((byte) => byte is! int || byte < 0 || byte > 0xFF)) {
      throw const FormatException('Native dump contains a malformed block');
    }
  }
}

MifareClassicGeometry _geometryForBlockCount(int blockCount) {
  final geometry = MifareClassicGeometry.fromImageSize(blockCount * 16);
  if (geometry == null) {
    throw const FormatException('Unsupported MIFARE Classic geometry');
  }
  return geometry;
}

void _requireMetadataHex(
  String source,
  String name, {
  required Set<int> allowedBytes,
}) {
  final values = _metadataValues(source, name);
  if (values.length != 1) {
    throw FormatException('Missing or duplicate $name metadata');
  }
  _requireHex(values.single, allowedBytes: allowedBytes);
}

List<String> _metadataValues(String source, String name) {
  final expression = RegExp(
    '^${RegExp.escape(name)}:\\s*(.+?)\\s*\$',
    caseSensitive: false,
    multiLine: true,
  );
  return expression
      .allMatches(source)
      .map((match) => match.group(1)!.trim())
      .toList();
}

void _requireHex(dynamic value, {required Set<int> allowedBytes}) {
  if (value is! String) {
    throw const FormatException('Card dump contains non-text hex data');
  }
  final normalized = value.replaceAll(RegExp(r'\s'), '');
  if (!allowedBytes.contains(normalized.length ~/ 2) ||
      normalized.length.isOdd ||
      !RegExp(r'^[0-9a-fA-F]+$').hasMatch(normalized)) {
    throw const FormatException('Card dump contains malformed hex data');
  }
}

void _validateCapacityLabels(
  Iterable<dynamic> labels,
  MifareClassicGeometry geometry,
) {
  for (final label in labels.where((label) => label != null)) {
    if (label is! String) {
      throw const FormatException('Malformed card capacity metadata');
    }
    final normalized = label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final matches = switch (normalized) {
      'mini' || 'mifareclassicmini' => geometry.type == MifareClassicType.mini,
      '1k' || 'mifareclassic1k' => geometry.type == MifareClassicType.m1k,
      '1kev1' ||
      'mifareclassic1kev1' =>
        geometry.type == MifareClassicType.m1k && geometry.isEV1,
      '2k' || 'mifareclassic2k' => geometry.type == MifareClassicType.m2k,
      '4k' || 'mifareclassic4k' => geometry.type == MifareClassicType.m4k,
      _ => false,
    };
    if (!matches) {
      throw const FormatException('Card capacity contradicts dump geometry');
    }
  }
}

bool _sameGeometry(
  MifareClassicGeometry first,
  MifareClassicGeometry second,
) =>
    first.type == second.type &&
    first.isEV1 == second.isEV1 &&
    first.blockCount == second.blockCount &&
    first.sectorCount == second.sectorCount;
