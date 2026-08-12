import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/mifare_classic/anti_collision.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('returns every supported MIFARE Classic anti-collision profile', () {
    final cases = <({TagType type, int uidLength, int sak, List<int> atqa})>[
      (
        type: TagType.mifareMini,
        uidLength: 4,
        sak: 0x09,
        atqa: const [0x00, 0x04],
      ),
      (
        type: TagType.mifare1K,
        uidLength: 4,
        sak: 0x08,
        atqa: const [0x00, 0x04],
      ),
      (
        type: TagType.mifare1K,
        uidLength: 7,
        sak: 0x08,
        atqa: const [0x00, 0x44],
      ),
      (
        type: TagType.mifare2K,
        uidLength: 4,
        sak: 0x19,
        atqa: const [0x00, 0x02],
      ),
      (
        type: TagType.mifare4K,
        uidLength: 4,
        sak: 0x18,
        atqa: const [0x00, 0x02],
      ),
      (
        type: TagType.mifare4K,
        uidLength: 7,
        sak: 0x18,
        atqa: const [0x00, 0x42],
      ),
    ];

    for (final testCase in cases) {
      final profile = mifareClassicAntiCollisionProfile(
        testCase.type,
        testCase.uidLength,
      );

      expect(profile.sak, testCase.sak, reason: '${testCase.type}');
      expect(profile.atqa, testCase.atqa, reason: '${testCase.type}');
    }
  });

  test('rejects UID lengths that the selected Classic profile cannot use', () {
    for (final testCase in [
      (type: TagType.mifareMini, uidLength: 7),
      (type: TagType.mifare1K, uidLength: 10),
      (type: TagType.mifare2K, uidLength: 7),
      (type: TagType.mifare4K, uidLength: 10),
    ]) {
      expect(
        () => mifareClassicAntiCollisionProfile(
          testCase.type,
          testCase.uidLength,
        ),
        throwsA(isA<FormatException>()),
        reason: '${testCase.type}',
      );
    }
  });

  test('rejects non-Classic tag types', () {
    expect(
      () => mifareClassicAntiCollisionProfile(TagType.ntag213, 7),
      throwsArgumentError,
    );
  });
}
