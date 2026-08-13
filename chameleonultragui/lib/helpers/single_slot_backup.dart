import 'dart:convert';
import 'dart:typed_data';

import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/card_profile.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';
import 'package:crypto/crypto.dart';

const singleSlotBackupFormat = 'chameleon-ultra-slot-backup';
const singleSlotBackupSchemaVersion = 1;

enum SlotBackupCompleteness {
  empty,
  complete,
  partial,
  unavailable,
  unsupported,
}

class SlotCardPayload {
  SlotCardPayload({
    required Uint8List uid,
    this.sak = 0,
    Uint8List? atqa,
    Uint8List? ats,
    List<Uint8List> data = const [],
    Uint8List? ultralightVersion,
    Uint8List? ultralightSignature,
    List<int> ultralightCounters = const [],
    List<bool> ultralightTearingStates = const [],
    this.emulator,
  })  : atqa = Uint8List.fromList(atqa ?? const []),
        ats = Uint8List.fromList(ats ?? const []),
        data = List.unmodifiable(data.map(Uint8List.fromList)),
        ultralightVersion = Uint8List.fromList(ultralightVersion ?? const []),
        ultralightSignature =
            Uint8List.fromList(ultralightSignature ?? const []),
        ultralightCounters = List.unmodifiable(ultralightCounters),
        ultralightTearingStates = List.unmodifiable(ultralightTearingStates),
        uid = Uint8List.fromList(uid);

  final Uint8List uid;
  final int sak;
  final Uint8List atqa;
  final Uint8List ats;
  final List<Uint8List> data;
  final Uint8List ultralightVersion;
  final Uint8List ultralightSignature;
  final List<int> ultralightCounters;
  final List<bool> ultralightTearingStates;
  final SlotEmulatorMetadata? emulator;
}

class SlotEmulatorMetadata {
  const SlotEmulatorMetadata({
    required this.detectionEnabled,
    required this.gen1aEnabled,
    required this.gen2OrMagicEnabled,
    required this.useFirstBlockCollision,
    required this.writeMode,
    this.prngType,
  });

  final bool detectionEnabled;
  final bool gen1aEnabled;
  final bool gen2OrMagicEnabled;
  final bool useFirstBlockCollision;
  final MifareWriteMode writeMode;
  final Mf1PrngType? prngType;
}

class SlotFrequencyBackup {
  const SlotFrequencyBackup._({
    required this.frequency,
    required this.state,
    this.type,
    this.enabled,
    this.name,
    this.payload,
  });

  factory SlotFrequencyBackup.complete({
    required TagFrequency frequency,
    required TagType type,
    required bool enabled,
    required String name,
    required SlotCardPayload payload,
  }) =>
      SlotFrequencyBackup._(
        frequency: frequency,
        state: SlotBackupCompleteness.complete,
        type: type,
        enabled: enabled,
        name: name,
        payload: payload,
      );

  factory SlotFrequencyBackup.partial({
    required TagFrequency frequency,
    TagType? type,
    bool? enabled,
    String? name,
    SlotCardPayload? payload,
  }) =>
      SlotFrequencyBackup._(
        frequency: frequency,
        state: SlotBackupCompleteness.partial,
        type: type,
        enabled: enabled,
        name: name,
        payload: payload,
      );

  factory SlotFrequencyBackup.empty({
    required TagFrequency frequency,
    required bool enabled,
    required String name,
  }) =>
      SlotFrequencyBackup._(
        frequency: frequency,
        state: SlotBackupCompleteness.empty,
        type: TagType.unknown,
        enabled: enabled,
        name: name,
      );

  const factory SlotFrequencyBackup.unavailable({
    required TagFrequency frequency,
  }) = _UnavailableSlotFrequencyBackup;

  factory SlotFrequencyBackup.unsupported({
    required TagFrequency frequency,
    required TagType type,
    required bool enabled,
    required String name,
  }) =>
      SlotFrequencyBackup._(
        frequency: frequency,
        state: SlotBackupCompleteness.unsupported,
        type: type,
        enabled: enabled,
        name: name,
      );

  final TagFrequency frequency;
  final SlotBackupCompleteness state;
  final TagType? type;
  final bool? enabled;
  final String? name;
  final SlotCardPayload? payload;

  bool get isRestorable =>
      state == SlotBackupCompleteness.empty ||
      state == SlotBackupCompleteness.complete;
}

class _UnavailableSlotFrequencyBackup extends SlotFrequencyBackup {
  const _UnavailableSlotFrequencyBackup({required super.frequency})
      : super._(state: SlotBackupCompleteness.unavailable);
}

class SingleSlotBackup {
  SingleSlotBackup({
    required this.sourceDevice,
    required this.sourcePosition,
    required DateTime createdAt,
    required this.hf,
    required this.lf,
  })  : createdAt = createdAt.toUtc(),
        assert(hf.frequency == TagFrequency.hf),
        assert(lf.frequency == TagFrequency.lf);

  final ChameleonDevice sourceDevice;
  final int sourcePosition;
  final DateTime createdAt;
  final SlotFrequencyBackup hf;
  final SlotFrequencyBackup lf;

  bool get isRestorable => hf.isRestorable && lf.isRestorable;
}

abstract final class SingleSlotBackupCodec {
  static void validateFrequency(SlotFrequencyBackup frequency) {
    _validateFrequency(frequency);
  }

  static String encode(SingleSlotBackup backup) {
    return jsonEncode(toJson(backup));
  }

  static Map<String, Object?> toJson(SingleSlotBackup backup) {
    _validateEnvelope(backup);
    return {
      'format': singleSlotBackupFormat,
      'schemaVersion': singleSlotBackupSchemaVersion,
      'createdAt': backup.createdAt.toIso8601String(),
      'sourceDevice': backup.sourceDevice.name,
      'sourcePosition': backup.sourcePosition,
      'frequencies': [
        _encodeFrequency(backup.hf),
        _encodeFrequency(backup.lf),
      ],
    };
  }

  static SingleSlotBackup decode(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } catch (_) {
      throw const FormatException('Backup is not valid JSON');
    }
    return fromJson(decoded);
  }

  static SingleSlotBackup fromJson(Object? source) {
    final root = _map(source, 'backup');
    if (root['format'] != singleSlotBackupFormat) {
      throw const FormatException('Unsupported backup format');
    }
    if (root['schemaVersion'] != singleSlotBackupSchemaVersion) {
      throw const FormatException('Unsupported backup schema');
    }
    final device = ChameleonDevice.values
        .where((device) => device.name == root['sourceDevice'])
        .firstOrNull;
    if (device == null || device == ChameleonDevice.none) {
      throw const FormatException('Invalid source device');
    }
    final position = _integer(root['sourcePosition'], 'sourcePosition');
    if (position < 0 || position >= 8) {
      throw const FormatException('Invalid source position');
    }
    final createdAtSource = root['createdAt'];
    final createdAt =
        createdAtSource is String ? DateTime.tryParse(createdAtSource) : null;
    if (createdAt == null) {
      throw const FormatException('Invalid creation time');
    }
    final frequencies = _list(root['frequencies'], 'frequencies');
    if (frequencies.length != 2) {
      throw const FormatException('A slot must contain HF and LF records');
    }
    final parsed = frequencies.map(_decodeFrequency).toList();
    final hf = parsed.where((item) => item.frequency == TagFrequency.hf);
    final lf = parsed.where((item) => item.frequency == TagFrequency.lf);
    if (hf.length != 1 || lf.length != 1) {
      throw const FormatException('Duplicate or missing frequency record');
    }
    final backup = SingleSlotBackup(
      sourceDevice: device,
      sourcePosition: position,
      createdAt: createdAt,
      hf: hf.single,
      lf: lf.single,
    );
    _validateEnvelope(backup);
    return backup;
  }

  static Map<String, Object?> _encodeFrequency(SlotFrequencyBackup frequency) {
    return {
      'frequency': frequency.frequency.name,
      'state': frequency.state.name,
      if (frequency.type != null) 'type': frequency.type!.value,
      if (frequency.enabled != null) 'enabled': frequency.enabled,
      if (frequency.name != null) 'name': frequency.name,
      if (frequency.payload != null)
        'payload': _encodePayload(frequency.payload!),
    };
  }

  static Map<String, Object?> _encodePayload(SlotCardPayload payload) {
    final flatData = Uint8List.fromList(
      payload.data.expand((chunk) => chunk).toList(),
    );
    final chunkSize = payload.data.isEmpty ? 0 : payload.data.first.length;
    return {
      'uid': _encodeBytes(payload.uid),
      'sak': payload.sak,
      'atqa': _encodeBytes(payload.atqa),
      'ats': _encodeBytes(payload.ats),
      'chunkSize': chunkSize,
      'chunkCount': payload.data.length,
      'data': _encodeBytes(flatData),
      'ultralightVersion': _encodeBytes(payload.ultralightVersion),
      'ultralightSignature': _encodeBytes(payload.ultralightSignature),
      'ultralightCounters': payload.ultralightCounters,
      'ultralightTearingStates': payload.ultralightTearingStates,
      if (payload.emulator != null)
        'emulator': {
          'detectionEnabled': payload.emulator!.detectionEnabled,
          'gen1aEnabled': payload.emulator!.gen1aEnabled,
          'gen2OrMagicEnabled': payload.emulator!.gen2OrMagicEnabled,
          'useFirstBlockCollision': payload.emulator!.useFirstBlockCollision,
          'writeMode': payload.emulator!.writeMode.name,
          if (payload.emulator!.prngType != null)
            'prngType': payload.emulator!.prngType!.name,
        },
    };
  }

  static Map<String, Object?> _encodeBytes(Uint8List bytes) => {
        'encoding': 'base64',
        'length': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
        'data': base64Encode(bytes),
      };

  static SlotFrequencyBackup _decodeFrequency(Object? source) {
    final map = _map(source, 'frequency');
    final frequency = TagFrequency.values
        .where((frequency) => frequency.name == map['frequency'])
        .firstOrNull;
    if (frequency != TagFrequency.hf && frequency != TagFrequency.lf) {
      throw const FormatException('Invalid frequency');
    }
    final state = SlotBackupCompleteness.values
        .where((state) => state.name == map['state'])
        .firstOrNull;
    if (state == null) {
      throw const FormatException('Invalid completeness state');
    }
    final typeValue = map['type'];
    final type = typeValue == null
        ? null
        : TagType.values.where((type) => type.value == typeValue).firstOrNull;
    if (typeValue != null && type == null) {
      throw const FormatException('Invalid tag type');
    }
    final enabled = map['enabled'];
    if (enabled != null && enabled is! bool) {
      throw const FormatException('Invalid enabled state');
    }
    final name = map['name'];
    if (name != null && name is! String) {
      throw const FormatException('Invalid slot name');
    }
    final payload = map['payload'] == null
        ? null
        : _decodePayload(_map(map['payload'], 'payload'));
    return SlotFrequencyBackup._(
      frequency: frequency!,
      state: state,
      type: type,
      enabled: enabled as bool?,
      name: name as String?,
      payload: payload,
    );
  }

  static SlotCardPayload _decodePayload(Map<String, dynamic> map) {
    final chunkSize = _integer(map['chunkSize'], 'chunkSize');
    final chunkCount = _integer(map['chunkCount'], 'chunkCount');
    if (chunkSize < 0 || chunkCount < 0 || (chunkCount > 0 && chunkSize <= 0)) {
      throw const FormatException('Invalid payload chunk geometry');
    }
    final flatData = _decodeBytes(map['data'], 'data');
    if (flatData.length != chunkSize * chunkCount) {
      throw const FormatException('Payload chunk geometry does not match');
    }
    final chunks = List.generate(
      chunkCount,
      (index) => Uint8List.fromList(
        flatData.sublist(index * chunkSize, (index + 1) * chunkSize),
      ),
    );
    final counters = _list(map['ultralightCounters'], 'ultralightCounters')
        .map((value) => _integer(value, 'ultralightCounter'))
        .toList();
    final tearingStates =
        _list(map['ultralightTearingStates'], 'ultralightTearingStates')
            .map((value) {
      if (value is! bool) {
        throw const FormatException(
          'ultralightTearingState must be a boolean',
        );
      }
      return value;
    }).toList();
    final emulator = map['emulator'] == null
        ? null
        : _decodeEmulator(_map(map['emulator'], 'emulator'));
    return SlotCardPayload(
      uid: _decodeBytes(map['uid'], 'uid'),
      sak: _integer(map['sak'], 'sak'),
      atqa: _decodeBytes(map['atqa'], 'atqa'),
      ats: _decodeBytes(map['ats'], 'ats'),
      data: chunks,
      ultralightVersion:
          _decodeBytes(map['ultralightVersion'], 'ultralightVersion'),
      ultralightSignature:
          _decodeBytes(map['ultralightSignature'], 'ultralightSignature'),
      ultralightCounters: counters,
      ultralightTearingStates: tearingStates,
      emulator: emulator,
    );
  }

  static SlotEmulatorMetadata _decodeEmulator(Map<String, dynamic> map) {
    bool boolean(String name) {
      final value = map[name];
      if (value is! bool) {
        throw FormatException('$name must be a boolean');
      }
      return value;
    }

    final writeMode = MifareWriteMode.values
        .where((mode) => mode.name == map['writeMode'])
        .firstOrNull;
    if (writeMode == null) {
      throw const FormatException('Invalid emulator write mode');
    }
    final prngSource = map['prngType'];
    final prngType = prngSource == null
        ? null
        : Mf1PrngType.values
            .where((type) => type.name == prngSource)
            .firstOrNull;
    if (prngSource != null && prngType == null) {
      throw const FormatException('Invalid emulator PRNG type');
    }
    return SlotEmulatorMetadata(
      detectionEnabled: boolean('detectionEnabled'),
      gen1aEnabled: boolean('gen1aEnabled'),
      gen2OrMagicEnabled: boolean('gen2OrMagicEnabled'),
      useFirstBlockCollision: boolean('useFirstBlockCollision'),
      writeMode: writeMode,
      prngType: prngType,
    );
  }

  static Uint8List _decodeBytes(Object? source, String field) {
    final map = _map(source, field);
    if (map['encoding'] != 'base64') {
      throw FormatException('$field uses an unsupported encoding');
    }
    final declaredLength = _integer(map['length'], '$field.length');
    final encoded = map['data'];
    if (encoded is! String) {
      throw FormatException('$field data is invalid');
    }
    final Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } catch (_) {
      throw FormatException('$field data is invalid');
    }
    if (bytes.length != declaredLength) {
      throw FormatException('$field length does not match');
    }
    if (map['sha256'] != sha256.convert(bytes).toString()) {
      throw FormatException('$field digest does not match');
    }
    return bytes;
  }

  static void _validateEnvelope(SingleSlotBackup backup) {
    if (backup.sourceDevice == ChameleonDevice.none) {
      throw const FormatException('Invalid source device');
    }
    if (backup.sourcePosition < 0 || backup.sourcePosition >= 8) {
      throw const FormatException('Invalid source position');
    }
    _validateFrequency(backup.hf);
    _validateFrequency(backup.lf);
  }

  static void _validateFrequency(SlotFrequencyBackup frequency) {
    final complete = frequency.state == SlotBackupCompleteness.complete;
    final empty = frequency.state == SlotBackupCompleteness.empty;
    if (empty) {
      if (frequency.type != TagType.unknown ||
          frequency.enabled == null ||
          frequency.name == null ||
          frequency.payload != null) {
        throw const FormatException('Invalid empty frequency record');
      }
      return;
    }
    if (complete) {
      final type = frequency.type;
      final payload = frequency.payload;
      if (type == null ||
          type == TagType.unknown ||
          frequency.enabled == null ||
          frequency.name == null ||
          payload == null ||
          chameleonTagToFrequency(type) != frequency.frequency) {
        throw const FormatException('Invalid complete frequency record');
      }
      _validateCompletePayload(type, payload);
      return;
    }
    if (frequency.state == SlotBackupCompleteness.unsupported &&
        (frequency.type == null ||
            frequency.enabled == null ||
            frequency.name == null ||
            frequency.payload != null ||
            chameleonTagToFrequency(frequency.type!) != frequency.frequency)) {
      throw const FormatException('Invalid unsupported frequency record');
    }
    if (frequency.state == SlotBackupCompleteness.unavailable &&
        (frequency.type != null ||
            frequency.enabled != null ||
            frequency.name != null ||
            frequency.payload != null)) {
      throw const FormatException('Invalid unavailable frequency record');
    }
  }

  static void _validateCompletePayload(TagType type, SlotCardPayload payload) {
    if (payload.sak < 0 || payload.sak > 255) {
      throw const FormatException('Invalid SAK');
    }
    if (isMifareClassic(type)) {
      final expected = mfClassicGetBlockCount(
        chameleonTagTypeGetMfClassicType(type),
      );
      if (!validUidLengthsForTagType(type).contains(payload.uid.length) ||
          payload.atqa.length != 2 ||
          payload.emulator == null ||
          payload.emulator!.prngType == null ||
          payload.data.length != expected ||
          payload.data.any((block) => block.length != 16)) {
        throw const FormatException('Invalid MIFARE Classic geometry');
      }
      return;
    }
    if (isMifareUltralight(type)) {
      if (!validUidLengthsForTagType(type).contains(payload.uid.length) ||
          payload.atqa.length != 2 ||
          payload.emulator == null ||
          payload.data.length != mfUltralightGetPagesCount(type) ||
          payload.data.any((page) => page.length != 4)) {
        throw const FormatException('Invalid MIFARE Ultralight geometry');
      }
      final expectedCounters =
          mfUltralightHasCounters(type) ? mfUltralightGetCounterCount(type) : 0;
      if (payload.ultralightCounters.length != expectedCounters ||
          payload.ultralightTearingStates.length != expectedCounters ||
          payload.ultralightTearingStates.any((state) => !state)) {
        throw const FormatException('Invalid MIFARE Ultralight metadata');
      }
      return;
    }
    final uidLength = type == TagType.hidProx ? 13 : uidSizeForLfTag(type);
    if (uidLength <= 0 || payload.uid.length != uidLength) {
      throw const FormatException('Invalid LF identity geometry');
    }
    if (payload.data.isNotEmpty) {
      throw const FormatException('LF identity cannot contain page data');
    }
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
