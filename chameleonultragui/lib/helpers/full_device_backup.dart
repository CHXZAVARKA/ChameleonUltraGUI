import 'dart:convert';

import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/single_slot_backup.dart';

const fullDeviceBackupFormat = 'chameleon-ultra-device-backup';
const fullDeviceBackupSchemaVersion = 1;

enum BackupFactState { confirmed, unsupported, failed }

enum FullDeviceOperatingMode { emulator, reader }

enum FullDeviceFirmwareProtocol { current, legacy }

enum FullDeviceCaptureState {
  complete,
  partial,
  unsupported,
  skipped,
  failed,
}

class BackupFact<T> {
  const BackupFact.confirmed(this.value) : state = BackupFactState.confirmed;

  const BackupFact.unsupported()
      : state = BackupFactState.unsupported,
        value = null;

  const BackupFact.failed()
      : state = BackupFactState.failed,
        value = null;

  final BackupFactState state;
  final T? value;
}

class FullDeviceFirmwareFacts {
  const FullDeviceFirmwareFacts({
    required this.version,
    required this.commit,
    required this.protocol,
  });

  final BackupFact<int> version;
  final BackupFact<String> commit;
  final BackupFact<FullDeviceFirmwareProtocol> protocol;

  bool get hasLimitations =>
      version.state != BackupFactState.confirmed ||
      commit.state != BackupFactState.confirmed ||
      protocol.state != BackupFactState.confirmed;
}

class FullDeviceSafePreferences {
  const FullDeviceSafePreferences({
    required this.animationMode,
    required this.buttonAPress,
    required this.buttonBPress,
    required this.buttonALongPress,
    required this.buttonBLongPress,
    required this.sleepTimeoutSeconds,
  });

  final BackupFact<AnimationSetting> animationMode;
  final BackupFact<ButtonConfig> buttonAPress;
  final BackupFact<ButtonConfig> buttonBPress;
  final BackupFact<ButtonConfig> buttonALongPress;
  final BackupFact<ButtonConfig> buttonBLongPress;
  final BackupFact<int> sleepTimeoutSeconds;

  bool get hasLimitations =>
      animationMode.state != BackupFactState.confirmed ||
      buttonAPress.state != BackupFactState.confirmed ||
      buttonBPress.state != BackupFactState.confirmed ||
      buttonALongPress.state != BackupFactState.confirmed ||
      buttonBLongPress.state != BackupFactState.confirmed ||
      sleepTimeoutSeconds.state != BackupFactState.confirmed;
}

class FullDevicePositionBackup {
  const FullDevicePositionBackup({
    required this.slot,
    required this.hfState,
    required this.lfState,
  });

  final SingleSlotBackup slot;
  final FullDeviceCaptureState hfState;
  final FullDeviceCaptureState lfState;

  bool get isConfirmed => state == FullDeviceCaptureState.complete;

  FullDeviceCaptureState get state {
    final states = {hfState, lfState};
    if (states.contains(FullDeviceCaptureState.failed)) {
      return FullDeviceCaptureState.failed;
    }
    if (states.contains(FullDeviceCaptureState.skipped)) {
      return FullDeviceCaptureState.skipped;
    }
    if (states.contains(FullDeviceCaptureState.partial)) {
      return FullDeviceCaptureState.partial;
    }
    if (states.contains(FullDeviceCaptureState.unsupported)) {
      return FullDeviceCaptureState.unsupported;
    }
    return FullDeviceCaptureState.complete;
  }

  factory FullDevicePositionBackup.captured(SingleSlotBackup slot) =>
      FullDevicePositionBackup(
        slot: slot,
        hfState: _stateForFrequency(slot.hf),
        lfState: _stateForFrequency(slot.lf),
      );

  static FullDeviceCaptureState _stateForFrequency(
    SlotFrequencyBackup frequency,
  ) =>
      switch (frequency.state) {
        SlotBackupCompleteness.empty ||
        SlotBackupCompleteness.complete =>
          FullDeviceCaptureState.complete,
        SlotBackupCompleteness.partial => FullDeviceCaptureState.partial,
        SlotBackupCompleteness.unsupported =>
          FullDeviceCaptureState.unsupported,
        SlotBackupCompleteness.unavailable => FullDeviceCaptureState.skipped,
      };
}

class FullDeviceBackup {
  FullDeviceBackup({
    required this.sourceDevice,
    required DateTime createdAt,
    required this.activeSlot,
    required this.mode,
    required this.firmware,
    required this.preferences,
    required List<FullDevicePositionBackup> positions,
  })  : createdAt = createdAt.toUtc(),
        positions = List.unmodifiable(positions);

  final ChameleonDevice sourceDevice;
  final DateTime createdAt;
  final int activeSlot;
  final FullDeviceOperatingMode mode;
  final FullDeviceFirmwareFacts firmware;
  final FullDeviceSafePreferences preferences;
  final List<FullDevicePositionBackup> positions;

  bool get hasLimitations =>
      firmware.hasLimitations ||
      preferences.hasLimitations ||
      positions
          .any((position) => position.state != FullDeviceCaptureState.complete);
}

abstract final class FullDeviceBackupCodec {
  static bool isSafeFirmwareCommit(Object? value) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= 96 &&
      RegExp(r'^[A-Za-z0-9._+-]+$').hasMatch(value);

  static String encode(FullDeviceBackup backup) {
    _validate(backup);
    return jsonEncode({
      'format': fullDeviceBackupFormat,
      'schemaVersion': fullDeviceBackupSchemaVersion,
      'createdAt': backup.createdAt.toIso8601String(),
      'sourceDevice': backup.sourceDevice.name,
      'activeSlot': backup.activeSlot,
      'mode': backup.mode.name,
      'firmware': {
        'version': _encodeFact(backup.firmware.version),
        'commit': _encodeFact(backup.firmware.commit),
        'protocol': _encodeFact(
          backup.firmware.protocol,
          encode: (value) => value.name,
        ),
      },
      'safePreferences': {
        'animationMode': _encodeFact(
          backup.preferences.animationMode,
          encode: (value) => value.name,
        ),
        'buttonAPress': _encodeFact(
          backup.preferences.buttonAPress,
          encode: (value) => value.name,
        ),
        'buttonBPress': _encodeFact(
          backup.preferences.buttonBPress,
          encode: (value) => value.name,
        ),
        'buttonALongPress': _encodeFact(
          backup.preferences.buttonALongPress,
          encode: (value) => value.name,
        ),
        'buttonBLongPress': _encodeFact(
          backup.preferences.buttonBLongPress,
          encode: (value) => value.name,
        ),
        'sleepTimeoutSeconds':
            _encodeFact(backup.preferences.sleepTimeoutSeconds),
      },
      'positions': backup.positions
          .map(
            (position) => {
              'slot': SingleSlotBackupCodec.toJson(position.slot),
              'capture': {
                'state': position.state.name,
                'hf': position.hfState.name,
                'lf': position.lfState.name,
              },
            },
          )
          .toList(),
    });
  }

  static FullDeviceBackup decode(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } catch (_) {
      throw const FormatException('Backup is not valid JSON');
    }
    final root = _map(decoded, 'backup');
    if (root['format'] != fullDeviceBackupFormat) {
      throw const FormatException('Unsupported backup format');
    }
    if (root['schemaVersion'] != fullDeviceBackupSchemaVersion) {
      throw const FormatException('Unsupported backup schema');
    }
    final device = ChameleonDevice.values
        .where((device) => device.name == root['sourceDevice'])
        .firstOrNull;
    if (device == null || device == ChameleonDevice.none) {
      throw const FormatException('Invalid source device');
    }
    final createdAtSource = root['createdAt'];
    final createdAt =
        createdAtSource is String ? DateTime.tryParse(createdAtSource) : null;
    if (createdAt == null) {
      throw const FormatException('Invalid creation time');
    }
    final activeSlot = _integer(root['activeSlot'], 'activeSlot');
    final mode = _enumValue(
      FullDeviceOperatingMode.values,
      root['mode'],
      'mode',
    );
    final firmwareMap = _map(root['firmware'], 'firmware');
    final preferencesMap = _map(root['safePreferences'], 'safePreferences');
    final positions = _list(root['positions'], 'positions').map((source) {
      final positionMap = _map(source, 'position');
      final slot = SingleSlotBackupCodec.fromJson(positionMap['slot']);
      final capture = _map(positionMap['capture'], 'capture');
      final position = FullDevicePositionBackup(
        slot: slot,
        hfState: _enumValue(
          FullDeviceCaptureState.values,
          capture['hf'],
          'capture.hf',
        ),
        lfState: _enumValue(
          FullDeviceCaptureState.values,
          capture['lf'],
          'capture.lf',
        ),
      );
      if (capture['state'] != position.state.name) {
        throw const FormatException('Invalid position capture summary');
      }
      return position;
    }).toList();
    final backup = FullDeviceBackup(
      sourceDevice: device,
      createdAt: createdAt,
      activeSlot: activeSlot,
      mode: mode,
      firmware: FullDeviceFirmwareFacts(
        version: _decodeFact<int>(
          firmwareMap['version'],
          'firmware.version',
          decode: (value) => _integer(value, 'firmware.version.value'),
        ),
        commit: _decodeFact<String>(
          firmwareMap['commit'],
          'firmware.commit',
          decode: (value) => _safeCommit(value),
        ),
        protocol: _decodeFact<FullDeviceFirmwareProtocol>(
          firmwareMap['protocol'],
          'firmware.protocol',
          decode: (value) => _enumValue(
            FullDeviceFirmwareProtocol.values,
            value,
            'firmware.protocol.value',
          ),
        ),
      ),
      preferences: FullDeviceSafePreferences(
        animationMode: _decodeFact<AnimationSetting>(
          preferencesMap['animationMode'],
          'safePreferences.animationMode',
          decode: (value) => _enumValue(
            AnimationSetting.values,
            value,
            'safePreferences.animationMode.value',
          ),
        ),
        buttonAPress: _decodeButton(
          preferencesMap['buttonAPress'],
          'safePreferences.buttonAPress',
        ),
        buttonBPress: _decodeButton(
          preferencesMap['buttonBPress'],
          'safePreferences.buttonBPress',
        ),
        buttonALongPress: _decodeButton(
          preferencesMap['buttonALongPress'],
          'safePreferences.buttonALongPress',
        ),
        buttonBLongPress: _decodeButton(
          preferencesMap['buttonBLongPress'],
          'safePreferences.buttonBLongPress',
        ),
        sleepTimeoutSeconds: _decodeFact<int>(
          preferencesMap['sleepTimeoutSeconds'],
          'safePreferences.sleepTimeoutSeconds',
          decode: (value) {
            final seconds = _integer(
              value,
              'safePreferences.sleepTimeoutSeconds.value',
            );
            if (seconds < 0 || seconds > 255) {
              throw const FormatException('Invalid sleep timeout');
            }
            return seconds;
          },
        ),
      ),
      positions: positions,
    );
    _validate(backup);
    return backup;
  }

  static Map<String, Object?> _encodeFact<T>(
    BackupFact<T> fact, {
    Object? Function(T value)? encode,
  }) =>
      {
        'state': fact.state.name,
        if (fact.state == BackupFactState.confirmed)
          'value': encode == null ? fact.value : encode(fact.value as T),
      };

  static BackupFact<T> _decodeFact<T>(
    Object? source,
    String field, {
    required T Function(Object? value) decode,
  }) {
    final map = _map(source, field);
    final state =
        _enumValue(BackupFactState.values, map['state'], '$field.state');
    if (state != BackupFactState.confirmed) {
      if (map.containsKey('value')) {
        throw FormatException('$field cannot contain a value');
      }
      return state == BackupFactState.unsupported
          ? BackupFact<T>.unsupported()
          : BackupFact<T>.failed();
    }
    if (!map.containsKey('value')) {
      throw FormatException('$field is missing a value');
    }
    return BackupFact<T>.confirmed(decode(map['value']));
  }

  static BackupFact<ButtonConfig> _decodeButton(Object? source, String field) =>
      _decodeFact<ButtonConfig>(
        source,
        field,
        decode: (value) =>
            _enumValue(ButtonConfig.values, value, '$field.value'),
      );

  static void _validate(FullDeviceBackup backup) {
    if (backup.sourceDevice == ChameleonDevice.none ||
        backup.activeSlot < 0 ||
        backup.activeSlot >= 8 ||
        backup.positions.length != 8) {
      throw const FormatException('Invalid device backup envelope');
    }
    final indexes = <int>{};
    for (final position in backup.positions) {
      final slot = position.slot;
      SingleSlotBackupCodec.fromJson(SingleSlotBackupCodec.toJson(slot));
      if (slot.sourceDevice != backup.sourceDevice ||
          !indexes.add(slot.sourcePosition)) {
        throw const FormatException('Invalid or duplicate position record');
      }
      _validateCaptureState(position.hfState, slot.hf);
      _validateCaptureState(position.lfState, slot.lf);
    }
    if (!indexes.containsAll(List.generate(8, (index) => index))) {
      throw const FormatException('Device backup must contain positions 0-7');
    }
    final version = backup.firmware.version.value;
    if (version != null && (version < 0 || version > 0xffff)) {
      throw const FormatException('Invalid firmware version');
    }
    final commit = backup.firmware.commit.value;
    if (commit != null) {
      _safeCommit(commit);
    }
    final sleep = backup.preferences.sleepTimeoutSeconds.value;
    if (sleep != null && (sleep < 0 || sleep > 255)) {
      throw const FormatException('Invalid sleep timeout');
    }
  }

  static void _validateCaptureState(
    FullDeviceCaptureState state,
    SlotFrequencyBackup frequency,
  ) {
    final valid = switch (state) {
      FullDeviceCaptureState.complete =>
        frequency.state == SlotBackupCompleteness.complete ||
            frequency.state == SlotBackupCompleteness.empty,
      FullDeviceCaptureState.partial =>
        frequency.state == SlotBackupCompleteness.partial,
      FullDeviceCaptureState.unsupported =>
        frequency.state == SlotBackupCompleteness.unsupported,
      FullDeviceCaptureState.skipped ||
      FullDeviceCaptureState.failed =>
        frequency.state == SlotBackupCompleteness.unavailable,
    };
    if (!valid) {
      throw const FormatException('Capture report does not match slot record');
    }
  }

  static String _safeCommit(Object? value) {
    if (!isSafeFirmwareCommit(value)) {
      throw const FormatException('Invalid firmware commit');
    }
    return value as String;
  }

  static T _enumValue<T extends Enum>(
    Iterable<T> values,
    Object? source,
    String field,
  ) {
    if (source is! String) {
      throw FormatException('$field must be a string');
    }
    return values.where((value) => value.name == source).firstOrNull ??
        (throw FormatException('Invalid $field'));
  }

  static Map<String, dynamic> _map(Object? source, String field) {
    if (source is! Map<String, dynamic>) {
      throw FormatException('$field must be an object');
    }
    return source;
  }

  static List<dynamic> _list(Object? source, String field) {
    if (source is! List<dynamic>) {
      throw FormatException('$field must be a list');
    }
    return source;
  }

  static int _integer(Object? source, String field) {
    if (source is! int) {
      throw FormatException('$field must be an integer');
    }
    return source;
  }
}
