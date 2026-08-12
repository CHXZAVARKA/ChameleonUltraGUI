import 'dart:typed_data';

import 'package:chameleonultragui/helpers/definitions.dart';

/// Returns the canonical MIFARE Classic anti-collision values for [type] and
/// [uidLength].
///
/// The Chameleon firmware accepts these values independently from the card's
/// memory image. Keeping the profile here prevents generated and saved cards
/// from advertising different identities for the same tag geometry.
({int sak, Uint8List atqa}) mifareClassicAntiCollisionProfile(
  TagType type,
  int uidLength,
) {
  final ({int sak, int atqaLow, List<int> uidLengths})
  baseProfile = switch (type) {
    TagType.mifareMini => (sak: 0x09, atqaLow: 0x04, uidLengths: const [4]),
    TagType.mifare1K => (sak: 0x08, atqaLow: 0x04, uidLengths: const [4, 7]),
    TagType.mifare2K => (sak: 0x19, atqaLow: 0x02, uidLengths: const [4]),
    TagType.mifare4K => (sak: 0x18, atqaLow: 0x02, uidLengths: const [4, 7]),
    _ => throw ArgumentError.value(type, 'type', 'Not MIFARE Classic'),
  };

  if (!baseProfile.uidLengths.contains(uidLength)) {
    throw FormatException('Invalid ${type.name} UID length: $uidLength');
  }

  return (
    sak: baseProfile.sak,
    atqa: Uint8List.fromList([
      0x00,
      baseProfile.atqaLow | (uidLength == 7 ? 0x40 : 0x00),
    ]),
  );
}
