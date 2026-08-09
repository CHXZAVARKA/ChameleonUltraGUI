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
  final rawGeometry = MifareClassicGeometry.fromImageSize(contents.length);
  if (rawGeometry != null) {
    return MifareClassicImportedImage(
      bytes: contents,
      geometry: rawGeometry,
    );
  }

  final source = const Utf8Decoder().convert(contents);
  dynamic decodedJson;
  try {
    decodedJson = jsonDecode(source);
  } catch (_) {
    // Text exports are handled by their existing format converters below.
  }
  if (decodedJson is Map &&
      decodedJson['format'] == 'chameleon-ultra-gui-folder') {
    throw const FormatException('Card folders are not single-card dumps');
  }

  final CardSave card;
  final isNativeCard = decodedJson is Map && decodedJson['data'] is List;
  if (decodedJson is Map && decodedJson['Created'] == 'proxmark3') {
    card = pm3JsonToCardSave(source);
  } else if (source.contains('Filetype: Flipper NFC device')) {
    if (source.contains('?')) {
      throw const FormatException('Flipper dump contains unknown bytes');
    }
    card = flipperNfcToCardSave(source);
  } else if (source.contains('+Sector: 0')) {
    if (source.contains('?')) {
      throw const FormatException('MCT dump contains unknown bytes');
    }
    card = mctToCardSave(source);
  } else if (isNativeCard) {
    card = CardSave.fromJson(source);
    if (card.extraData.mifareClassicDumpComplete == false) {
      throw const FormatException('Native dump is marked as incomplete');
    }
  } else {
    throw const FormatException('Unsupported card dump format');
  }

  final geometry = MifareClassicGeometry.fromSavedCardData(card);
  if (geometry == null) {
    throw const FormatException(
      'Card dump is not a complete supported MIFARE Classic image',
    );
  }
  return MifareClassicImportedImage(
    bytes: mfClassicGetExportBytes(
      geometry.type,
      card.data,
      isEV1: geometry.isEV1,
    ),
    geometry: geometry,
  );
}
