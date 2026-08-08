import 'dart:convert';
import 'dart:typed_data';

import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _key(List<int> bytes) => Uint8List.fromList(bytes);

void main() {
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

  test('runtime A and B slots preserve their sector assignments', () {
    final keys = List.generate(80, (_) => Uint8List(0));
    final verified = List.filled(80, false);
    keys[0] = _key([1, 2, 3, 4, 5, 6]);
    verified[0] = true;
    keys[40 + 39] = _key([6, 5, 4, 3, 2, 1]);
    verified[40 + 39] = true;

    final profile = MifareClassicKeyProfile.fromVerifiedRuntimeKeys(
      name: 'Mapped keys',
      cardType: 'm4k',
      sectorCount: 40,
      validKeys: keys,
      isVerified: verified,
    );

    expect(profile.assignments.map((entry) => entry.sector), [0, 39]);
    expect(profile.assignedKey(0, 0), orderedEquals([1, 2, 3, 4, 5, 6]));
    expect(profile.assignedKey(0, 1), isNull);
    expect(profile.assignedKey(39, 0), isNull);
    expect(profile.assignedKey(39, 1), orderedEquals([6, 5, 4, 3, 2, 1]));
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
    expect(decoded.keyCount, 4);
    expect(decoded.keyUsages.single.keyHex, 'FFFFFFFFFFFF');
    expect(decoded.keyUsages.single.keyASectors, [0, 1]);
    expect(decoded.keyUsages.single.keyBSectors, [1, 39]);
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
