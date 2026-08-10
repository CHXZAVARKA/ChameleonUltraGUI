import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';

/// Editable UID lengths accepted by the selected emulation profile.
List<int> validUidLengthsForTagType(TagType type) {
  if (isMifareUltralight(type)) return const [7];

  return switch (type) {
    TagType.mifareMini || TagType.mifare2K => const [4],
    TagType.mifare1K || TagType.mifare4K => const [4, 7],
    _ when chameleonTagToFrequency(type) == TagFrequency.lf => [
        uidSizeForLfTag(type),
      ],
    _ => const [4, 7, 10],
  };
}

class HidFormatLimits {
  const HidFormatLimits({
    required this.facilityCode,
    required this.cardNumber,
    required this.issueLevel,
    required this.oem,
  });

  final int facilityCode;
  final int cardNumber;
  final int issueLevel;
  final int oem;
}

/// Limits mirrored from the firmware Wiegand format table.
const _hidFormatLimits = <HidFormatLimits>[
  HidFormatLimits(
      facilityCode: 0xFF, cardNumber: 0xFFFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0xFFF, cardNumber: 0xFFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0x1FFF, cardNumber: 0x3FFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0x1FFF, cardNumber: 0x3FFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0x7FF, cardNumber: 0xFFFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0xFF, cardNumber: 0x7FFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0x1FFF, cardNumber: 0xFFFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0xFFF, cardNumber: 0xFFFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0xF, cardNumber: 0x7FFFFF, issueLevel: 0, oem: 0),
  HidFormatLimits(facilityCode: 0, cardNumber: 0x3FFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0xFFF, cardNumber: 0x7FFFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0xFF, cardNumber: 0xFFFF, issueLevel: 0x1F, oem: 0),
  HidFormatLimits(
      facilityCode: 0xFF, cardNumber: 0xFFFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0xFFF, cardNumber: 0xFFFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0x7F, cardNumber: 0xFFFFFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0xFFFF, cardNumber: 0xFFFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0xFFFF, cardNumber: 0xFFFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0x3FF, cardNumber: 0xFFFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0x3FF, cardNumber: 0xFFFF, issueLevel: 0x7, oem: 0),
  HidFormatLimits(
      facilityCode: 0xFF, cardNumber: 0xFFFFFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0xFFF, cardNumber: 0xFFFFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0xFF, cardNumber: 0xFFFF, issueLevel: 0, oem: 0x3FF),
  HidFormatLimits(
      facilityCode: 0xFF, cardNumber: 0xFFFFFF, issueLevel: 0x3, oem: 0),
  HidFormatLimits(
      facilityCode: 0x3FFFF, cardNumber: 0xFFFF, issueLevel: 0, oem: 0),
  HidFormatLimits(facilityCode: 0, cardNumber: 99999999, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0, cardNumber: 0x7FFFFFFFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0xFFFF, cardNumber: 0x7FFFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0x1FFF, cardNumber: 0x3FFFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0, cardNumber: 0xFFFFFFFF, issueLevel: 0, oem: 0),
  HidFormatLimits(
      facilityCode: 0xF, cardNumber: 0x1FFFFFFF, issueLevel: 0, oem: 0),
];

int get hidFormatCount => _hidFormatLimits.length;

HidFormatLimits hidFormatLimits(int hidType) {
  if (hidType < 1 || hidType > _hidFormatLimits.length) {
    return _hidFormatLimits.first;
  }
  return _hidFormatLimits[hidType - 1];
}
