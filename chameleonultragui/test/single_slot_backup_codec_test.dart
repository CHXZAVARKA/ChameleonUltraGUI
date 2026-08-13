import 'dart:convert';
import 'dart:typed_data';

import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/single_slot_backup.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('single-slot backup codec', () {
    test('round-trips a complete HF and LF bundle deterministically', () {
      final backup = SingleSlotBackup(
        sourceDevice: ChameleonDevice.ultra,
        sourcePosition: 2,
        createdAt: DateTime.utc(2026, 8, 13, 9, 30),
        hf: SlotFrequencyBackup.complete(
          frequency: TagFrequency.hf,
          type: TagType.mifareMini,
          enabled: true,
          name: 'Office',
          payload: SlotCardPayload(
            uid: Uint8List.fromList([1, 2, 3, 4]),
            sak: 0x09,
            atqa: Uint8List.fromList([0, 4]),
            ats: Uint8List(0),
            data: List.generate(
              20,
              (block) => Uint8List.fromList(
                List.generate(16, (offset) => block + offset),
              ),
            ),
            emulator: const SlotEmulatorMetadata(
              detectionEnabled: true,
              gen1aEnabled: false,
              gen2OrMagicEnabled: true,
              useFirstBlockCollision: true,
              writeMode: MifareWriteMode.shadow,
              prngType: Mf1PrngType.weak,
            ),
          ),
        ),
        lf: SlotFrequencyBackup.complete(
          frequency: TagFrequency.lf,
          type: TagType.em410X,
          enabled: false,
          name: 'Door',
          payload: SlotCardPayload(
            uid: Uint8List.fromList([1, 2, 3, 4, 5]),
          ),
        ),
      );

      final encoded = SingleSlotBackupCodec.encode(backup);
      final decoded = SingleSlotBackupCodec.decode(encoded);

      expect(SingleSlotBackupCodec.encode(decoded), encoded);
      expect(decoded.sourcePosition, 2);
      expect(decoded.hf.payload!.data, hasLength(20));
      expect(decoded.hf.payload!.data.last, backup.hf.payload!.data.last);
      expect(decoded.lf.enabled, isFalse);
      expect(decoded.lf.payload!.uid, backup.lf.payload!.uid);
    });

    test('rejects a changed payload digest', () {
      final encoded = SingleSlotBackupCodec.encode(
        SingleSlotBackup(
          sourceDevice: ChameleonDevice.ultra,
          sourcePosition: 0,
          createdAt: DateTime.utc(2026),
          hf: SlotFrequencyBackup.empty(
            frequency: TagFrequency.hf,
            enabled: false,
            name: '',
          ),
          lf: SlotFrequencyBackup.complete(
            frequency: TagFrequency.lf,
            type: TagType.em410X,
            enabled: true,
            name: 'Door',
            payload: SlotCardPayload(
              uid: Uint8List.fromList([1, 2, 3, 4, 5]),
            ),
          ),
        ),
      );
      final corrupted = encoded.replaceFirst('AQIDBAU=', 'AQIDBAY=');

      expect(
        () => SingleSlotBackupCodec.decode(corrupted),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects invalid schema, indexes, model, and geometry', () {
      String minimal({
        int version = 1,
        String model = 'ultra',
        int position = 0,
        String hf =
            '{"frequency":"hf","state":"empty","enabled":false,"name":""}',
      }) =>
          '{"format":"chameleon-ultra-slot-backup",'
          '"schemaVersion":$version,"createdAt":"2026-01-01T00:00:00.000Z",'
          '"sourceDevice":"$model","sourcePosition":$position,'
          '"frequencies":[$hf,'
          '{"frequency":"lf","state":"empty","enabled":false,"name":""}]}';

      expect(
        () => SingleSlotBackupCodec.decode(minimal(version: 2)),
        throwsFormatException,
      );
      expect(
        () => SingleSlotBackupCodec.decode(minimal(position: 8)),
        throwsFormatException,
      );
      expect(
        () => SingleSlotBackupCodec.decode(minimal(model: 'none')),
        throwsFormatException,
      );
      final validMini = SingleSlotBackupCodec.encode(
        SingleSlotBackup(
          sourceDevice: ChameleonDevice.ultra,
          sourcePosition: 0,
          createdAt: DateTime.utc(2026),
          hf: SlotFrequencyBackup.complete(
            frequency: TagFrequency.hf,
            type: TagType.mifareMini,
            enabled: true,
            name: 'Mini',
            payload: SlotCardPayload(
              uid: Uint8List.fromList([1, 2, 3, 4]),
              sak: 9,
              atqa: Uint8List.fromList([0, 4]),
              data: List.generate(20, (_) => Uint8List(16)),
              emulator: const SlotEmulatorMetadata(
                detectionEnabled: false,
                gen1aEnabled: false,
                gen2OrMagicEnabled: false,
                useFirstBlockCollision: false,
                writeMode: MifareWriteMode.normal,
                prngType: Mf1PrngType.weak,
              ),
            ),
          ),
          lf: SlotFrequencyBackup.empty(
            frequency: TagFrequency.lf,
            enabled: false,
            name: '',
          ),
        ),
      );
      final invalidGeometry = jsonDecode(validMini) as Map<String, dynamic>;
      final hf = (invalidGeometry['frequencies'] as List<dynamic>).first
          as Map<String, dynamic>;
      final payload = hf['payload'] as Map<String, dynamic>;
      payload['chunkCount'] = 19;
      payload['data'] = _binary(List.filled(19 * 16, 0));

      expect(
        () => SingleSlotBackupCodec.decode(jsonEncode(invalidGeometry)),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Invalid MIFARE Classic geometry',
          ),
        ),
      );

      expect(
        () => SingleSlotBackupCodec.encode(
          SingleSlotBackup(
            sourceDevice: ChameleonDevice.ultra,
            sourcePosition: 0,
            createdAt: DateTime.utc(2026),
            hf: SlotFrequencyBackup.complete(
              frequency: TagFrequency.hf,
              type: TagType.mifareMini,
              enabled: true,
              name: 'Missing metadata',
              payload: SlotCardPayload(
                uid: Uint8List.fromList([1, 2, 3, 4]),
                sak: 9,
                atqa: Uint8List.fromList([0, 4]),
                data: List.generate(20, (_) => Uint8List(16)),
              ),
            ),
            lf: SlotFrequencyBackup.empty(
              frequency: TagFrequency.lf,
              enabled: false,
              name: '',
            ),
          ),
        ),
        throwsFormatException,
      );
    });

    test('preserves explicit unavailable, unsupported, and partial states', () {
      final source = SingleSlotBackup(
        sourceDevice: ChameleonDevice.lite,
        sourcePosition: 7,
        createdAt: DateTime.utc(2026),
        hf: SlotFrequencyBackup.partial(
          frequency: TagFrequency.hf,
          type: TagType.ntag213,
          enabled: true,
          name: 'Partial',
          payload: SlotCardPayload(
            uid: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]),
            data: [
              Uint8List.fromList([1, 2])
            ],
          ),
        ),
        lf: const SlotFrequencyBackup.unavailable(
          frequency: TagFrequency.lf,
        ),
      );

      final decoded = SingleSlotBackupCodec.decode(
        SingleSlotBackupCodec.encode(source),
      );

      expect(decoded.hf.state, SlotBackupCompleteness.partial);
      expect(decoded.lf.state, SlotBackupCompleteness.unavailable);
      expect(decoded.isRestorable, isFalse);

      final unsupported = SingleSlotBackupCodec.decode(
        SingleSlotBackupCodec.encode(
          SingleSlotBackup(
            sourceDevice: ChameleonDevice.ultra,
            sourcePosition: 1,
            createdAt: DateTime.utc(2026),
            hf: SlotFrequencyBackup.unsupported(
              frequency: TagFrequency.hf,
              type: TagType.mifare1K,
              enabled: true,
              name: 'Unsupported by this build',
            ),
            lf: SlotFrequencyBackup.empty(
              frequency: TagFrequency.lf,
              enabled: false,
              name: '',
            ),
          ),
        ),
      );
      expect(unsupported.hf.state, SlotBackupCompleteness.unsupported);
      expect(unsupported.isRestorable, isFalse);
    });

    test('ignores unknown future fields in schema version one', () {
      final source = SingleSlotBackupCodec.encode(
        SingleSlotBackup(
          sourceDevice: ChameleonDevice.ultra,
          sourcePosition: 0,
          createdAt: DateTime.utc(2026),
          hf: SlotFrequencyBackup.empty(
            frequency: TagFrequency.hf,
            enabled: false,
            name: '',
          ),
          lf: SlotFrequencyBackup.empty(
            frequency: TagFrequency.lf,
            enabled: false,
            name: '',
          ),
        ),
      );
      final extended = source.replaceFirst(
        '"sourcePosition":0,',
        '"sourcePosition":0,"futureField":{"nested":true},',
      );

      final decoded = SingleSlotBackupCodec.decode(extended);

      expect(decoded.sourcePosition, 0);
      expect(decoded.isRestorable, isTrue);
    });
  });
}

Map<String, Object> _binary(List<int> bytes) => {
      'encoding': 'base64',
      'length': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
      'data': base64Encode(bytes),
    };
