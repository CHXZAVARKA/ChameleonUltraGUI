import 'dart:typed_data';

import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';
import 'package:chameleonultragui/helpers/single_slot_backup.dart';
import 'package:chameleonultragui/helpers/slot_command_runner.dart';
import 'package:chameleonultragui/helpers/slot_payload.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/status/connected_device_status.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';

enum SlotWriteVerificationOutcome {
  verified,
  mismatch,
  incomplete,
  unknown,
  connectionChanged,
}

enum SlotWriteVerificationDetail {
  exactMatch,
  typeMismatch,
  anticollisionMismatch,
  expectedGeometryIncomplete,
  deviceGeometryIncomplete,
  payloadMismatch,
  metadataMismatch,
  comparisonUnavailable,
  connectionChanged,
}

class SlotWriteVerificationResult {
  const SlotWriteVerificationResult({
    required this.outcome,
    required this.detail,
  });

  const SlotWriteVerificationResult.verified()
      : this(
          outcome: SlotWriteVerificationOutcome.verified,
          detail: SlotWriteVerificationDetail.exactMatch,
        );

  const SlotWriteVerificationResult.connectionChanged()
      : this(
          outcome: SlotWriteVerificationOutcome.connectionChanged,
          detail: SlotWriteVerificationDetail.connectionChanged,
        );

  final SlotWriteVerificationOutcome outcome;
  final SlotWriteVerificationDetail detail;
}

class SlotWriteWorkflow {
  const SlotWriteWorkflow();

  Future<SlotWriteVerificationResult> upload({
    required ConnectedDeviceStatus status,
    required int position,
    required CardSave card,
    required String name,
    void Function(int progress)? onProgress,
    void Function()? onVerificationStarted,
  }) async {
    if (position < 0 ||
        position >= 8 ||
        !SlotPayloadWriter.supports(card.tag)) {
      return const SlotWriteVerificationResult(
        outcome: SlotWriteVerificationOutcome.unknown,
        detail: SlotWriteVerificationDetail.comparisonUnavailable,
      );
    }
    final targetType = _targetType(card);
    try {
      return await status.mutateSlots((mutation) async {
        await mutation.run(
          (communicator) => communicator.setReaderDeviceMode(false),
        );
        await SlotPayloadWriter.writeCard(
          runner: mutation,
          position: position,
          card: card,
          enabled: true,
          name: name,
          targetType: targetType,
          activateAfterEnable: true,
          onProgress: onProgress,
        );
        await mutation.run((communicator) => communicator.saveSlotData());
        onVerificationStarted?.call();
        return SlotWriteVerifier.verify(
          runner: mutation,
          position: position,
          card: card,
          targetType: targetType,
        );
      }, reconcileMode: true);
    } on SlotMutationConnectionChanged {
      return const SlotWriteVerificationResult.connectionChanged();
    } catch (_) {
      return status.isCurrentSession
          ? const SlotWriteVerificationResult(
              outcome: SlotWriteVerificationOutcome.unknown,
              detail: SlotWriteVerificationDetail.comparisonUnavailable,
            )
          : const SlotWriteVerificationResult.connectionChanged();
    }
  }

  TagType _targetType(CardSave card) {
    if (isEM410X(card.tag)) {
      return card.tag == TagType.em410XElectra
          ? TagType.em410XElectra
          : TagType.em410X;
    }
    return SlotPayloadWriter.targetTypeForCard(card);
  }
}

abstract final class SlotWriteVerifier {
  static const _bytes = ListEquality<int>();

  static Future<SlotWriteVerificationResult> verify({
    required SlotCommandRunner runner,
    required int position,
    required CardSave card,
    required TagType targetType,
  }) async {
    try {
      final types = await runner.run(
        (communicator) => communicator.getSlotTagTypes(),
      );
      if (types.length != 8 || position < 0 || position >= types.length) {
        return const SlotWriteVerificationResult(
          outcome: SlotWriteVerificationOutcome.incomplete,
          detail: SlotWriteVerificationDetail.deviceGeometryIncomplete,
        );
      }
      final frequency = chameleonTagToFrequency(targetType);
      final actualType = switch (frequency) {
        TagFrequency.hf => types[position].hf,
        TagFrequency.lf => types[position].lf,
        TagFrequency.unknown => TagType.unknown,
      };
      if (actualType != targetType) {
        return const SlotWriteVerificationResult(
          outcome: SlotWriteVerificationOutcome.mismatch,
          detail: SlotWriteVerificationDetail.typeMismatch,
        );
      }

      final actual = await SlotPayloadReader.read(
        runner: runner,
        type: actualType,
      );
      if (isMifareClassic(targetType)) {
        return _compareClassic(card, targetType, actual);
      }
      if (isMifareUltralight(targetType)) {
        return _compareUltralight(card, targetType, actual);
      }
      return _compareLf(card, targetType, actual);
    } on SlotCommandRunnerChanged {
      rethrow;
    } catch (_) {
      return const SlotWriteVerificationResult(
        outcome: SlotWriteVerificationOutcome.unknown,
        detail: SlotWriteVerificationDetail.comparisonUnavailable,
      );
    }
  }

  static SlotWriteVerificationResult _compareClassic(
    CardSave card,
    TagType type,
    SlotPayloadReadResult actual,
  ) {
    final CardData expectedAnticollision;
    try {
      expectedAnticollision = mifareClassicAntiCollisionForCard(card);
    } catch (_) {
      return _incomplete(
        SlotWriteVerificationDetail.expectedGeometryIncomplete,
      );
    }
    if (!_sameAnticollision(expectedAnticollision, actual.payload)) {
      return _mismatch(SlotWriteVerificationDetail.anticollisionMismatch);
    }
    final sourceGeometry = MifareClassicGeometry.fromSavedCardData(card);
    final targetGeometry = MifareClassicGeometry.fromType(
      chameleonTagTypeGetMfClassicType(type),
    );
    if (sourceGeometry == null ||
        targetGeometry == null ||
        SlotPayloadWriter.targetTypeForCard(card) != type ||
        sourceGeometry.blockCount > targetGeometry.blockCount) {
      return _incomplete(
        SlotWriteVerificationDetail.expectedGeometryIncomplete,
      );
    }
    if (!actual.structurallyComplete ||
        actual.payload.data.length != targetGeometry.blockCount ||
        actual.payload.data.any((block) => block.length != 16)) {
      return _incomplete(SlotWriteVerificationDetail.deviceGeometryIncomplete);
    }
    final expectedBlocks = List.generate(
      targetGeometry.blockCount,
      (block) => block < sourceGeometry.blockCount
          ? card.data[block]
          : _classicDefaultBlock(block),
    );
    if (_digest(expectedBlocks) != _digest(actual.payload.data)) {
      return _mismatch(SlotWriteVerificationDetail.payloadMismatch);
    }
    return const SlotWriteVerificationResult.verified();
  }

  static SlotWriteVerificationResult _compareUltralight(
    CardSave card,
    TagType type,
    SlotPayloadReadResult actual,
  ) {
    final expectedUid = _parseUid(card.uid);
    if (expectedUid == null || card.atqa.length != 2) {
      return _incomplete(
        SlotWriteVerificationDetail.expectedGeometryIncomplete,
      );
    }
    if (!_bytes.equals(expectedUid, actual.payload.uid) ||
        card.sak != actual.payload.sak ||
        !_bytes.equals(card.atqa, actual.payload.atqa)) {
      return _mismatch(SlotWriteVerificationDetail.anticollisionMismatch);
    }
    final pageCount = mfUltralightGetPagesCount(type);
    final counterCount =
        mfUltralightHasCounters(type) ? mfUltralightGetCounterCount(type) : 0;
    if (card.data.length != pageCount ||
        card.data.any((page) => page.length != 4) ||
        card.extraData.ultralightCounters.length != counterCount) {
      return _incomplete(
        SlotWriteVerificationDetail.expectedGeometryIncomplete,
      );
    }
    if (!actual.structurallyComplete ||
        actual.payload.data.length != pageCount ||
        actual.payload.data.any((page) => page.length != 4) ||
        actual.payload.ultralightCounters.length != counterCount) {
      return _incomplete(SlotWriteVerificationDetail.deviceGeometryIncomplete);
    }
    if (_digest(card.data) != _digest(actual.payload.data)) {
      return _mismatch(SlotWriteVerificationDetail.payloadMismatch);
    }
    if (!_bytes.equals(
          card.extraData.ultralightVersion,
          actual.payload.ultralightVersion,
        ) ||
        !_bytes.equals(
          card.extraData.ultralightSignature,
          actual.payload.ultralightSignature,
        ) ||
        !const ListEquality<int>().equals(
          card.extraData.ultralightCounters,
          actual.payload.ultralightCounters,
        )) {
      return _mismatch(SlotWriteVerificationDetail.metadataMismatch);
    }
    return const SlotWriteVerificationResult.verified();
  }

  static SlotWriteVerificationResult _compareLf(
    CardSave card,
    TagType type,
    SlotPayloadReadResult actual,
  ) {
    final expected = _lfIdentity(card, type);
    final expectedLength = type == TagType.hidProx ? 13 : uidSizeForLfTag(type);
    if (expected == null ||
        expectedLength <= 0 ||
        expected.length != expectedLength) {
      return _incomplete(
        SlotWriteVerificationDetail.expectedGeometryIncomplete,
      );
    }
    if (actual.payload.uid.length != expectedLength) {
      return _incomplete(SlotWriteVerificationDetail.deviceGeometryIncomplete);
    }
    if (!_bytes.equals(expected, actual.payload.uid)) {
      return _mismatch(SlotWriteVerificationDetail.payloadMismatch);
    }
    return const SlotWriteVerificationResult.verified();
  }

  static bool _sameAnticollision(CardData expected, SlotCardPayload actual) =>
      _bytes.equals(expected.uid, actual.uid) &&
      expected.sak == actual.sak &&
      _bytes.equals(expected.atqa, actual.atqa);

  static Uint8List? _lfIdentity(CardSave card, TagType type) {
    try {
      if (type == TagType.hidProx) {
        return hexToBytes(HIDCard.fromUID(card.uid).toString());
      }
      return hexToBytes(card.uid);
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _parseUid(String uid) {
    try {
      return hexToBytes(uid);
    } catch (_) {
      return null;
    }
  }

  // setDefaultDataToSlot initializes every unwritten Classic target block with
  // the firmware factory image before the source payload is copied over it.
  static Uint8List _classicDefaultBlock(int block) => Uint8List.fromList(
        (block < 128 && block % 4 == 3) || block % 16 == 15
            ? const [
                0xff,
                0xff,
                0xff,
                0xff,
                0xff,
                0xff,
                0xff,
                0x07,
                0x80,
                0x69,
                0xff,
                0xff,
                0xff,
                0xff,
                0xff,
                0xff,
              ]
            : List.filled(16, 0),
      );

  static String _digest(Iterable<Uint8List> chunks) =>
      sha256.convert(chunks.expand((chunk) => chunk).toList()).toString();

  static SlotWriteVerificationResult _mismatch(
    SlotWriteVerificationDetail detail,
  ) =>
      SlotWriteVerificationResult(
        outcome: SlotWriteVerificationOutcome.mismatch,
        detail: detail,
      );

  static SlotWriteVerificationResult _incomplete(
    SlotWriteVerificationDetail detail,
  ) =>
      SlotWriteVerificationResult(
        outcome: SlotWriteVerificationOutcome.incomplete,
        detail: detail,
      );
}
