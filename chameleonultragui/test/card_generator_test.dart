import 'dart:math';
import 'dart:typed_data';

import 'package:chameleonultragui/generated/i18n/app_localizations_en.dart';
import 'package:chameleonultragui/helpers/card_generator.dart';
import 'package:chameleonultragui/helpers/card_profile.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/validators.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MIFARE Classic profiles keep UID, SAK, and ATQA coherent', () {
    final generator = CardProfileGenerator(random: Random(71));
    final expected = {
      TagType.mifareMini: (0x09, 0x04),
      TagType.mifare1K: (0x08, 0x04),
      TagType.mifare2K: (0x19, 0x02),
      TagType.mifare4K: (0x18, 0x02),
    };

    for (final entry in expected.entries) {
      for (var attempt = 0; attempt < 20; attempt++) {
        final profile = generator.generate(entry.key);
        expect(profile.sak, entry.value.$1);
        expect(profile.uid.length, anyOf(4, 7));
        expect(profile.atqa![0], 0x00);
        expect(
          profile.atqa![1],
          entry.value.$2 | (profile.uid.length == 7 ? 0x40 : 0x00),
        );
        if (profile.uid.length == 4) {
          expect(profile.uid[0] & 0x0F, 0x0F);
        } else {
          expect(profile.uid[0], 0x04);
          expect(profile.uid[3], isNot(0x88));
        }
      }
    }

    expect(
      generator.generate(TagType.mifare4K, uidLength: 4).atqa,
      [0x00, 0x02],
    );
    expect(
      generator.generate(TagType.mifare4K, uidLength: 7).atqa,
      [0x00, 0x42],
    );
  });

  test('Ultralight and NTAG profiles use Type 2 anticollision values', () {
    final generator = CardProfileGenerator(random: Random(11));
    final versionedTypes = {
      TagType.ultralight11: 0x0B,
      TagType.ultralight21: 0x0E,
      TagType.ntag210: 0x0B,
      TagType.ntag212: 0x0E,
      TagType.ntag213: 0x0F,
      TagType.ntag215: 0x11,
      TagType.ntag216: 0x13,
    };

    for (final type in getTagTypesByFrequency(TagFrequency.hf)) {
      if (!versionedTypes.containsKey(type) &&
          type != TagType.ultralight &&
          type != TagType.ultralightC) {
        continue;
      }
      final profile = generator.generate(type);
      expect(profile.uid.length, 7);
      expect(profile.uid.first, 0x04);
      expect(profile.sak, 0x00);
      expect(profile.atqa, [0x00, 0x44]);
      if (versionedTypes.containsKey(type)) {
        expect(profile.ultralightVersion, hasLength(8));
        expect(profile.ultralightVersion![6], versionedTypes[type]);
      } else {
        expect(profile.ultralightVersion, isNull);
      }
    }
  });

  test('LF profiles preserve their protocol structure', () {
    final generator = CardProfileGenerator(random: Random(29));

    for (final type in getTagTypesByFrequency(TagFrequency.lf)) {
      final profile = generator.generate(type);
      expect(profile.uid.length, uidSizeForLfTag(type), reason: '$type');
    }

    final pac = generator.generate(TagType.pac).uid;
    expect(pac.every((byte) => byte >= 0x30 && byte <= 0x39), isTrue);

    final idteck = generator.generate(TagType.idteck).uid;
    expect(idteck.sublist(0, 4), [0x49, 0x44, 0x54, 0x4B]);
    expect(idteck[4], (idteck[5] + idteck[6] + idteck[7]) & 0xFF);

    final ioProx = generator.generate(TagType.ioProx).uid;
    expect(ioProx.sublist(12), [0, 0, 0, 0]);
    expect(ioProx.sublist(0, 4).every((byte) => byte <= 0xFF), isTrue);

    final hid = generator.generate(TagType.hidProx);
    expect(hid.hidType, 1);
    expect(hid.facilityCode, inInclusiveRange(0, 255));
    expect(hid.issueLevel, 0);
    expect(hid.oem, 0);
  });

  test('HID generation respects every selected firmware format', () {
    final generator = CardProfileGenerator(random: Random(53));

    for (var hidType = 1; hidType <= 30; hidType++) {
      final limits = hidFormatLimits(hidType);
      for (var attempt = 0; attempt < 20; attempt++) {
        final profile = generator.generate(
          TagType.hidProx,
          hidType: hidType,
        );
        final cardNumber = profile.uid.fold<int>(
          0,
          (value, byte) => (value << 8) | byte,
        );

        expect(profile.hidType, hidType);
        expect(cardNumber, inInclusiveRange(0, limits.cardNumber));
        expect(
          profile.facilityCode,
          inInclusiveRange(0, limits.facilityCode),
        );
        expect(profile.issueLevel, inInclusiveRange(0, limits.issueLevel));
        expect(profile.oem, inInclusiveRange(0, limits.oem));
      }
    }
  });

  test('UID validation follows the selected card profile', () {
    final localizations = AppLocalizationsEn();

    expect(
      validateUid('01 02 03 04', localizations, TagType.mifareMini),
      isNull,
    );
    expect(
      validateUid(
        '04 01 02 03 04 05 06',
        localizations,
        TagType.mifareMini,
      ),
      isNotNull,
    );
    expect(
      validateUid(
        '04 01 02 03 04 05 06',
        localizations,
        TagType.ntag215,
      ),
      isNull,
    );
    expect(
      validateUid(
        '01 02 03 04 05 06 07 08 09 0A',
        localizations,
        TagType.mifare4K,
      ),
      isNotNull,
    );
  });

  test('whole-card generation rebuilds memory for the selected geometry', () {
    final generator = CardProfileGenerator(random: Random(41));
    final classic = generator.generate(TagType.mifare4K, uidLength: 7);
    final classicData = generateBlankCardData(
      type: TagType.mifare4K,
      uid: classic.uid,
      sak: classic.sak!,
      atqa: classic.atqa!,
    );

    expect(classicData, hasLength(256));
    expect(classicData.first.sublist(0, 7), classic.uid);
    expect(classicData.last, hasLength(16));

    final ntag = generator.generate(TagType.ntag213);
    final ntagData = generateBlankCardData(
      type: TagType.ntag213,
      uid: ntag.uid,
      sak: ntag.sak!,
      atqa: ntag.atqa!,
    );
    expect(ntagData, hasLength(45));
    expect(ntagData.every((page) => page.length == 4), isTrue);

    expect(
      generateBlankCardData(
        type: TagType.em410X,
        uid: Uint8List(5),
      ),
      isEmpty,
    );
  });
}
