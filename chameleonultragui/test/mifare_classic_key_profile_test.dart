import 'dart:convert';
import 'dart:typed_data';

import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _key(List<int> bytes) => Uint8List.fromList(bytes);

void main() {
  test('profile exposes exact typed geometry for its wire fields', () {
    final cases = [
      (
        cardType: 'mini',
        sectorCount: 5,
        type: MifareClassicType.mini,
        isEV1: false,
        blockCount: 20,
      ),
      (
        cardType: 'm1k',
        sectorCount: 16,
        type: MifareClassicType.m1k,
        isEV1: false,
        blockCount: 64,
      ),
      (
        cardType: 'm1k',
        sectorCount: 18,
        type: MifareClassicType.m1k,
        isEV1: true,
        blockCount: 72,
      ),
      (
        cardType: 'm2k',
        sectorCount: 32,
        type: MifareClassicType.m2k,
        isEV1: false,
        blockCount: 128,
      ),
      (
        cardType: 'm4k',
        sectorCount: 40,
        type: MifareClassicType.m4k,
        isEV1: false,
        blockCount: 256,
      ),
    ];

    for (final testCase in cases) {
      final profile = MifareClassicKeyProfile(
        name: testCase.cardType,
        cardType: testCase.cardType,
        sectorCount: testCase.sectorCount,
        assignments: const [],
      );
      final importedProfile = MifareClassicKeyProfile.fromJson(
        profile.toJson(),
      );

      expect(importedProfile.geometry?.type, testCase.type);
      expect(importedProfile.geometry?.isEV1, testCase.isEV1);
      expect(importedProfile.geometry?.sectorCount, testCase.sectorCount);
      expect(importedProfile.geometry?.blockCount, testCase.blockCount);
    }
  });

  test('profile wire data rejects impossible card geometries', () {
    const invalidPairs = [
      (cardType: 'mini', sectorCount: 4),
      (cardType: 'mini', sectorCount: 16),
      (cardType: 'm1k', sectorCount: 5),
      (cardType: 'm1k', sectorCount: 17),
      (cardType: 'm2k', sectorCount: 16),
      (cardType: 'm2k', sectorCount: 40),
      (cardType: 'm4k', sectorCount: 32),
      (cardType: 'm4k', sectorCount: 39),
    ];

    for (final invalidPair in invalidPairs) {
      expect(
        () => MifareClassicKeyProfile.fromJson(jsonEncode({
          'format': mifareClassicKeyProfileFormat,
          'version': mifareClassicKeyProfileVersion,
          'id': 'invalid-profile',
          'name': 'Invalid geometry',
          'cardType': invalidPair.cardType,
          'sectorCount': invalidPair.sectorCount,
          'uid': null,
          'keys': const [],
        })),
        throwsFormatException,
        reason: '${invalidPair.cardType}/${invalidPair.sectorCount}',
      );
    }
  });

  test('legacy wire JSON round-trips with identical text and bytes', () {
    const legacyJson =
        '{"format":"chameleon-ultra-gui-mf1-key-profile","version":1,'
        '"id":"legacy-profile","name":"Legacy EV1","cardType":"m1k",'
        '"sectorCount":18,"uid":null,"keys":['
        '{"key":"A0A1A2A3A4A5","keyA":[0,17],"keyB":[17]}]}';

    final profile = MifareClassicKeyProfile.fromJson(legacyJson);

    expect(profile.toJson(), legacyJson);
    expect(profile.toFile(), orderedEquals(utf8.encode(legacyJson)));
    expect(profile.cardType, 'm1k');
    expect(profile.sectorCount, 18);
  });

  test('profile round-trips assigned keys without losing null or zero key', () {
    final profile = MifareClassicKeyProfile(
      id: 'profile-1',
      name: 'Building A',
      cardType: 'm4k',
      sectorCount: 40,
      uid: '01 23 45 67',
      assignments: [
        MifareClassicKeyAssignment(
          sector: 0,
          keyA: _key([0, 0, 0, 0, 0, 0]),
        ),
        MifareClassicKeyAssignment(
          sector: 39,
          keyB: _key([0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5]),
        ),
      ],
    );

    final decoded = MifareClassicKeyProfile.fromJson(profile.toJson());
    final json = jsonDecode(profile.toJson()) as Map<String, dynamic>;
    final compactKeys = json['keys'] as List<dynamic>;
    final zeroKey = compactKeys.firstWhere(
            (entry) => (entry as Map<String, dynamic>)['key'] == '000000000000')
        as Map<String, dynamic>;

    expect(decoded.id, 'profile-1');
    expect(decoded.uid, '01234567');
    expect(decoded.assignedKey(0, 0), orderedEquals([0, 0, 0, 0, 0, 0]));
    expect(decoded.assignedKey(0, 1), isNull);
    expect(decoded.assignedKey(39, 1),
        orderedEquals([0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5]));
    expect(zeroKey['keyA'], [0]);
    expect(zeroKey['keyB'], isEmpty);
  });

  test('compact JSON stores a repeated key once for all assigned sectors', () {
    final repeated = _key([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
    final profile = MifareClassicKeyProfile(
      name: 'Shared key',
      cardType: 'm4k',
      sectorCount: 40,
      assignments: [
        MifareClassicKeyAssignment(sector: 0, keyA: repeated),
        MifareClassicKeyAssignment(sector: 1, keyA: repeated, keyB: repeated),
        MifareClassicKeyAssignment(sector: 39, keyB: repeated),
      ],
    );

    final json = jsonDecode(profile.toJson()) as Map<String, dynamic>;
    final keys = json['keys'] as List<dynamic>;

    expect(keys, hasLength(1));
    expect(keys.single['key'], 'FFFFFFFFFFFF');
    expect(keys.single['keyA'], [0, 1]);
    expect(keys.single['keyB'], [1, 39]);
    final decoded = MifareClassicKeyProfile.fromJson(profile.toJson());
    expect(decoded.keyCount, 1);
    expect(decoded.keyUsages.single.keyHex, 'FFFFFFFFFFFF');
    expect(decoded.keyUsages.single.keyASectors, [0, 1]);
    expect(decoded.keyUsages.single.keyBSectors, [1, 39]);
  });

  test('profile import rejects the unpublished assignments draft', () {
    expect(
      () => MifareClassicKeyProfile.fromJson(jsonEncode({
        'format': mifareClassicKeyProfileFormat,
        'version': mifareClassicKeyProfileVersion,
        'id': 'draft-profile',
        'name': 'Draft',
        'cardType': 'm1k',
        'sectorCount': 16,
        'assignments': [
          {
            'sector': 0,
            'keyA': '010203040506',
            'keyB': null,
          },
        ],
      })),
      throwsFormatException,
    );
  });

  test('assignments are normalized to ascending sector order', () {
    final profile = MifareClassicKeyProfile(
      name: 'Ordered',
      cardType: 'm4k',
      sectorCount: 40,
      assignments: [
        MifareClassicKeyAssignment(sector: 39, keyB: _key([6, 5, 4, 3, 2, 1])),
        MifareClassicKeyAssignment(sector: 0, keyA: _key([1, 2, 3, 4, 5, 6])),
      ],
    );

    expect(profile.assignments.map((assignment) => assignment.sector), [0, 39]);
  });

  test('profile rejects duplicate sectors, bad keys and unrelated JSON', () {
    expect(
      () => MifareClassicKeyProfile(
        name: 'Duplicate',
        cardType: 'm1k',
        sectorCount: 16,
        assignments: [
          MifareClassicKeyAssignment(sector: 0, keyA: _key([1, 2, 3, 4, 5, 6])),
          MifareClassicKeyAssignment(sector: 0, keyB: _key([1, 2, 3, 4, 5, 6])),
        ],
      ),
      throwsFormatException,
    );
    expect(
      () => MifareClassicKeyAssignment(sector: 0, keyA: _key([1, 2, 3, 4, 5])),
      throwsFormatException,
    );
    expect(
      () => MifareClassicKeyProfile.fromJson('{"name":"dictionary"}'),
      throwsFormatException,
    );
    expect(
      () => MifareClassicKeyProfile(
        id: '',
        name: 'Reserved id',
        cardType: 'm1k',
        sectorCount: 16,
        assignments: [
          MifareClassicKeyAssignment(sector: 0, keyA: _key([1, 2, 3, 4, 5, 6])),
        ],
      ),
      throwsFormatException,
    );
    expect(
      () => MifareClassicKeyProfile(
        name: 'Unsupported type',
        cardType: 'desfire',
        sectorCount: 16,
        assignments: [
          MifareClassicKeyAssignment(
            sector: 0,
            keyA: _key([1, 2, 3, 4, 5, 6]),
          ),
        ],
      ),
      throwsFormatException,
    );
  });

  test('profiles persist separately from flat dictionaries', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final profile = MifareClassicKeyProfile(
      id: 'stored-profile',
      name: 'Stored profile',
      cardType: 'm4k',
      sectorCount: 40,
      assignments: [
        MifareClassicKeyAssignment(
          sector: 32,
          keyA: _key([0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5]),
        ),
      ],
    );

    preferences.setMifareClassicKeyProfiles([profile]);

    expect(preferences.getDictionaries(), isEmpty);
    expect(
        preferences.getMifareClassicKeyProfiles().single.id, 'stored-profile');
  });

  test('generic settings export excludes assigned key profiles', () async {
    SharedPreferences.setMockInitialValues({'app_theme': 2});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final profile = MifareClassicKeyProfile(
      id: 'private-profile',
      name: 'Private profile',
      cardType: 'm1k',
      sectorCount: 16,
      uid: '01020304',
      assignments: [
        MifareClassicKeyAssignment(
          sector: 0,
          keyA: _key([0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5]),
        ),
      ],
    );
    preferences.setMifareClassicKeyProfiles([profile]);

    final exported =
        jsonDecode(preferences.dumpSettingsToJson()) as Map<String, dynamic>;

    expect(exported['app_theme'], 2);
    expect(exported, isNot(contains('mifare_classic_key_profiles')));
    expect(preferences.getMifareClassicKeyProfiles(), hasLength(1));
  });

  test('generic settings import cannot overwrite assigned key profiles',
      () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = SharedPreferencesProvider();
    await preferences.load();
    final stored = MifareClassicKeyProfile(
      id: 'stored-profile',
      name: 'Stored profile',
      cardType: 'm1k',
      sectorCount: 16,
      assignments: [
        MifareClassicKeyAssignment(
          sector: 0,
          keyA: _key([1, 2, 3, 4, 5, 6]),
        ),
      ],
    );
    final injected = MifareClassicKeyProfile(
      id: 'injected-profile',
      name: 'Injected profile',
      cardType: 'm1k',
      sectorCount: 16,
      assignments: [
        MifareClassicKeyAssignment(
          sector: 0,
          keyA: _key([6, 5, 4, 3, 2, 1]),
        ),
      ],
    );
    preferences.setMifareClassicKeyProfiles([stored]);

    preferences.restoreSettingsFromJson(jsonEncode({
      'app_theme': 2,
      'mifare_classic_key_profiles': [jsonDecode(injected.toJson())],
    }));

    expect(
        preferences.getMifareClassicKeyProfiles().single.id, 'stored-profile');
  });

  test('a corrupt stored profile does not hide valid profiles', () async {
    final valid = MifareClassicKeyProfile(
      id: 'valid-profile',
      name: 'Valid profile',
      cardType: 'm1k',
      sectorCount: 16,
      assignments: [
        MifareClassicKeyAssignment(sector: 0, keyA: _key([1, 2, 3, 4, 5, 6])),
      ],
    );
    SharedPreferences.setMockInitialValues({
      'mifare_classic_key_profiles': ['not json', valid.toJson()],
    });
    final preferences = SharedPreferencesProvider();
    await preferences.load();

    expect(
        preferences.getMifareClassicKeyProfiles().single.id, 'valid-profile');
  });
}
