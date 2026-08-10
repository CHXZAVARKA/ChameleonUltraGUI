import 'dart:math';
import 'dart:typed_data';

import 'package:chameleonultragui/helpers/card_profile.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';

/// A coherent set of editable identity fields for one supported tag type.
///
/// This deliberately excludes manufacturer signatures and ATS values: random
/// bytes in those fields would look plausible while being cryptographically or
/// protocol-invalid.
class GeneratedCardProfile {
  const GeneratedCardProfile({
    required this.uid,
    this.sak,
    this.atqa,
    this.ultralightVersion,
    this.hidType,
    this.facilityCode,
    this.issueLevel,
    this.oem,
  });

  final Uint8List uid;
  final int? sak;
  final Uint8List? atqa;
  final Uint8List? ultralightVersion;
  final int? hidType;
  final int? facilityCode;
  final int? issueLevel;
  final int? oem;
}

/// Generates values that match the selected card's on-air format.
///
/// The defaults mirror the tag profiles supported by Chameleon Ultra firmware.
/// A [Random] can be injected to make the output deterministic in tests.
class CardProfileGenerator {
  CardProfileGenerator({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  int generateUltralightCounter() => _random.nextInt(0x1000000);

  GeneratedCardProfile generate(
    TagType type, {
    int? uidLength,
    int? hidType,
  }) {
    if (isMifareClassic(type)) {
      return _generateMifareClassic(type, uidLength: uidLength);
    }
    if (isMifareUltralight(type)) {
      return GeneratedCardProfile(
        uid: _nxpSevenByteUid(),
        sak: 0x00,
        atqa: Uint8List.fromList(const [0x00, 0x44]),
        ultralightVersion: _ultralightVersion(type),
      );
    }
    return _generateLf(type, hidType: hidType);
  }

  GeneratedCardProfile _generateMifareClassic(
    TagType type, {
    int? uidLength,
  }) {
    final supportsSevenByteUid = validUidLengthsForTagType(type).contains(7);
    final useSevenByteUid = supportsSevenByteUid &&
        (uidLength == 7 || (uidLength == null && _random.nextBool()));
    final uid = useSevenByteUid ? _nxpSevenByteUid() : _fixedNonUniqueUid();

    final (sak, atqaLow) = switch (type) {
      TagType.mifareMini => (0x09, 0x04),
      TagType.mifare1K => (0x08, 0x04),
      TagType.mifare2K => (0x19, 0x02),
      TagType.mifare4K => (0x18, 0x02),
      _ => throw ArgumentError.value(type, 'type', 'Not MIFARE Classic'),
    };

    return GeneratedCardProfile(
      uid: uid,
      sak: sak,
      atqa: Uint8List.fromList([
        0x00,
        useSevenByteUid ? atqaLow | 0x40 : atqaLow,
      ]),
    );
  }

  GeneratedCardProfile _generateLf(TagType type, {int? hidType}) {
    switch (type) {
      case TagType.hidProx:
        return _generateHid(hidType ?? 1);
      case TagType.pac:
        return GeneratedCardProfile(
          uid: Uint8List.fromList(
            List.generate(8, (_) => 0x30 + _random.nextInt(10)),
          ),
        );
      case TagType.ioProx:
        return GeneratedCardProfile(uid: _ioProxData());
      case TagType.idteck:
        return GeneratedCardProfile(uid: _idteckFrame());
      case TagType.em410X:
      case TagType.em410X16:
      case TagType.em410X32:
      case TagType.em410X64:
      case TagType.em410XElectra:
      case TagType.viking:
        return GeneratedCardProfile(
          uid: _randomBytes(uidSizeForLfTag(type)),
        );
      default:
        throw ArgumentError.value(type, 'type', 'Unsupported tag type');
    }
  }

  GeneratedCardProfile _generateHid(int hidType) {
    final limits = hidFormatLimits(hidType);
    final cardNumber = _randomInt(limits.cardNumber);
    return GeneratedCardProfile(
      uid: Uint8List.fromList([
        (cardNumber >> 32) & 0xFF,
        (cardNumber >> 24) & 0xFF,
        (cardNumber >> 16) & 0xFF,
        (cardNumber >> 8) & 0xFF,
        cardNumber & 0xFF,
      ]),
      hidType: hidType,
      facilityCode: _randomInt(limits.facilityCode),
      issueLevel: _randomInt(limits.issueLevel),
      oem: _randomInt(limits.oem),
    );
  }

  int _randomInt(int inclusiveMax) {
    if (inclusiveMax == 0) return 0;

    final bitLength = inclusiveMax.bitLength;
    while (true) {
      var value = 0;
      for (var shift = 0; shift < bitLength; shift += 16) {
        final chunkBits = min(16, bitLength - shift);
        value |= _random.nextInt(1 << chunkBits) << shift;
      }
      if (value <= inclusiveMax) return value;
    }
  }

  Uint8List _fixedNonUniqueUid() {
    final uid = _randomBytes(4);
    uid[0] = (uid[0] & 0xF0) | 0x0F;
    return uid;
  }

  Uint8List _nxpSevenByteUid() {
    final uid = _randomBytes(7);
    uid[0] = 0x04;
    while (uid[3] == 0x88) {
      uid[3] = _random.nextInt(0x100);
    }
    return uid;
  }

  Uint8List? _ultralightVersion(TagType type) {
    final (productType, subtype, storageSize) = switch (type) {
      TagType.ultralight11 => (0x03, 0x02, 0x0B),
      TagType.ultralight21 => (0x03, 0x02, 0x0E),
      TagType.ntag210 => (0x04, 0x01, 0x0B),
      TagType.ntag212 => (0x04, 0x01, 0x0E),
      TagType.ntag213 => (0x04, 0x02, 0x0F),
      TagType.ntag215 => (0x04, 0x02, 0x11),
      TagType.ntag216 => (0x04, 0x02, 0x13),
      _ => (-1, -1, -1),
    };
    if (productType < 0) return null;
    return Uint8List.fromList([
      0x00,
      0x04,
      productType,
      subtype,
      0x01,
      0x00,
      storageSize,
      0x03,
    ]);
  }

  Uint8List _ioProxData() {
    final version = _random.nextInt(0x100);
    final facility = _random.nextInt(0x100);
    final number = _random.nextInt(0x10000);
    final payload = [0xF0, facility, version, number >> 8, number & 0xFF];
    final checksum =
        0xFF - (payload.fold<int>(0, (sum, byte) => sum + byte) & 0xFF);
    final framed = [0x00, ...payload, checksum];
    final bits = <int>[];
    for (var i = 0; i < framed.length; i++) {
      final byte = framed[i];
      for (var bit = 7; bit >= 0; bit--) {
        bits.add((byte >> bit) & 1);
      }
      bits.add(i == 0 ? 0 : 1);
    }
    bits.add(1);

    final raw = Uint8List(8);
    for (var i = 0; i < 64; i++) {
      raw[i ~/ 8] |= bits[i] << (7 - (i % 8));
    }
    return Uint8List.fromList([
      version,
      facility,
      number >> 8,
      number & 0xFF,
      ...raw,
      0x00,
      0x00,
      0x00,
      0x00,
    ]);
  }

  Uint8List _idteckFrame() {
    final cardId = _random.nextInt(0x1000000);
    final low = cardId & 0xFF;
    final middle = (cardId >> 8) & 0xFF;
    final high = (cardId >> 16) & 0xFF;
    final checksum = (low + middle + high) & 0xFF;
    return Uint8List.fromList([
      0x49,
      0x44,
      0x54,
      0x4B,
      checksum,
      low,
      middle,
      high,
    ]);
  }

  Uint8List _randomBytes(int length) =>
      Uint8List.fromList(List.generate(length, (_) => _random.nextInt(0x100)));
}

String generatedHex(Uint8List? bytes) =>
    bytes == null ? '' : bytesToHexSpace(bytes);

/// Builds neutral, internally consistent memory for a newly generated card.
List<Uint8List> generateBlankCardData({
  required TagType type,
  required Uint8List uid,
  int sak = 0,
  Uint8List? atqa,
}) {
  if (chameleonTagToFrequency(type) == TagFrequency.lf) return [];

  if (isMifareUltralight(type)) {
    final blocks = mfUltralightGenerateFirstBlocks(uid, type);
    final cc = Uint8List.fromList([
      0xE1,
      0x10,
      (getMemorySizeForTagType(type) ~/ 8) & 0xFF,
      0x00,
    ]);
    blocks.add(cc);
    while (blocks.length < getBlockCountForTagType(type)) {
      blocks.add(Uint8List(4));
    }
    return blocks;
  }

  if (isMifareClassic(type)) {
    final blocks = <Uint8List>[];
    for (var sector = 0;
        sector <
            mfClassicGetSectorCount(chameleonTagTypeGetMfClassicType(type));
        sector++) {
      for (var block = 0;
          block < mfClassicGetBlockCountBySector(sector) - 1;
          block++) {
        blocks.add(Uint8List(16));
      }
      blocks.add(
        Uint8List.fromList(const [
          0xFF,
          0xFF,
          0xFF,
          0xFF,
          0xFF,
          0xFF,
          0xFF,
          0x07,
          0x80,
          0x69,
          0xFF,
          0xFF,
          0xFF,
          0xFF,
          0xFF,
          0xFF,
        ]),
      );
    }
    blocks[0] = mfClassicGenerateFirstBlock(
      uid,
      sak,
      atqa ?? Uint8List(2),
    );
    return blocks;
  }

  return [];
}
