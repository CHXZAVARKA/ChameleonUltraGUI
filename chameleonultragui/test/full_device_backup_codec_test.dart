import 'dart:convert';
import 'dart:typed_data';

import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/full_device_backup.dart';
import 'package:chameleonultragui/helpers/single_slot_backup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('full-device backup codec', () {
    test('round-trips exactly eight canonical position records', () {
      final backup = _backup();

      final encoded = FullDeviceBackupCodec.encode(backup);
      final root = jsonDecode(encoded) as Map<String, dynamic>;
      final positions = root['positions'] as List<dynamic>;
      final decoded = FullDeviceBackupCodec.decode(encoded);

      expect(root['format'], fullDeviceBackupFormat);
      expect(root['schemaVersion'], fullDeviceBackupSchemaVersion);
      expect(positions, hasLength(8));
      expect(
        positions.map(
          (position) => ((position as Map<String, dynamic>)['slot']
              as Map<String, dynamic>)['format'],
        ),
        everyElement(singleSlotBackupFormat),
      );
      expect(decoded.positions.map((item) => item.slot.sourcePosition),
          orderedEquals(List.generate(8, (index) => index)));
      expect(decoded.activeSlot, 3);
      expect(decoded.mode, FullDeviceOperatingMode.reader);
      expect(FullDeviceBackupCodec.encode(decoded), encoded);
    });

    test('stores only allowlisted settings and sanitized firmware facts', () {
      final encoded = FullDeviceBackupCodec.encode(_backup());
      final root = jsonDecode(encoded) as Map<String, dynamic>;
      final preferences = root['safePreferences'] as Map<String, dynamic>;

      expect(
        preferences.keys,
        unorderedEquals([
          'animationMode',
          'buttonAPress',
          'buttonBPress',
          'buttonALongPress',
          'buttonBLongPress',
          'sleepTimeoutSeconds',
        ]),
      );
      expect(encoded, isNot(contains('pairing')));
      expect(encoded, isNot(contains('bond')));
      expect(encoded, isNot(contains('bleKey')));
      expect(encoded, isNot(contains('debug')));
      expect(encoded, isNot(contains('firmwareBinary')));
      expect(encoded, isNot(contains('applicationPreferences')));
      expect(encoded, contains('v2.2.0-19-gcf2b268'));
      expect(encoded, contains('legacy'));
    });

    test('rejects missing, duplicate, and out-of-range positions', () {
      final valid = jsonDecode(FullDeviceBackupCodec.encode(_backup()))
          as Map<String, dynamic>;
      final positions = valid['positions'] as List<dynamic>;

      final missing = Map<String, dynamic>.from(valid)
        ..['positions'] = positions.take(7).toList();
      expect(
        () => FullDeviceBackupCodec.decode(jsonEncode(missing)),
        throwsFormatException,
      );

      final duplicatePositions = positions
          .map((position) => jsonDecode(jsonEncode(position)))
          .toList();
      final duplicate = duplicatePositions[7] as Map<String, dynamic>;
      final duplicateSlot = duplicate['slot'] as Map<String, dynamic>;
      duplicateSlot['sourcePosition'] = 6;
      final duplicated = Map<String, dynamic>.from(valid)
        ..['positions'] = duplicatePositions;
      expect(
        () => FullDeviceBackupCodec.decode(jsonEncode(duplicated)),
        throwsFormatException,
      );

      final outOfRangePositions = positions
          .map((position) => jsonDecode(jsonEncode(position)))
          .toList();
      final outOfRange = outOfRangePositions[7] as Map<String, dynamic>;
      final outOfRangeSlot = outOfRange['slot'] as Map<String, dynamic>;
      outOfRangeSlot['sourcePosition'] = 8;
      final invalid = Map<String, dynamic>.from(valid)
        ..['positions'] = outOfRangePositions;
      expect(
        () => FullDeviceBackupCodec.decode(jsonEncode(invalid)),
        throwsFormatException,
      );
    });

    test('rejects a capture report that contradicts its slot record', () {
      final root = jsonDecode(FullDeviceBackupCodec.encode(_backup()))
          as Map<String, dynamic>;
      final positions = root['positions'] as List<dynamic>;
      final first = positions.first as Map<String, dynamic>;
      final capture = first['capture'] as Map<String, dynamic>;
      capture['hf'] = 'failed';
      capture['state'] = 'failed';

      expect(
        () => FullDeviceBackupCodec.decode(jsonEncode(root)),
        throwsFormatException,
      );
    });

    test('detects corruption inside an embedded canonical payload', () {
      final root =
          jsonDecode(FullDeviceBackupCodec.encode(_backup(withLf: true)))
              as Map<String, dynamic>;
      final positions = root['positions'] as List<dynamic>;
      final first = positions.first as Map<String, dynamic>;
      final slot = first['slot'] as Map<String, dynamic>;
      final frequencies = slot['frequencies'] as List<dynamic>;
      final lf = frequencies[1] as Map<String, dynamic>;
      final payload = lf['payload'] as Map<String, dynamic>;
      final uid = payload['uid'] as Map<String, dynamic>;
      uid['data'] = 'AQIDBAY=';

      expect(
        () => FullDeviceBackupCodec.decode(jsonEncode(root)),
        throwsFormatException,
      );
    });

    test('ignores unknown future fields without relaxing schema validation',
        () {
      final root = jsonDecode(FullDeviceBackupCodec.encode(_backup()))
          as Map<String, dynamic>;
      root['futureEnvelopeField'] = {'enabled': true};
      final positions = root['positions'] as List<dynamic>;
      (positions.first as Map<String, dynamic>)['futurePositionField'] = 7;

      final decoded = FullDeviceBackupCodec.decode(jsonEncode(root));

      expect(decoded.positions, hasLength(8));
      root['schemaVersion'] = 2;
      expect(
        () => FullDeviceBackupCodec.decode(jsonEncode(root)),
        throwsFormatException,
      );
    });

    test('round-trips explicit skipped and failed report states', () {
      final source = _backup();
      FullDevicePositionBackup unavailable(
        int position,
        FullDeviceCaptureState state,
      ) =>
          FullDevicePositionBackup(
            slot: SingleSlotBackup(
              sourceDevice: source.sourceDevice,
              sourcePosition: position,
              createdAt: source.createdAt,
              hf: const SlotFrequencyBackup.unavailable(
                frequency: TagFrequency.hf,
              ),
              lf: const SlotFrequencyBackup.unavailable(
                frequency: TagFrequency.lf,
              ),
            ),
            hfState: state,
            lfState: state,
          );
      final backup = FullDeviceBackup(
        sourceDevice: source.sourceDevice,
        createdAt: source.createdAt,
        activeSlot: source.activeSlot,
        mode: source.mode,
        firmware: source.firmware,
        preferences: source.preferences,
        positions: [
          ...source.positions.take(6),
          unavailable(6, FullDeviceCaptureState.skipped),
          unavailable(7, FullDeviceCaptureState.failed),
        ],
      );

      final decoded = FullDeviceBackupCodec.decode(
        FullDeviceBackupCodec.encode(backup),
      );

      expect(decoded.positions[6].state, FullDeviceCaptureState.skipped);
      expect(decoded.positions[7].state, FullDeviceCaptureState.failed);
    });
  });
}

FullDeviceBackup _backup({bool withLf = false}) {
  final createdAt = DateTime.utc(2026, 8, 13, 10, 30);
  return FullDeviceBackup(
    sourceDevice: ChameleonDevice.ultra,
    createdAt: createdAt,
    activeSlot: 3,
    mode: FullDeviceOperatingMode.reader,
    firmware: const FullDeviceFirmwareFacts(
      version: BackupFact<int>.confirmed(0x202),
      commit: BackupFact<String>.confirmed('v2.2.0-19-gcf2b268'),
      protocol: BackupFact<FullDeviceFirmwareProtocol>.confirmed(
          FullDeviceFirmwareProtocol.legacy),
    ),
    preferences: const FullDeviceSafePreferences(
      animationMode: BackupFact<AnimationSetting>.confirmed(
        AnimationSetting.symmetric,
      ),
      buttonAPress: BackupFact<ButtonConfig>.confirmed(
        ButtonConfig.cycleForward,
      ),
      buttonBPress: BackupFact<ButtonConfig>.confirmed(
        ButtonConfig.cycleBackward,
      ),
      buttonALongPress: BackupFact<ButtonConfig>.confirmed(
        ButtonConfig.cloneUID,
      ),
      buttonBLongPress: BackupFact<ButtonConfig>.confirmed(
        ButtonConfig.chargeStatus,
      ),
      sleepTimeoutSeconds: BackupFact<int>.confirmed(30),
    ),
    positions: List.generate(8, (position) {
      final slot = SingleSlotBackup(
        sourceDevice: ChameleonDevice.ultra,
        sourcePosition: position,
        createdAt: createdAt,
        hf: SlotFrequencyBackup.empty(
          frequency: TagFrequency.hf,
          enabled: false,
          name: '',
        ),
        lf: withLf && position == 0
            ? SlotFrequencyBackup.complete(
                frequency: TagFrequency.lf,
                type: TagType.em410X,
                enabled: true,
                name: 'Door',
                payload: SlotCardPayload(
                  uid: Uint8List.fromList([1, 2, 3, 4, 5]),
                ),
              )
            : SlotFrequencyBackup.empty(
                frequency: TagFrequency.lf,
                enabled: false,
                name: '',
              ),
      );
      return FullDevicePositionBackup.captured(slot);
    }),
  );
}
