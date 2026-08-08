import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/recovery/recovery.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';

// Recovery
import 'package:chameleonultragui/recovery/recovery.dart' as recovery;

extension PartitionList<E> on List<E> {
  List<List<E>> partition(int size) {
    assert(size > 0);
    final out = <List<E>>[];
    for (var i = 0; i < length; i += size) {
      final end = i + size < length ? i + size : length;
      out.add(sublist(i, end));
    }
    return out;
  }
}

enum ChameleonKeyCheckmark { none, found, checking, disabled }

class _RecoveryOperationCancelled implements Exception {
  const _RecoveryOperationCancelled();
}

class _RecoveryOperation {
  final ConnectedDeviceSession session;

  const _RecoveryOperation(this.session);

  ChameleonCommunicator get communicator => session.communicator;

  bool get isCurrent => session.isCurrent;

  void ensureCurrent() {
    if (!isCurrent) {
      throw const _RecoveryOperationCancelled();
    }
  }

  Future<T> waitFor<T>(Future<T> future) async {
    try {
      return await future;
    } finally {
      ensureCurrent();
    }
  }
}

class MifareClassicRecovery {
  late ChameleonGUIState appState;
  late AppLocalizations localizations;
  String error;
  String state;
  bool allKeysExists;
  bool dumpComplete;
  List<Dictionary> dictionaries;
  Dictionary? selectedDictionary;
  List<MifareClassicKeyProfile> keyProfiles;
  MifareClassicKeyProfile? selectedKeyProfile;
  List<ChameleonKeyCheckmark> checkMarks;
  List<Uint8List> validKeys;
  List<Uint8List> cardData;
  double dumpProgress;
  double? hardnestedProgress;
  double? keyCheckProgress;
  void Function() update;
  MifareClassicType mifareClassicType;
  bool isMifareClassicEV1;

  MifareClassicRecovery(
      {required this.appState,
      required this.update,
      required this.localizations,
      this.error = '',
      this.state = '',
      this.allKeysExists = false,
      this.dumpComplete = false,
      this.dictionaries = const [],
      this.keyProfiles = const [],
      this.dumpProgress = 0,
      this.selectedDictionary,
      this.selectedKeyProfile,
      this.mifareClassicType = MifareClassicType.none,
      this.isMifareClassicEV1 = false,
      List<ChameleonKeyCheckmark>? checkMarks,
      List<Uint8List>? validKeys,
      List<Uint8List>? cardData})
      : checkMarks =
            checkMarks ?? List.generate(80, (_) => ChameleonKeyCheckmark.none),
        validKeys = validKeys ?? List.generate(80, (_) => Uint8List(0)),
        cardData = cardData ?? List.generate(256, (_) => Uint8List(0));

  _RecoveryOperation? _captureOperation() {
    final session = ConnectedDeviceSession.capture(appState);
    return session == null ? null : _RecoveryOperation(session);
  }

  Future<bool> _completeOperation(
      _RecoveryOperation operation, Future<void> future) async {
    try {
      await future;
      operation.ensureCurrent();
      return true;
    } on _RecoveryOperationCancelled {
      return false;
    }
  }

  Future<bool> checkKeysOnSector(
      List<Uint8List> keys, int keyType, int sector) async {
    final operation = _captureOperation();
    if (operation == null) {
      return false;
    }
    try {
      return await operation
          .waitFor(_checkKeysOnSector(keys, keyType, sector, operation));
    } on _RecoveryOperationCancelled {
      return false;
    }
  }

  Future<bool> _checkKeysOnSector(List<Uint8List> keys, int keyType, int sector,
      _RecoveryOperation operation) async {
    state = localizations.checking_keys(keys.length);
    Uint8List? key;
    keyCheckProgress = null;
    int chunkSize =
        operation.session.connector.connectionType == ConnectionType.ble
            ? 32
            : 64;

    if (getSectorState(sector, keyType) != ChameleonKeyCheckmark.found &&
        getSectorState(sector, keyType) != ChameleonKeyCheckmark.disabled) {
      setCheckingSector(sector, keyType);
      int totalChunks = keys.partition(chunkSize).length;

      for (var chunk in keys.partition(chunkSize)) {
        key = await operation.waitFor(operation.communicator
            .mf1AuthMultipleKeys(mfClassicGetSectorTrailerBlockBySector(sector),
                0x60 + keyType, chunk));
        if (key != null) {
          setKeyAsFound(sector, keyType, key);
          keyCheckProgress = null;
          await operation.waitFor(_recheckKey(key, sector, operation));
          return true;
        } else if (totalChunks > 10) {
          keyCheckProgress = (keyCheckProgress ?? 0) + 1 / totalChunks;
          update();
        }
      }

      if (key == null) {
        setMissingSector(sector, keyType);
      }
    }

    setMissingSector(sector, keyType);
    keyCheckProgress = null;
    return false;
  }

  Future<bool> initialize() {
    final operation = _captureOperation();
    if (operation == null) {
      return Future.value(false);
    }
    return _completeOperation(operation, _initialize(operation));
  }

  Future<void> _initialize(_RecoveryOperation operation) async {
    if (!await operation.waitFor(operation.communicator.isReaderDeviceMode())) {
      await operation.waitFor(operation.communicator.setReaderDeviceMode(true));
    }

    final mifare =
        await operation.waitFor(operation.communicator.detectMf1Support());

    if (mifare) {
      mifareClassicType = await operation.waitFor(mfClassicGetType(
        operation.communicator,
        canContinue: () => operation.isCurrent,
      ));
    } else {
      appState.log!.e("Not Mifare Classic tag!");
    }

    isMifareClassicEV1 = await operation.waitFor(
        operation.communicator.mf1Auth(0x45, 0x61, gMifareClassicKeys[3]));
    if (isMifareClassicEV1) {
      setKeyAsFound(17, 1, gMifareClassicKeys[3]);
    }
  }

  Future<void> recheckKey(Uint8List key, int startingSector) async {
    final operation = _captureOperation();
    if (operation == null) {
      return;
    }
    try {
      await operation.waitFor(_recheckKey(key, startingSector, operation));
    } on _RecoveryOperationCancelled {
      return;
    }
  }

  Future<void> _recheckKey(
      Uint8List key, int startingSector, _RecoveryOperation operation) async {
    for (var sector = startingSector;
        sector <
            mfClassicGetSectorCount(mifareClassicType,
                isEV1: isMifareClassicEV1);
        sector++) {
      for (var keyType = 0; keyType < 2; keyType++) {
        if (getSectorState(sector, keyType) == ChameleonKeyCheckmark.none) {
          state = localizations.checking_keys(1);
          appState.log!
              .d("Checking a found key on sector $sector, key type $keyType");
          setCheckingSector(sector, keyType);

          if (await operation.waitFor(operation.communicator.mf1Auth(
              mfClassicGetSectorTrailerBlockBySector(sector),
              0x60 + keyType,
              key))) {
            // Found valid key
            setKeyAsFound(sector, keyType, key);
          } else {
            setMissingSector(sector, keyType);
          }

          update();
        }
      }
    }
  }

  Future<bool> checkKeys({bool skipDefaultDictionary = false}) {
    final operation = _captureOperation();
    if (operation == null) {
      return Future.value(false);
    }
    return _completeOperation(
      operation,
      _checkKeys(operation, skipDefaultDictionary: skipDefaultDictionary),
    );
  }

  Future<void> _checkKeys(_RecoveryOperation operation,
      {required bool skipDefaultDictionary}) async {
    await operation.waitFor(_verifyKnownEV1Keys(operation));

    await operation.waitFor(_checkAssignedProfileKeys(operation));

    final selectedKeys = selectedDictionary?.keys ?? <Uint8List>[];
    final selectedKeyHex = selectedKeys.map(bytesToHex).toSet();
    final keyList = [
      ...selectedKeys,
      if (!skipDefaultDictionary)
        ...gMifareClassicKeys
            .where((key) => !selectedKeyHex.contains(bytesToHex(key)))
    ];

    for (var sector = 0;
        sector <
            mfClassicGetSectorCount(mifareClassicType,
                isEV1: isMifareClassicEV1);
        sector++) {
      for (var keyType = 0; keyType < 2; keyType++) {
        await operation
            .waitFor(_checkKeysOnSector(keyList, keyType, sector, operation));
      }
    }

    // Key check part competed, checking found keys
    allKeysExists = true;
    for (var sector = 0;
        sector <
            mfClassicGetSectorCount(mifareClassicType,
                isEV1: isMifareClassicEV1);
        sector++) {
      for (var keyType = 0; keyType < 2; keyType++) {
        if (getSectorState(sector, keyType) != ChameleonKeyCheckmark.found &&
            getSectorState(sector, keyType) != ChameleonKeyCheckmark.disabled) {
          allKeysExists = false;
        }
      }
    }

    state = "";
    update();
  }

  Future<void> _verifyKnownEV1Keys(_RecoveryOperation operation) async {
    if (!isMifareClassicEV1) {
      return;
    }
    final knownKeys = <(int, int, Uint8List)>[
      (16, 0, gMifareClassicKeys[4]),
      (16, 1, gMifareClassicKeys[5]),
      (17, 0, gMifareClassicKeys[6]),
      (17, 1, gMifareClassicKeys[3]),
    ];
    for (final (sector, keyType, key) in knownKeys) {
      final index = sector + keyType * 40;
      if (_hasConfirmedKeyAt(index)) {
        continue;
      }
      final authResult = await operation.waitFor(
        operation.communicator.mf1AuthResult(
          mfClassicGetSectorTrailerBlockBySector(sector),
          0x60 + keyType,
          key,
        ),
      );
      if (authResult.status == 0) {
        setKeyAsFound(sector, keyType, key);
      } else if (authResult.status == 0x06) {
        checkMarks[index] = ChameleonKeyCheckmark.none;
        validKeys[index] = Uint8List(0);
        update();
      } else {
        throw StateError(
            'EV1 signature-key authentication failed with device status '
            '0x${authResult.status.toRadixString(16).padLeft(2, '0')}');
      }
    }
  }

  Future<void> checkAssignedProfileKeys() async {
    final operation = _captureOperation();
    if (operation == null) {
      return;
    }
    try {
      await operation.waitFor(_checkAssignedProfileKeys(operation));
    } on _RecoveryOperationCancelled {
      return;
    }
  }

  Future<void> _checkAssignedProfileKeys(_RecoveryOperation operation) async {
    final profile = selectedKeyProfile;
    if (profile == null) {
      return;
    }

    final sectorCount =
        mfClassicGetSectorCount(mifareClassicType, isEV1: isMifareClassicEV1);
    if (!profile.isCompatible(
        cardType: mifareClassicType.name, sectorCount: sectorCount)) {
      throw const FormatException(
          'The selected key profile is not compatible with this card');
    }

    for (final assignment in profile.assignments) {
      for (var keyType = 0; keyType < 2; keyType++) {
        final key = assignment.keyForType(keyType);
        if (key == null ||
            getSectorState(assignment.sector, keyType) ==
                ChameleonKeyCheckmark.found ||
            getSectorState(assignment.sector, keyType) ==
                ChameleonKeyCheckmark.disabled) {
          continue;
        }

        state = localizations.checking_keys(1);
        setCheckingSector(assignment.sector, keyType);
        final authResult = await operation.waitFor(
          operation.communicator.mf1AuthResult(
            mfClassicGetSectorTrailerBlockBySector(assignment.sector),
            0x60 + keyType,
            key,
          ),
        );
        if (authResult.status == 0) {
          setKeyAsFound(assignment.sector, keyType, key);
        } else if (authResult.status == 0x06) {
          setMissingSector(assignment.sector, keyType);
        } else {
          throw StateError(
              'Assigned-key authentication failed with device status '
              '0x${authResult.status.toRadixString(16).padLeft(2, '0')}');
        }
      }
    }
  }

  bool get hasVerifiedKeys {
    for (var index = 0; index < checkMarks.length; index++) {
      if (_hasConfirmedKeyAt(index)) {
        return true;
      }
    }
    return false;
  }

  MifareClassicKeyProfile createKeyProfile({
    required String name,
    String? uid,
  }) {
    final sectorCount =
        mfClassicGetSectorCount(mifareClassicType, isEV1: isMifareClassicEV1);
    final assignments = <MifareClassicKeyAssignment>[];
    for (var sector = 0; sector < sectorCount; sector++) {
      final keyA = _hasConfirmedKeyAt(sector) ? validKeys[sector] : null;
      final keyB =
          _hasConfirmedKeyAt(sector + 40) ? validKeys[sector + 40] : null;
      if (keyA != null || keyB != null) {
        assignments.add(MifareClassicKeyAssignment(
          sector: sector,
          keyA: keyA,
          keyB: keyB,
        ));
      }
    }
    if (assignments.isEmpty) {
      throw const FormatException('No verified keys to save');
    }

    return MifareClassicKeyProfile(
      name: name,
      cardType: mifareClassicType.name,
      sectorCount: sectorCount,
      uid: uid,
      assignments: assignments,
    );
  }

  bool _hasConfirmedKeyAt(int index) =>
      checkMarks[index] == ChameleonKeyCheckmark.found &&
      validKeys[index].length == 6;

  Future<bool> recoverKeys() {
    final operation = _captureOperation();
    if (operation == null) {
      return Future.value(false);
    }
    return _completeOperation(operation, _recoverKeys(operation));
  }

  Future<void> _recoverKeys(_RecoveryOperation operation) async {
    state = localizations.checking_card_info;
    update();

    error = "";
    bool hasKey = false;
    bool hasBackdoor = await operation.waitFor(mfClassicHasBackdoor(
      operation.communicator,
      canContinue: () => operation.isCurrent,
    ));
    (int, NestedNonces, NestedNonces, Uint8List)? backdoorInfo;
    if (hasBackdoor) {
      backdoorInfo = await operation.waitFor(
        operation.communicator.getMf1StaticEncryptedNestedAcquire(
          sectorCount: mfClassicGetSectorCount(mifareClassicType,
              isEV1: isMifareClassicEV1),
        ),
      );
    }

    DarksideResult darkside = DarksideResult.fixed;
    for (var sector = 0;
        sector <
                mfClassicGetSectorCount(mifareClassicType,
                    isEV1: isMifareClassicEV1) &&
            !hasKey;
        sector++) {
      for (var keyType = 0; keyType < 2; keyType++) {
        if (getSectorState(sector, keyType) == ChameleonKeyCheckmark.found) {
          hasKey = true;
          break;
        }
      }
    }

    update();

    bool isStaticEncrypted = false;

    if (hasBackdoor) {
      isStaticEncrypted = await operation.waitFor(mfClassicIsStaticEncrypted(
          operation.communicator, 0, 4, backdoorInfo!.$4));
    }

    NTLevel prng =
        await operation.waitFor(operation.communicator.getMf1NTLevel());
    update();

    if (!hasKey && !isStaticEncrypted && prng != NTLevel.static) {
      state = localizations.checking_or_running_darkside;
      update();

      try {
        setCheckingSector(0, 1);
        darkside =
            await operation.waitFor(operation.communicator.checkMf1Darkside());
      } on _RecoveryOperationCancelled {
        rethrow;
      } catch (_) {
        setMissingSector(0, 1);
      }

      if (darkside == DarksideResult.vulnerable) {
        // recover with darkside
        var data = await operation.waitFor(
            operation.communicator.getMf1Darkside(0x03, 0x61, true, 15));
        var darkside = DarksideDart(uid: data.uid, items: []);
        bool found = false;
        update();

        for (var tries = 0; tries < 5 && !found; tries++) {
          darkside.items.add(DarksideItemDart(
              nt1: data.nt1,
              ks1: data.ks1,
              par: data.par,
              nr: data.nr,
              ar: data.ar));

          var keys = await operation.waitFor(recovery.darkside(darkside));
          if (keys.isNotEmpty) {
            appState.log!
                .d("Darkside recovered ${keys.length} candidate key(s)");

            if (await operation.waitFor(_checkKeysOnSector(
                mfClassicConvertKeys(keys), 1, 0, operation))) {
              found = true;
              hasKey = true;

              break;
            }
          } else {
            appState.log!.d("Can't find keys, retrying...");
            data = await operation.waitFor(
                operation.communicator.getMf1Darkside(0x03, 0x61, false, 15));
          }
        }

        if (!found) {
          setMissingSector(0, 1);
        }
      }
    }

    update();

    if (!hasKey && hasBackdoor && prng == NTLevel.weak && !isStaticEncrypted) {
      state = localizations.backdoor_recovery_of_non_static_encrypted;
      setCheckingSector(0, 0);

      for (var i = 0; i < 3; i++) {
        NTDistance distance = await operation.waitFor(
            operation.communicator.getMf1NTDistance(0, 0x64, backdoorInfo!.$4));

        NestedNonces nonces = await operation.waitFor(operation.communicator
            .getMf1NestedNonces(0, 0x64, backdoorInfo.$4, 0, 0x60,
                level: prng));

        var nested = NestedDart(
            uid: distance.uid,
            distance: distance.distance,
            nt0: nonces.nonces[0].nt,
            nt0Enc: nonces.nonces[0].ntEnc,
            par0: nonces.nonces[0].parity,
            nt1: nonces.nonces[1].nt,
            nt1Enc: nonces.nonces[1].ntEnc,
            par1: nonces.nonces[1].parity);

        List<int> keys = await operation.waitFor(recovery.nested(nested));

        if (keys.isNotEmpty) {
          appState.log!.d("Recovered ${keys.length} candidate key(s)");
          if (await operation.waitFor(_checkKeysOnSector(
              mfClassicConvertKeys(keys), 0, 0, operation))) {
            break;
          }
        }
      }
    }

    Uint8List validKey = Uint8List(0);
    int validKeyBlock = 0;
    int validKeyType = -1;

    for (var sector = 0;
        sector <
            mfClassicGetSectorCount(mifareClassicType,
                isEV1: isMifareClassicEV1);
        sector++) {
      for (var keyType = 0; keyType < 2; keyType++) {
        if (getSectorState(sector, keyType) == ChameleonKeyCheckmark.found) {
          validKey = getSectorKey(sector, keyType);
          validKeyBlock = mfClassicGetSectorTrailerBlockBySector(sector);
          validKeyType = keyType;
          if (!isStaticEncrypted) {
            isStaticEncrypted = await operation.waitFor(
                mfClassicIsStaticEncrypted(operation.communicator,
                    validKeyBlock, validKeyType, validKey));
          }
          break;
        }
      }
    }

    if ((isStaticEncrypted || (validKeyType == -1 && hasBackdoor)) &&
        backdoorInfo != null) {
      prng = NTLevel.backdoor;
    }

    if (validKeyType == -1 && prng != NTLevel.backdoor) {
      error = localizations.recovery_error_no_keys_darkside;
      state = "";
      return;
    }

    int tries = [NTLevel.backdoor, NTLevel.static].contains(prng) ? 1 : 5;

    for (var sector = 0;
        sector <
            mfClassicGetSectorCount(mifareClassicType,
                isEV1: isMifareClassicEV1);
        sector++) {
      for (var keyType = 0; keyType < 2; keyType++) {
        if (getSectorState(sector, keyType) == ChameleonKeyCheckmark.none) {
          String attackType;

          switch (prng) {
            case NTLevel.static:
              attackType = "Static Nested";
            case NTLevel.weak:
              attackType = "Nested";
            case NTLevel.hard:
              attackType = "Hard Nested";
            case NTLevel.backdoor:
              attackType = localizations.has_backdoor_support;
            case NTLevel.unknown:
              attackType = "";
          }

          state = localizations.collecting_nonces(attackType);
          setCheckingSector(sector, keyType);

          NTDistance? distance;
          NestedNonces? nonces;

          if (prng != NTLevel.backdoor) {
            distance = await operation.waitFor(operation.communicator
                .getMf1NTDistance(
                    validKeyBlock, 0x60 + validKeyType, validKey));
          }

          bool found = false;
          for (var i = 0; i < tries && !found; i++) {
            List<int> keys = [];

            if (prng == NTLevel.hard) {
              hardnestedProgress = 0;
              update();

              var result = await operation.waitFor(_collectHardnestedNonces(
                validKeyBlock,
                0x60 + validKeyType,
                validKey,
                mfClassicGetSectorTrailerBlockBySector(sector),
                0x60 + keyType,
                operation,
              ));

              if (result is String) {
                setMissingSector(sector, keyType);
                error = result;
                return;
              } else {
                nonces = result as NestedNonces;
              }
            } else if (prng != NTLevel.backdoor) {
              nonces = await operation.waitFor(
                operation.communicator.getMf1NestedNonces(
                  validKeyBlock,
                  0x60 + validKeyType,
                  validKey,
                  mfClassicGetSectorTrailerBlockBySector(sector),
                  0x60 + keyType,
                  level: prng,
                ),
              );
            }

            state = localizations.recovering_key(attackType);
            update();

            if (prng == NTLevel.weak) {
              var nested = NestedDart(
                  uid: distance!.uid,
                  distance: distance.distance,
                  nt0: nonces!.nonces[0].nt,
                  nt0Enc: nonces.nonces[0].ntEnc,
                  par0: nonces.nonces[0].parity,
                  nt1: nonces.nonces[1].nt,
                  nt1Enc: nonces.nonces[1].ntEnc,
                  par1: nonces.nonces[1].parity);

              keys = await operation.waitFor(recovery.nested(nested));
            } else if (prng == NTLevel.static) {
              var nested = StaticNestedDart(
                uid: distance!.uid,
                keyType: 0x60 + validKeyType,
                nt0: nonces!.nonces[0].nt,
                nt0Enc: nonces.nonces[0].ntEnc,
                nt1: nonces.nonces[1].nt,
                nt1Enc: nonces.nonces[1].ntEnc,
              );

              keys = await operation.waitFor(recovery.staticNested(nested));
            } else if (prng == NTLevel.hard) {
              var nested =
                  HardNestedDart(nonces: nonces!.getHardNested(distance!.uid));
              keys = await operation.waitFor(recovery.hardNested(nested));
            } else if (prng == NTLevel.backdoor) {
              setCheckingSector(sector, 1);

              var possibleAKeys = await operation.waitFor(
                recovery.staticEncryptedNested(
                  StaticEncryptedNestedDart(
                      uid: backdoorInfo!.$1,
                      nt: backdoorInfo.$2.nonces[sector].nt,
                      ntEnc: backdoorInfo.$2.nonces[sector].ntEnc,
                      ntParEnc: backdoorInfo.$2.nonces[sector].parity),
                ),
              );

              var possibleBKeys = await operation.waitFor(
                recovery.staticEncryptedNested(
                  StaticEncryptedNestedDart(
                      uid: backdoorInfo.$1,
                      nt: backdoorInfo.$3.nonces[sector].nt,
                      ntEnc: backdoorInfo.$3.nonces[sector].ntEnc,
                      ntParEnc: backdoorInfo.$3.nonces[sector].parity),
                ),
              );

              var filtered = await operation.waitFor(
                StaticEncryptedKeysFilterAsync.filterKeys(
                    possibleAKeys,
                    possibleBKeys,
                    backdoorInfo.$2.nonces[sector].nt,
                    backdoorInfo.$3.nonces[sector].nt),
              );

              if (checkMarks[sector + 40] != ChameleonKeyCheckmark.found &&
                  checkMarks[sector + 40] != ChameleonKeyCheckmark.disabled &&
                  await operation.waitFor(_checkKeysOnSector(
                      mfClassicConvertKeys(filtered.$2.reversed.toList()),
                      1,
                      sector,
                      operation))) {
                checkMarks[sector + 40] = ChameleonKeyCheckmark.found;
              }

              if (checkMarks[sector] == ChameleonKeyCheckmark.found ||
                  checkMarks[sector] == ChameleonKeyCheckmark.disabled) {
                found = true;
                break;
              } else if (await operation.waitFor(_checkKeysOnSector(
                  mfClassicConvertKeys(await operation.waitFor(
                      StaticEncryptedKeysFilterAsync.findMatchingKeys(
                          backdoorInfo.$3.nonces[sector].nt,
                          bytesToU64(Uint8List.fromList(
                              [0, 0, ...validKeys[sector + 40]])),
                          backdoorInfo.$2.nonces[sector].nt,
                          possibleAKeys))),
                  0,
                  sector,
                  operation))) {
                found = true;
                break;
              } else if (await operation.waitFor(_checkKeysOnSector(
                  mfClassicConvertKeys(filtered.$1.reversed.toList()),
                  0,
                  sector,
                  operation))) {
                found = true;
                break;
              }

              setMissingSector(sector, 0);
              setMissingSector(sector, 1);
            }

            if (keys.isNotEmpty) {
              appState.log!.d("Recovered ${keys.length} candidate key(s)");

              if (await operation.waitFor(_checkKeysOnSector(
                  mfClassicConvertKeys(keys), keyType, sector, operation))) {
                found = true;

                break;
              }
            } else {
              appState.log!.e("Can't find keys, retrying...");
            }
          }
        }
      }
    }

    state = "";
    allKeysExists = true;
    for (var sector = 0;
        sector <
            mfClassicGetSectorCount(mifareClassicType,
                isEV1: isMifareClassicEV1);
        sector++) {
      for (var keyType = 0; keyType < 2; keyType++) {
        if (getSectorState(sector, keyType) != ChameleonKeyCheckmark.found &&
            getSectorState(sector, keyType) != ChameleonKeyCheckmark.disabled) {
          allKeysExists = false;
        }
      }
    }
    update();
  }

  Future<bool> dumpData() {
    final operation = _captureOperation();
    if (operation == null) {
      return Future.value(false);
    }
    return _completeOperation(operation, _dumpData(operation));
  }

  Future<void> _dumpData(_RecoveryOperation operation) async {
    cardData = List.generate(256, (_) => Uint8List(0));
    dumpComplete = true;

    for (var sector = 0;
        sector <
            mfClassicGetSectorCount(mifareClassicType,
                isEV1: isMifareClassicEV1);
        sector++) {
      for (var block = 0;
          block < mfClassicGetBlockCountBySector(sector);
          block++) {
        final absoluteBlock =
            block + mfClassicGetFirstBlockCountBySector(sector);
        Uint8List? blockData;
        for (var keyType = 0; keyType < 2; keyType++) {
          appState.log!
              .d("Dumping sector $sector, block $block with key $keyType");

          if (getSectorKey(sector, keyType).isEmpty) {
            appState.log!.w("Skipping missing key");
            continue;
          }

          final candidate = await operation.waitFor(
            operation.communicator.mf1ReadBlock(
              absoluteBlock,
              0x60 + keyType,
              getSectorKey(sector, keyType),
            ),
          );

          if (candidate.length != 16) {
            continue;
          }
          blockData = candidate;
          break;
        }

        if (blockData == null) {
          dumpComplete = false;
          cardData[absoluteBlock] = Uint8List(16);
        } else {
          if (mfClassicGetSectorTrailerBlockBySector(sector) == absoluteBlock) {
            // set keys in sector trailer
            if (getSectorKey(sector, 0).isNotEmpty) {
              blockData.setRange(0, 6, getSectorKey(sector, 0));
            }

            if (getSectorKey(sector, 1).isNotEmpty) {
              blockData.setRange(10, 16, getSectorKey(sector, 1));
            }
          }
          cardData[absoluteBlock] = blockData;
        }

        dumpProgress = absoluteBlock /
            (mfClassicGetBlockCount(mifareClassicType,
                isEV1: isMifareClassicEV1));
        update();
      }
    }
  }

  Future<dynamic> collectHardnestedNonces(int block, int keyType,
      Uint8List knownKey, int targetBlock, int targetKeyType) async {
    final operation = _captureOperation();
    if (operation == null) {
      return null;
    }
    try {
      return await operation.waitFor(_collectHardnestedNonces(
          block, keyType, knownKey, targetBlock, targetKeyType, operation));
    } on _RecoveryOperationCancelled {
      return null;
    }
  }

  Future<dynamic> _collectHardnestedNonces(
      int block,
      int keyType,
      Uint8List knownKey,
      int targetBlock,
      int targetKeyType,
      _RecoveryOperation operation) async {
    NestedNonces nonces = NestedNonces(nonces: []);
    while (true) {
      var collectedNonces = await operation.waitFor(
        operation.communicator.getMf1NestedNonces(
            block, keyType, knownKey, targetBlock, targetKeyType,
            level: NTLevel.hard),
      );
      nonces.nonces.addAll(collectedNonces.nonces);
      List info = nonces.getNoncesInfo();
      appState.log!.d(
          "Collected ${nonces.nonces.length} nonces, sum ${info[0]}, num ${info[1]}");

      if (nonces.nonces.isEmpty) {
        return localizations.recovery_old_firmware;
      }

      hardnestedProgress = info[1] / 256;
      state = localizations.hardnested_collecting_nonces(
          (hardnestedProgress! * 256).toInt().toString());
      update();
      if (info[1] == 256) {
        if ([
          0,
          32,
          56,
          64,
          80,
          96,
          104,
          112,
          120,
          128,
          136,
          144,
          152,
          160,
          176,
          192,
          200,
          224,
          256
        ].contains(info[0])) {
          break;
        }

        appState.log!.e("Got wrong sum, trying to collect nonces again...");
        nonces.nonces = [];
      }
    }

    hardnestedProgress = null;
    return nonces;
  }

  void setKeyAsFound(int sector, int keyType, Uint8List key) {
    final index = sector + (keyType * 40);
    checkMarks[index] = ChameleonKeyCheckmark.found;
    validKeys[index] = key;
    update();
  }

  void setCheckingSector(int sector, int keyType) {
    if (getSectorState(sector, keyType) == ChameleonKeyCheckmark.none) {
      checkMarks[sector + (keyType * 40)] = ChameleonKeyCheckmark.checking;
    }
    update();
  }

  void setMissingSector(int sector, int keyType) {
    if (getSectorState(sector, keyType) == ChameleonKeyCheckmark.checking) {
      checkMarks[sector + (keyType * 40)] = ChameleonKeyCheckmark.none;
      update();
    }
  }

  Uint8List getSectorKey(int sector, int keyType) {
    return validKeys[sector + (keyType * 40)];
  }

  ChameleonKeyCheckmark getSectorState(int sector, int keyType) {
    return checkMarks[sector + (keyType * 40)];
  }
}
