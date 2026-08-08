import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';
import 'package:chameleonultragui/helpers/mifare_classic/recovery.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';

void main() {
  test('profile includes only found slots with six-byte keys', () async {
    final appState = ChameleonGUIState(SharedPreferencesProvider());
    final localizations =
        await AppLocalizations.delegate.load(const Locale('en'));
    final checkMarks =
        List.filled(80, ChameleonKeyCheckmark.none, growable: false);
    final validKeys = List.generate(80, (_) => Uint8List(0), growable: false);
    checkMarks[0] = ChameleonKeyCheckmark.found;
    validKeys[0] = Uint8List.fromList([1, 2, 3, 4, 5, 6]);
    validKeys[1] = Uint8List.fromList([6, 5, 4, 3, 2, 1]);
    checkMarks[40] = ChameleonKeyCheckmark.found;

    final recovery = MifareClassicRecovery(
      appState: appState,
      update: () {},
      localizations: localizations,
      mifareClassicType: MifareClassicType.m1k,
      checkMarks: checkMarks,
      validKeys: validKeys,
    );

    expect(recovery.hasVerifiedKeys, isTrue);
    final profile = recovery.createKeyProfile(name: 'Live keys');
    expect(profile.keyCount, 1);
    expect(profile.assignedKey(0, 0), orderedEquals([1, 2, 3, 4, 5, 6]));
    expect(profile.assignedKey(1, 0), isNull);
    expect(profile.assignedKey(0, 1), isNull);
  });

  test('EV1 signature defaults are exported only after live authentication',
      () async {
    final communicator = _RecordingCommunicator(
      acceptedSingleKey: gMifareClassicKeys[3],
      acceptedDictionaryKey: gMifareClassicKeys[3],
      acceptAllSingleKeys: true,
    );
    final appState = ChameleonGUIState(SharedPreferencesProvider())
      ..communicator = communicator
      ..connector = _TestSerial(log: Logger())
      ..log = Logger();
    final localizations =
        await AppLocalizations.delegate.load(const Locale('en'));
    final checkMarks =
        List.filled(80, ChameleonKeyCheckmark.disabled, growable: false);
    final recovery = MifareClassicRecovery(
      appState: appState,
      update: () {},
      localizations: localizations,
      mifareClassicType: MifareClassicType.m1k,
      isMifareClassicEV1: true,
      checkMarks: checkMarks,
    );

    expect(recovery.getSectorState(16, 0), ChameleonKeyCheckmark.disabled);
    expect(recovery.getSectorKey(16, 0), isEmpty);
    expect(recovery.hasVerifiedKeys, isFalse);
    expect(
      () => recovery.createKeyProfile(name: 'EV1 defaults'),
      throwsFormatException,
    );

    await recovery.checkKeys(skipDefaultDictionary: true);
    final profile = recovery.createKeyProfile(name: 'Verified EV1');

    expect(
        profile.assignments.map((assignment) => assignment.sector), [16, 17]);
    expect(profile.keyCount, 4);
    expect(communicator.calls, [
      'single:67:96:5C8FF9990DA2',
      'single:67:97:D01AFEEB890A',
      'single:71:96:75CCB59C9BED',
      'single:71:97:4B791BEA7BCC',
    ]);
  });

  test('rechecking EV1 preserves a verified alternative signature key',
      () async {
    final alternativeKey = Uint8List.fromList([1, 2, 3, 4, 5, 6]);
    final communicator = _RecordingCommunicator(
      acceptedSingleKey: alternativeKey,
      acceptedDictionaryKey: alternativeKey,
    );
    final appState = ChameleonGUIState(SharedPreferencesProvider())
      ..communicator = communicator
      ..connector = _TestSerial(log: Logger())
      ..log = Logger();
    final localizations =
        await AppLocalizations.delegate.load(const Locale('en'));
    final recovery = MifareClassicRecovery(
      appState: appState,
      update: () {},
      localizations: localizations,
      mifareClassicType: MifareClassicType.m1k,
      isMifareClassicEV1: true,
      checkMarks:
          List.filled(80, ChameleonKeyCheckmark.disabled, growable: false),
      selectedKeyProfile: MifareClassicKeyProfile(
        name: 'Alternative EV1 key',
        cardType: 'm1k',
        sectorCount: 18,
        assignments: [
          MifareClassicKeyAssignment(sector: 16, keyA: alternativeKey),
        ],
      ),
    );

    await recovery.checkKeys(skipDefaultDictionary: true);
    expect(recovery.getSectorKey(16, 0), orderedEquals(alternativeKey));

    communicator.calls.clear();
    await recovery.checkKeys(skipDefaultDictionary: true);

    expect(recovery.getSectorKey(16, 0), orderedEquals(alternativeKey));
    expect(
      recovery
          .createKeyProfile(name: 'Verified alternative')
          .assignments
          .single
          .keyA,
      orderedEquals(alternativeKey),
    );
    expect(
      communicator.calls,
      [
        'single:67:97:D01AFEEB890A',
        'single:71:96:75CCB59C9BED',
        'single:71:97:4B791BEA7BCC',
      ],
    );
  });

  test(
      'assigned profile is checked first and dictionary fills unresolved slots',
      () async {
    final profileA = Uint8List.fromList([1, 2, 3, 4, 5, 6]);
    final wrongProfileB = Uint8List.fromList([6, 5, 4, 3, 2, 1]);
    final dictionaryKey =
        Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
    final communicator = _RecordingCommunicator(
      acceptedSingleKey: profileA,
      acceptedDictionaryKey: dictionaryKey,
    );
    final appState = ChameleonGUIState(SharedPreferencesProvider())
      ..communicator = communicator
      ..connector = _TestSerial(log: Logger())
      ..log = Logger();
    final checkMarks =
        List.filled(80, ChameleonKeyCheckmark.disabled, growable: false);
    checkMarks[0] = ChameleonKeyCheckmark.none;
    checkMarks[40 + 1] = ChameleonKeyCheckmark.none;
    final localizations =
        await AppLocalizations.delegate.load(const Locale('en'));
    final recovery = MifareClassicRecovery(
      appState: appState,
      update: () {},
      localizations: localizations,
      mifareClassicType: MifareClassicType.m1k,
      checkMarks: checkMarks,
      selectedDictionary: Dictionary(
        id: 'dictionary',
        name: 'Fallback',
        keys: [dictionaryKey],
        keyLength: 12,
      ),
      selectedKeyProfile: MifareClassicKeyProfile(
        name: 'Assigned',
        cardType: 'm1k',
        sectorCount: 16,
        assignments: [
          MifareClassicKeyAssignment(sector: 0, keyA: profileA),
          MifareClassicKeyAssignment(sector: 1, keyB: wrongProfileB),
        ],
      ),
    );

    await recovery.checkKeys(skipDefaultDictionary: true);

    expect(communicator.calls, [
      'single:3:96:010203040506',
      'single:7:97:060504030201',
      'multiple:7:97:FFFFFFFFFFFF',
    ]);
    expect(recovery.getSectorKey(0, 0), orderedEquals(profileA));
    expect(recovery.getSectorKey(1, 1), orderedEquals(dictionaryKey));
    expect(recovery.allKeysExists, isTrue);
  });

  test('device errors do not fall through to dictionary key scanning',
      () async {
    final profileKey = Uint8List.fromList([1, 2, 3, 4, 5, 6]);
    final dictionaryKey = Uint8List.fromList(List.filled(6, 0xFF));
    final communicator = _RecordingCommunicator(
      acceptedSingleKey: profileKey,
      acceptedDictionaryKey: dictionaryKey,
      forcedSingleStatus: 0x66,
    );
    final appState = ChameleonGUIState(SharedPreferencesProvider())
      ..communicator = communicator
      ..connector = _TestSerial(log: Logger())
      ..log = Logger();
    final checkMarks =
        List.filled(80, ChameleonKeyCheckmark.disabled, growable: false);
    checkMarks[0] = ChameleonKeyCheckmark.none;
    final localizations =
        await AppLocalizations.delegate.load(const Locale('en'));
    final recovery = MifareClassicRecovery(
      appState: appState,
      update: () {},
      localizations: localizations,
      mifareClassicType: MifareClassicType.m1k,
      checkMarks: checkMarks,
      selectedDictionary: Dictionary(
        id: 'dictionary',
        name: 'Fallback',
        keys: [dictionaryKey],
        keyLength: 12,
      ),
      selectedKeyProfile: MifareClassicKeyProfile(
        name: 'Assigned',
        cardType: 'm1k',
        sectorCount: 16,
        assignments: [
          MifareClassicKeyAssignment(sector: 0, keyA: profileKey),
        ],
      ),
    );

    await expectLater(
      recovery.checkKeys(skipDefaultDictionary: true),
      throwsStateError,
    );
    expect(communicator.calls, ['single:3:96:010203040506']);
  });
}

class _RecordingCommunicator extends ChameleonCommunicator {
  final Uint8List acceptedSingleKey;
  final Uint8List acceptedDictionaryKey;
  final int? forcedSingleStatus;
  final bool acceptAllSingleKeys;
  final List<String> calls = [];

  _RecordingCommunicator({
    required this.acceptedSingleKey,
    required this.acceptedDictionaryKey,
    this.forcedSingleStatus,
    this.acceptAllSingleKeys = false,
  }) : super(Logger());

  String _hex(Uint8List value) => value
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();

  @override
  Future<ChameleonMessage> mf1AuthResult(
      int block, int keyType, Uint8List key) async {
    calls.add('single:$block:$keyType:${_hex(key)}');
    return ChameleonMessage(
      command: ChameleonCommand.mf1CheckKey.value,
      status: forcedSingleStatus ??
          (acceptAllSingleKeys || _hex(key) == _hex(acceptedSingleKey)
              ? 0
              : 0x06),
      data: Uint8List(0),
    );
  }

  @override
  Future<Uint8List?> mf1AuthMultipleKeys(
      int block, int keyType, List<Uint8List> keys) async {
    calls.add('multiple:$block:$keyType:${keys.map(_hex).join(',')}');
    return keys.any((key) => _hex(key) == _hex(acceptedDictionaryKey))
        ? acceptedDictionaryKey
        : null;
  }
}

class _TestSerial extends AbstractSerial {
  _TestSerial({required super.log}) {
    connectionType = ConnectionType.usb;
    connected = true;
  }

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => [];

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => true;

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => true;
}
