import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

const String mifareClassicKeyProfileFormat =
    'chameleon-ultra-gui-mf1-key-profile';
const int mifareClassicKeyProfileVersion = 1;
const Set<String> mifareClassicKeyProfileCardTypes = {
  'mini',
  'm1k',
  'm2k',
  'm4k',
};

String _bytesToUpperHex(Uint8List bytes) => bytes
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join()
    .toUpperCase();

Uint8List _keyFromHex(Object? value, String field) {
  if (value is! String || !RegExp(r'^[0-9a-fA-F]{12}$').hasMatch(value)) {
    throw FormatException('$field must contain exactly 6 hexadecimal bytes');
  }

  return Uint8List.fromList([
    for (var index = 0; index < value.length; index += 2)
      int.parse(value.substring(index, index + 2), radix: 16),
  ]);
}

String? normalizeMifareClassicProfileUid(String? uid) {
  if (uid == null || uid.trim().isEmpty) {
    return null;
  }

  if (!RegExp(r'^[0-9a-fA-F\s:-]+$').hasMatch(uid)) {
    throw const FormatException('UID must contain hexadecimal bytes');
  }
  final normalized = uid.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
  if (normalized.isEmpty ||
      normalized.length.isOdd ||
      !RegExp(r'^[0-9A-F]+$').hasMatch(normalized)) {
    throw const FormatException('UID must contain hexadecimal bytes');
  }
  return normalized;
}

class MifareClassicKeyAssignment {
  final int sector;
  final Uint8List? keyA;
  final Uint8List? keyB;

  MifareClassicKeyAssignment({
    required this.sector,
    Uint8List? keyA,
    Uint8List? keyB,
  })  : keyA = _validatedKey(keyA, 'keyA'),
        keyB = _validatedKey(keyB, 'keyB') {
    if (keyA == null && keyB == null) {
      throw const FormatException(
          'A sector assignment must contain Key A or Key B');
    }
  }

  static Uint8List? _validatedKey(Uint8List? key, String field) {
    if (key == null) {
      return null;
    }
    if (key.length != 6) {
      throw FormatException('$field must contain exactly 6 bytes');
    }
    return Uint8List.fromList(key);
  }

  Uint8List? keyForType(int keyType) {
    if (keyType == 0) {
      return keyA == null ? null : Uint8List.fromList(keyA!);
    }
    if (keyType == 1) {
      return keyB == null ? null : Uint8List.fromList(keyB!);
    }
    throw RangeError.range(keyType, 0, 1, 'keyType');
  }
}

class MifareClassicKeyUsage {
  final Uint8List key;
  final List<int> keyASectors;
  final List<int> keyBSectors;

  MifareClassicKeyUsage({
    required Uint8List key,
    required List<int> keyASectors,
    required List<int> keyBSectors,
  })  : key = Uint8List.fromList(key),
        keyASectors = List.unmodifiable(List<int>.from(keyASectors)..sort()),
        keyBSectors = List.unmodifiable(List<int>.from(keyBSectors)..sort());

  String get keyHex => _bytesToUpperHex(key);

  Map<String, dynamic> toMap() => {
        'key': keyHex,
        'keyA': keyASectors,
        'keyB': keyBSectors,
      };
}

class MifareClassicKeyProfile {
  final String id;
  final String name;
  final String cardType;
  final int sectorCount;
  final String? uid;
  final List<MifareClassicKeyAssignment> assignments;

  MifareClassicKeyProfile({
    String? id,
    required this.name,
    required this.cardType,
    required this.sectorCount,
    String? uid,
    required List<MifareClassicKeyAssignment> assignments,
  })  : id = id ?? const Uuid().v4(),
        uid = normalizeMifareClassicProfileUid(uid),
        assignments = List.unmodifiable(List<MifareClassicKeyAssignment>.from(
            assignments)
          ..sort((first, second) => first.sector.compareTo(second.sector))) {
    if (name.trim().isEmpty) {
      throw const FormatException('Profile name cannot be empty');
    }
    if (this.id.trim().isEmpty) {
      throw const FormatException('Profile id cannot be empty');
    }
    if (!mifareClassicKeyProfileCardTypes.contains(cardType)) {
      throw const FormatException('Unsupported MIFARE Classic card type');
    }
    if (sectorCount < 1 || sectorCount > 40) {
      throw RangeError.range(sectorCount, 1, 40, 'sectorCount');
    }

    final sectors = <int>{};
    for (final assignment in assignments) {
      if (assignment.sector < 0 || assignment.sector >= sectorCount) {
        throw RangeError.range(
            assignment.sector, 0, sectorCount - 1, 'assignment.sector');
      }
      if (!sectors.add(assignment.sector)) {
        throw FormatException(
            'Sector ${assignment.sector} is assigned more than once');
      }
    }
  }

  factory MifareClassicKeyProfile.fromJson(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != mifareClassicKeyProfileFormat ||
        decoded['version'] != mifareClassicKeyProfileVersion) {
      throw const FormatException('Unsupported MIFARE Classic key profile');
    }

    final assignments = _assignmentsFromProfileMap(decoded);

    return MifareClassicKeyProfile(
      id: decoded['id'] as String?,
      name: decoded['name'] as String,
      cardType: decoded['cardType'] as String,
      sectorCount: decoded['sectorCount'] as int,
      uid: decoded['uid'] as String?,
      assignments: assignments,
    );
  }

  int get keyCount => assignments.fold(
      0,
      (count, assignment) =>
          count +
          (assignment.keyA == null ? 0 : 1) +
          (assignment.keyB == null ? 0 : 1));

  List<MifareClassicKeyUsage> get keyUsages {
    final grouped = <String, MifareClassicKeyUsage>{};
    final keyASectors = <String, List<int>>{};
    final keyBSectors = <String, List<int>>{};

    for (final assignment in assignments) {
      void addKey(Uint8List? key, Map<String, List<int>> sectors) {
        if (key == null) {
          return;
        }
        final keyHex = _bytesToUpperHex(key);
        grouped.putIfAbsent(
          keyHex,
          () => MifareClassicKeyUsage(
            key: key,
            keyASectors: const [],
            keyBSectors: const [],
          ),
        );
        sectors.putIfAbsent(keyHex, () => <int>[]).add(assignment.sector);
      }

      addKey(assignment.keyA, keyASectors);
      addKey(assignment.keyB, keyBSectors);
    }

    return [
      for (final entry in grouped.entries)
        MifareClassicKeyUsage(
          key: entry.value.key,
          keyASectors: keyASectors[entry.key] ?? const [],
          keyBSectors: keyBSectors[entry.key] ?? const [],
        ),
    ];
  }

  bool isCompatible({required String cardType, required int sectorCount}) =>
      this.cardType == cardType && this.sectorCount == sectorCount;

  bool matchesUid(String otherUid) =>
      uid != null && uid == normalizeMifareClassicProfileUid(otherUid);

  Uint8List? assignedKey(int sector, int keyType) {
    for (final assignment in assignments) {
      if (assignment.sector == sector) {
        return assignment.keyForType(keyType);
      }
    }
    return null;
  }

  String toJson() => jsonEncode({
        'format': mifareClassicKeyProfileFormat,
        'version': mifareClassicKeyProfileVersion,
        'id': id,
        'name': name,
        'cardType': cardType,
        'sectorCount': sectorCount,
        'uid': uid,
        'keys': keyUsages.map((usage) => usage.toMap()).toList(),
      });

  Uint8List toFile() => Uint8List.fromList(utf8.encode(toJson()));

  static List<MifareClassicKeyAssignment> _assignmentsFromProfileMap(
      Map<String, dynamic> decoded) {
    final compactKeys = decoded['keys'];
    if (compactKeys is! List<dynamic>) {
      throw const FormatException('keys must be a list');
    }
    final bySector = <int, Map<String, Uint8List>>{};
    for (final item in compactKeys) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Invalid compact key entry');
      }
      final key = _keyFromHex(item['key'], 'key');
      for (final keyType in ['keyA', 'keyB']) {
        final sectors = item[keyType];
        if (sectors is! List<dynamic>) {
          throw FormatException('$keyType must be a list of sectors');
        }
        for (final sector in sectors) {
          if (sector is! int) {
            throw const FormatException('Sector must be an integer');
          }
          final assignment =
              bySector.putIfAbsent(sector, () => <String, Uint8List>{});
          if (assignment.containsKey(keyType)) {
            throw FormatException(
                'Sector $sector has more than one $keyType assignment');
          }
          assignment[keyType] = key;
        }
      }
    }

    final sectors = bySector.keys.toList()..sort();
    return sectors
        .map((sector) => MifareClassicKeyAssignment(
              sector: sector,
              keyA: bySector[sector]!['keyA'],
              keyB: bySector[sector]!['keyB'],
            ))
        .toList();
  }
}
