import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/dump_analyzer.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';

enum MifareClassicMaintenanceFailure {
  invalidImage,
  incompatibleProfile,
  communicationLost,
  stalePlan,
  noCard,
  wrongCardType,
  identityMismatch,
  authenticationFailed,
  readFailed,
  invalidAccessBits,
  writeNotAllowed,
  verificationNotAllowed,
  writeFailed,
  verificationFailed,
  cancelled,
}

enum MifareClassicWriteOutcome { notAttempted, rejected, unknown }

class MifareClassicMaintenanceException implements Exception {
  final MifareClassicMaintenanceFailure failure;
  final String message;
  final int? sector;
  final int? block;
  final int? status;
  final int verifiedBlocks;
  final MifareClassicWriteOutcome writeOutcome;

  const MifareClassicMaintenanceException(
    this.failure,
    this.message, {
    this.sector,
    this.block,
    this.status,
    this.verifiedBlocks = 0,
    this.writeOutcome = MifareClassicWriteOutcome.notAttempted,
  });

  @override
  String toString() {
    final details = [
      if (sector != null) 'sector $sector',
      if (block != null) 'block $block',
      if (status != null)
        'status 0x${status!.toRadixString(16).padLeft(2, '0')}',
      if (verifiedBlocks > 0 ||
          writeOutcome == MifareClassicWriteOutcome.unknown)
        '$verifiedBlocks ${verifiedBlocks == 1 ? 'block' : 'blocks'} verified',
      if (writeOutcome == MifareClassicWriteOutcome.unknown)
        'write outcome unknown',
    ].join(', ');
    return details.isEmpty ? message : '$message ($details)';
  }
}

class MifareClassicIoResult {
  final int status;
  final Uint8List data;

  MifareClassicIoResult({required this.status, Uint8List? data})
      : data = Uint8List.fromList(data ?? Uint8List(0));

  bool get isSuccess => status == 0;
}

abstract class MifareClassicMaintenancePort {
  Future<void> ensureReaderMode();

  Future<CardData?> scan();

  Future<MifareClassicType> detectType();

  Future<bool> isBlockAvailable(int block);

  Future<MifareClassicIoResult> authenticate(
      int block, int keyType, Uint8List key);

  Future<MifareClassicIoResult> readBlock(
      int block, int keyType, Uint8List key);

  Future<MifareClassicIoResult> writeBlock(
      int block, int keyType, Uint8List key, Uint8List data);
}

class ChameleonMifareClassicMaintenancePort
    implements MifareClassicMaintenancePort {
  final ChameleonCommunicator communicator;

  ChameleonMifareClassicMaintenancePort(this.communicator);

  @override
  Future<void> ensureReaderMode() async {
    if (!await communicator.isReaderDeviceMode()) {
      await communicator.setReaderDeviceMode(true);
    }
  }

  @override
  Future<CardData?> scan() => communicator.scan14443aTag();

  @override
  Future<MifareClassicType> detectType() async {
    if (!await communicator.detectMf1Support()) {
      return MifareClassicType.none;
    }
    return mfClassicGetType(communicator);
  }

  @override
  Future<bool> isBlockAvailable(int block) async =>
      (await communicator.send14ARaw(
        Uint8List.fromList([0x60, block]),
        checkResponseCrc: false,
      ))
          .length ==
      4;

  @override
  Future<MifareClassicIoResult> authenticate(
      int block, int keyType, Uint8List key) async {
    final result = await communicator.mf1AuthResult(block, keyType, key);
    return MifareClassicIoResult(status: result.status, data: result.data);
  }

  @override
  Future<MifareClassicIoResult> readBlock(
      int block, int keyType, Uint8List key) async {
    final result = await communicator.mf1ReadBlockResult(block, keyType, key);
    return MifareClassicIoResult(status: result.status, data: result.data);
  }

  @override
  Future<MifareClassicIoResult> writeBlock(
      int block, int keyType, Uint8List key, Uint8List data) async {
    final result =
        await communicator.mf1WriteBlockResult(block, keyType, key, data);
    return MifareClassicIoResult(status: result.status, data: result.data);
  }
}

class _MifareClassicCredential {
  final int keyType;
  final Uint8List key;

  _MifareClassicCredential({required this.keyType, required Uint8List key})
      : key = Uint8List.fromList(key);
}

class _MifareClassicMaintenanceOperation {
  final int sector;
  final int block;
  final Uint8List expectedData;
  final Uint8List targetData;
  final _MifareClassicCredential writeCredential;
  final _MifareClassicCredential readCredential;

  _MifareClassicMaintenanceOperation({
    required this.sector,
    required this.block,
    required Uint8List expectedData,
    required Uint8List targetData,
    required this.writeCredential,
    required this.readCredential,
  })  : expectedData = Uint8List.fromList(expectedData),
        targetData = Uint8List.fromList(targetData);
}

class _MifareClassicMaintenancePrecondition {
  final int sector;
  final int block;
  final Uint8List expectedData;
  final _MifareClassicCredential readCredential;

  _MifareClassicMaintenancePrecondition({
    required this.sector,
    required this.block,
    required Uint8List expectedData,
    required this.readCredential,
  }) : expectedData = Uint8List.fromList(expectedData);
}

class MifareClassicMaintenancePlan {
  bool _claimed = false;
  final Object _ownerToken;
  final MifareClassicGeometry _geometry;
  final Uint8List _expectedUid;
  final int _expectedSak;
  final Uint8List _expectedAtqa;
  final Uint8List _expectedManufacturerBlock;
  final _MifareClassicCredential _manufacturerReadCredential;
  final int _capacityBlock;
  final _MifareClassicCredential _capacityCredential;
  final List<_MifareClassicMaintenancePrecondition> _preconditions;
  final List<_MifareClassicMaintenanceOperation> _operations;
  final int unchangedBlocks;
  final int dataBlockCount;

  MifareClassicMaintenancePlan._({
    required Object ownerToken,
    required MifareClassicGeometry geometry,
    required Uint8List expectedUid,
    required int expectedSak,
    required Uint8List expectedAtqa,
    required Uint8List expectedManufacturerBlock,
    required _MifareClassicCredential manufacturerReadCredential,
    required int capacityBlock,
    required _MifareClassicCredential capacityCredential,
    required List<_MifareClassicMaintenancePrecondition> preconditions,
    required List<_MifareClassicMaintenanceOperation> operations,
    required this.unchangedBlocks,
    required this.dataBlockCount,
  })  : _ownerToken = ownerToken,
        _geometry = geometry,
        _expectedUid = Uint8List.fromList(expectedUid),
        _expectedSak = expectedSak,
        _expectedAtqa = Uint8List.fromList(expectedAtqa),
        _expectedManufacturerBlock =
            Uint8List.fromList(expectedManufacturerBlock),
        _manufacturerReadCredential = manufacturerReadCredential,
        _capacityBlock = capacityBlock,
        _capacityCredential = capacityCredential,
        _preconditions = List.unmodifiable(preconditions),
        _operations = List.unmodifiable(operations);

  int get changedBlocks => _operations.length;

  List<int> get plannedBlocks =>
      List.unmodifiable(_operations.map((operation) => operation.block));
}

class MifareClassicMaintenanceReport {
  final int writtenBlocks;
  final int verifiedBlocks;
  final int unchangedBlocks;

  const MifareClassicMaintenanceReport({
    required this.writtenBlocks,
    required this.verifiedBlocks,
    required this.unchangedBlocks,
  });
}

enum MifareClassicMaintenancePhase {
  preflight,
  revalidating,
  writing,
  verifying,
}

class MifareClassicMaintenanceProgress {
  final MifareClassicMaintenancePhase phase;
  final int completed;
  final int total;
  final int? sector;
  final int? block;

  const MifareClassicMaintenanceProgress({
    required this.phase,
    required this.completed,
    required this.total,
    this.sector,
    this.block,
  });
}

typedef MifareClassicMaintenanceProgressCallback = void Function(
    MifareClassicMaintenanceProgress progress);

class MifareClassicMaintenance {
  final MifareClassicMaintenancePort port;
  final Object _ownerToken = Object();

  MifareClassicMaintenance(this.port);

  Future<MifareClassicMaintenancePlan> preflight({
    required Uint8List image,
    required MifareClassicKeyProfile profile,
    MifareClassicMaintenanceProgressCallback? onProgress,
    bool Function()? shouldCancel,
  }) async {
    final geometry = _geometryForImage(image);
    final blocks = _parseImage(image, geometry);
    if (!profile.isCompatible(
        cardType: geometry.cardType, sectorCount: geometry.sectorCount)) {
      throw MifareClassicMaintenanceException(
        MifareClassicMaintenanceFailure.incompatibleProfile,
        'The key profile is not compatible with this MIFARE Classic image',
      );
    }

    await _communicate(
      port.ensureReaderMode,
      'Communication with Chameleon was lost while enabling reader mode',
    );
    final initialCard = await _requireCard();
    final detectedType = await _communicate(
      port.detectType,
      'Communication with Chameleon was lost while detecting the card type',
    );
    if (detectedType != geometry.type) {
      throw MifareClassicMaintenanceException(
        MifareClassicMaintenanceFailure.wrongCardType,
        'The presented card type does not match the image',
      );
    }
    await _requireExactGeometry(geometry);
    if (!_startsWith(blocks[0], initialCard.uid)) {
      throw const MifareClassicMaintenanceException(
        MifareClassicMaintenanceFailure.identityMismatch,
        'The dump UID does not match the presented card',
        block: 0,
      );
    }
    if (profile.uid != null &&
        !profile.matchesUid(bytesToHex(initialCard.uid))) {
      throw const MifareClassicMaintenanceException(
        MifareClassicMaintenanceFailure.incompatibleProfile,
        'The key profile UID does not match the presented card',
      );
    }

    final operations = <_MifareClassicMaintenanceOperation>[];
    final preconditions = <_MifareClassicMaintenancePrecondition>[];
    _MifareClassicCredential? manufacturerReadCredential;
    _MifareClassicCredential? capacityCredential;
    var capacityBlock = -1;
    var unchangedBlocks = 0;
    var plannedDataBlocks = 0;

    for (var sector = 0; sector < geometry.sectorCount; sector++) {
      _throwIfCancelled(shouldCancel);
      await _requireExpectedCard(
        initialCard.uid,
        initialCard.sak,
        initialCard.atqa,
        sector: sector,
      );
      final trailerBlock = mfClassicGetSectorTrailerBlockBySector(sector);
      final credentials = <int, _MifareClassicCredential>{};

      for (var keyType = 0; keyType < 2; keyType++) {
        final key = profile.assignedKey(sector, keyType);
        if (key == null) {
          continue;
        }
        final result = await _communicate(
          () => port.authenticate(trailerBlock, 0x60 + keyType, key),
          'Communication with Chameleon was lost while authenticating',
          sector: sector,
          block: trailerBlock,
        );
        if (!result.isSuccess) {
          throw MifareClassicMaintenanceException(
            MifareClassicMaintenanceFailure.authenticationFailed,
            'An assigned profile key did not authenticate',
            sector: sector,
            block: trailerBlock,
            status: result.status,
          );
        }
        credentials[keyType] =
            _MifareClassicCredential(keyType: 0x60 + keyType, key: key);
      }
      if (credentials.isEmpty) {
        throw MifareClassicMaintenanceException(
          MifareClassicMaintenanceFailure.authenticationFailed,
          'The profile has no key for this sector',
          sector: sector,
          block: trailerBlock,
        );
      }
      if (sector == geometry.sectorCount - 1) {
        capacityBlock = trailerBlock;
        capacityCredential = credentials.values.first;
      }

      final trailer = await _readWithAnyCredential(
        trailerBlock,
        credentials.values,
        sector: sector,
      );
      final accessValues = MifareClassicDumpAnalyzer.accessConditionValues(
          bytesToHex(trailer.data.sublist(6, 9)));
      if (accessValues == null) {
        throw MifareClassicMaintenanceException(
          MifareClassicMaintenanceFailure.invalidAccessBits,
          'The current sector trailer has invalid access bits',
          sector: sector,
          block: trailerBlock,
        );
      }

      final firstBlock = mfClassicGetFirstBlockCountBySector(sector);
      final localTrailer = mfClassicGetSectorTrailerBlockInSector(sector);
      for (var localBlock = 0; localBlock < localTrailer; localBlock++) {
        final block = firstBlock + localBlock;
        final accessGroup = sector < 32 ? localBlock : localBlock ~/ 5;
        final permissions = MifareClassicDumpAnalyzer.dataAccessPermissions(
            accessValues[accessGroup]);
        final readCredential = _selectCredential(permissions[0], credentials);
        if (readCredential == null) {
          throw MifareClassicMaintenanceException(
            MifareClassicMaintenanceFailure.verificationNotAllowed,
            'No verified profile key can read this data block',
            sector: sector,
            block: block,
          );
        }

        final current = await _communicate(
          () =>
              port.readBlock(block, readCredential.keyType, readCredential.key),
          'Communication with Chameleon was lost while reading during preflight',
          sector: sector,
          block: block,
        );
        if (!current.isSuccess || current.data.length != 16) {
          throw MifareClassicMaintenanceException(
            MifareClassicMaintenanceFailure.readFailed,
            'Could not read a data block during preflight',
            sector: sector,
            block: block,
            status: current.status,
          );
        }

        if (block == 0) {
          if (!_sameBytes(current.data, blocks[0])) {
            throw const MifareClassicMaintenanceException(
              MifareClassicMaintenanceFailure.identityMismatch,
              'Manufacturer block 0 differs from the dump',
              sector: 0,
              block: 0,
            );
          }
          manufacturerReadCredential = readCredential;
          continue;
        }

        plannedDataBlocks++;
        preconditions.add(_MifareClassicMaintenancePrecondition(
          sector: sector,
          block: block,
          expectedData: current.data,
          readCredential: readCredential,
        ));
        if (_sameBytes(current.data, blocks[block])) {
          unchangedBlocks++;
        } else {
          final writeCredential =
              _selectCredential(permissions[1], credentials);
          if (writeCredential == null) {
            throw MifareClassicMaintenanceException(
              MifareClassicMaintenanceFailure.writeNotAllowed,
              'No verified profile key can write this data block',
              sector: sector,
              block: block,
            );
          }
          operations.add(_MifareClassicMaintenanceOperation(
            sector: sector,
            block: block,
            expectedData: current.data,
            targetData: blocks[block],
            writeCredential: writeCredential,
            readCredential: readCredential,
          ));
        }
      }

      onProgress?.call(MifareClassicMaintenanceProgress(
        phase: MifareClassicMaintenancePhase.preflight,
        completed: sector + 1,
        total: geometry.sectorCount,
        sector: sector,
      ));
    }

    await _requireExpectedCard(
      initialCard.uid,
      initialCard.sak,
      initialCard.atqa,
      sector: geometry.sectorCount - 1,
    );

    if (plannedDataBlocks != geometry.dataBlockCount) {
      throw StateError(
          'Internal geometry error: planned $plannedDataBlocks data blocks');
    }
    if (manufacturerReadCredential == null) {
      throw StateError('Internal geometry error: block 0 was not checked');
    }
    if (capacityBlock < 0 || capacityCredential == null) {
      throw StateError('Internal geometry error: capacity was not checked');
    }

    return MifareClassicMaintenancePlan._(
      ownerToken: _ownerToken,
      geometry: geometry,
      expectedUid: initialCard.uid,
      expectedSak: initialCard.sak,
      expectedAtqa: initialCard.atqa,
      expectedManufacturerBlock: blocks[0],
      manufacturerReadCredential: manufacturerReadCredential,
      capacityBlock: capacityBlock,
      capacityCredential: capacityCredential,
      preconditions: preconditions,
      operations: operations,
      unchangedBlocks: unchangedBlocks,
      dataBlockCount: plannedDataBlocks,
    );
  }

  Future<MifareClassicMaintenanceReport> execute(
    MifareClassicMaintenancePlan plan, {
    MifareClassicMaintenanceProgressCallback? onProgress,
    bool Function()? shouldCancel,
  }) async {
    if (!identical(plan._ownerToken, _ownerToken) || plan._claimed) {
      throw const MifareClassicMaintenanceException(
        MifareClassicMaintenanceFailure.stalePlan,
        'This maintenance plan has already been used; run preflight again',
      );
    }
    plan._claimed = true;

    var written = 0;
    var verified = 0;

    _throwIfCancelled(shouldCancel);
    await _communicate(
      port.ensureReaderMode,
      'Communication with Chameleon was lost while enabling reader mode',
      verifiedBlocks: verified,
    );
    await _requireExpectedCard(
      plan._expectedUid,
      plan._expectedSak,
      plan._expectedAtqa,
      sector: 0,
    );
    final detectedType = await _communicate(
      port.detectType,
      'Communication with Chameleon was lost while detecting the card type',
      verifiedBlocks: verified,
    );
    if (detectedType != plan._geometry.type) {
      throw MifareClassicMaintenanceException(
        MifareClassicMaintenanceFailure.wrongCardType,
        'The presented card type no longer matches the image',
      );
    }
    await _requireExactGeometry(plan._geometry, verifiedBlocks: verified);
    final capacityCheck = await _communicate(
      () => port.authenticate(
        plan._capacityBlock,
        plan._capacityCredential.keyType,
        plan._capacityCredential.key,
      ),
      'Communication with Chameleon was lost while checking card capacity',
      sector: plan._geometry.sectorCount - 1,
      block: plan._capacityBlock,
      verifiedBlocks: verified,
    );
    if (!capacityCheck.isSuccess) {
      throw MifareClassicMaintenanceException(
        MifareClassicMaintenanceFailure.wrongCardType,
        'The presented card no longer has the expected capacity',
        sector: plan._geometry.sectorCount - 1,
        block: plan._capacityBlock,
        status: capacityCheck.status,
      );
    }
    final manufacturerBlock = await _communicate(
      () => port.readBlock(
        0,
        plan._manufacturerReadCredential.keyType,
        plan._manufacturerReadCredential.key,
      ),
      'Communication with Chameleon was lost while checking manufacturer block 0',
      sector: 0,
      block: 0,
      verifiedBlocks: verified,
    );
    if (!manufacturerBlock.isSuccess ||
        !_sameBytes(manufacturerBlock.data, plan._expectedManufacturerBlock)) {
      throw MifareClassicMaintenanceException(
        MifareClassicMaintenanceFailure.identityMismatch,
        'Manufacturer block 0 changed after preflight',
        sector: 0,
        block: 0,
        status: manufacturerBlock.status,
      );
    }

    var revalidationSector = -1;
    for (var index = 0; index < plan._preconditions.length; index++) {
      final precondition = plan._preconditions[index];
      _throwIfCancelledBeforePrecondition(shouldCancel, precondition);
      if (precondition.sector != revalidationSector) {
        await _requireExpectedCard(
          plan._expectedUid,
          plan._expectedSak,
          plan._expectedAtqa,
          sector: precondition.sector,
        );
        revalidationSector = precondition.sector;
      }
      final currentBlock = await _communicate(
        () => port.readBlock(
          precondition.block,
          precondition.readCredential.keyType,
          precondition.readCredential.key,
        ),
        'Communication with Chameleon was lost while revalidating the card',
        sector: precondition.sector,
        block: precondition.block,
        verifiedBlocks: verified,
      );
      _throwIfCancelledBeforePrecondition(shouldCancel, precondition);
      if (!currentBlock.isSuccess || currentBlock.data.length != 16) {
        throw MifareClassicMaintenanceException(
          MifareClassicMaintenanceFailure.readFailed,
          'Could not revalidate a data block after preflight',
          sector: precondition.sector,
          block: precondition.block,
          status: currentBlock.status,
        );
      }
      if (!_sameBytes(currentBlock.data, precondition.expectedData)) {
        throw MifareClassicMaintenanceException(
          MifareClassicMaintenanceFailure.stalePlan,
          'A data block changed after preflight; run preflight again',
          sector: precondition.sector,
          block: precondition.block,
        );
      }
      onProgress?.call(MifareClassicMaintenanceProgress(
        phase: MifareClassicMaintenancePhase.revalidating,
        completed: index + 1,
        total: plan._preconditions.length,
        sector: precondition.sector,
        block: precondition.block,
      ));
    }
    await _requireExpectedCard(
      plan._expectedUid,
      plan._expectedSak,
      plan._expectedAtqa,
      sector: plan._geometry.sectorCount - 1,
    );

    for (final operation in plan._operations) {
      _throwIfCancelledBeforeBlock(shouldCancel, operation, verified);
      if (operation.block < 0 || operation.block >= plan._geometry.blockCount) {
        throw StateError(
            'Maintenance plan contains invalid block ${operation.block}');
      }
      final actualSector = mfClassicGetSectorByBlock(operation.block);
      if (actualSector != operation.sector) {
        throw StateError(
            'Maintenance plan sector does not match block ${operation.block}');
      }
      if (operation.block == 0 ||
          operation.block ==
              mfClassicGetSectorTrailerBlockBySector(actualSector)) {
        throw StateError(
            'Maintenance plan attempted a protected block ${operation.block}');
      }
      // Each device command starts a fresh RF interaction. Re-scan before
      // every write to detect ordinary card movement as early as possible.
      // The current firmware has no atomic "verify UID and write" command.
      try {
        await _requireExpectedCard(
          plan._expectedUid,
          plan._expectedSak,
          plan._expectedAtqa,
          sector: actualSector,
        );
      } on MifareClassicMaintenanceException catch (error) {
        throw MifareClassicMaintenanceException(
          error.failure,
          error.message,
          sector: actualSector,
          block: operation.block,
          status: error.status,
          verifiedBlocks: verified,
        );
      }

      final currentBlock = await _communicate(
        () => port.readBlock(
          operation.block,
          operation.readCredential.keyType,
          operation.readCredential.key,
        ),
        'Communication with Chameleon was lost before writing the data block',
        sector: operation.sector,
        block: operation.block,
        verifiedBlocks: verified,
      );
      if (!currentBlock.isSuccess || currentBlock.data.length != 16) {
        throw MifareClassicMaintenanceException(
          MifareClassicMaintenanceFailure.readFailed,
          'Could not re-read a data block before writing',
          sector: operation.sector,
          block: operation.block,
          status: currentBlock.status,
          verifiedBlocks: verified,
        );
      }
      if (!_sameBytes(currentBlock.data, operation.expectedData)) {
        throw MifareClassicMaintenanceException(
          MifareClassicMaintenanceFailure.stalePlan,
          'A data block changed after preflight; run preflight again',
          sector: operation.sector,
          block: operation.block,
          verifiedBlocks: verified,
        );
      }
      _throwIfCancelledBeforeBlock(shouldCancel, operation, verified);

      onProgress?.call(MifareClassicMaintenanceProgress(
        phase: MifareClassicMaintenancePhase.writing,
        completed: written,
        total: plan._operations.length,
        sector: operation.sector,
        block: operation.block,
      ));
      _throwIfCancelledBeforeBlock(shouldCancel, operation, verified);
      MifareClassicIoResult? writeResult;
      try {
        writeResult = await port.writeBlock(
          operation.block,
          operation.writeCredential.keyType,
          operation.writeCredential.key,
          operation.targetData,
        );
      } catch (_) {
        // A lost response does not prove that the card rejected the write.
        // Resolve the outcome with the same read-back used for a normal ACK.
      }

      try {
        await _requireExpectedCard(
          plan._expectedUid,
          plan._expectedSak,
          plan._expectedAtqa,
          sector: operation.sector,
        );
      } on MifareClassicMaintenanceException catch (error) {
        throw MifareClassicMaintenanceException(
          error.failure,
          error.message,
          sector: operation.sector,
          block: operation.block,
          status: writeResult?.status ?? error.status,
          verifiedBlocks: verified,
          writeOutcome: MifareClassicWriteOutcome.unknown,
        );
      }

      try {
        onProgress?.call(MifareClassicMaintenanceProgress(
          phase: MifareClassicMaintenancePhase.verifying,
          completed: verified,
          total: plan._operations.length,
          sector: operation.sector,
          block: operation.block,
        ));
      } catch (_) {
        // UI progress reporting cannot interrupt the mandatory read-back.
      }
      MifareClassicIoResult? readResult;
      try {
        readResult = await port.readBlock(
          operation.block,
          operation.readCredential.keyType,
          operation.readCredential.key,
        );
      } catch (_) {
        throw MifareClassicMaintenanceException(
          MifareClassicMaintenanceFailure.communicationLost,
          'The write outcome is unknown because read-back failed',
          sector: operation.sector,
          block: operation.block,
          status: writeResult?.status,
          verifiedBlocks: verified,
          writeOutcome: MifareClassicWriteOutcome.unknown,
        );
      }
      if (!readResult.isSuccess ||
          !_sameBytes(readResult.data, operation.targetData)) {
        final writeWasRejected = writeResult != null && !writeResult.isSuccess;
        throw MifareClassicMaintenanceException(
          writeWasRejected
              ? MifareClassicMaintenanceFailure.writeFailed
              : MifareClassicMaintenanceFailure.verificationFailed,
          writeWasRejected
              ? 'Card rejected a data-block write'
              : 'Read-back verification failed',
          sector: operation.sector,
          block: operation.block,
          status: writeWasRejected ? writeResult.status : readResult.status,
          verifiedBlocks: verified,
          writeOutcome: writeWasRejected
              ? MifareClassicWriteOutcome.rejected
              : MifareClassicWriteOutcome.unknown,
        );
      }
      written++;
      verified++;
    }

    return MifareClassicMaintenanceReport(
      writtenBlocks: written,
      verifiedBlocks: verified,
      unchangedBlocks: plan.unchangedBlocks,
    );
  }

  MifareClassicGeometry _geometryForImage(Uint8List image) {
    final geometry = MifareClassicGeometry.fromImageSize(image.length);
    if (geometry == null) {
      throw const MifareClassicMaintenanceException(
        MifareClassicMaintenanceFailure.invalidImage,
        'Unsupported MIFARE Classic image size',
      );
    }
    return geometry;
  }

  List<Uint8List> _parseImage(Uint8List image, MifareClassicGeometry geometry) {
    return List.generate(
      geometry.blockCount,
      (block) => Uint8List.fromList(image.sublist(block * 16, block * 16 + 16)),
    );
  }

  Future<CardData> _requireCard() async {
    CardData? card;
    try {
      card = await port.scan();
    } catch (_) {
      throw const MifareClassicMaintenanceException(
        MifareClassicMaintenanceFailure.communicationLost,
        'Communication with Chameleon was lost while scanning the card',
      );
    }
    if (card == null) {
      throw const MifareClassicMaintenanceException(
        MifareClassicMaintenanceFailure.noCard,
        'No single ISO14443-A card is available',
      );
    }
    return card;
  }

  Future<T> _communicate<T>(
    Future<T> Function() command,
    String message, {
    int? sector,
    int? block,
    int verifiedBlocks = 0,
  }) async {
    try {
      return await command();
    } on MifareClassicMaintenanceException {
      rethrow;
    } catch (_) {
      throw MifareClassicMaintenanceException(
        MifareClassicMaintenanceFailure.communicationLost,
        message,
        sector: sector,
        block: block,
        verifiedBlocks: verifiedBlocks,
      );
    }
  }

  Future<void> _requireExactGeometry(
    MifareClassicGeometry geometry, {
    int verifiedBlocks = 0,
  }) async {
    if (geometry.type != MifareClassicType.m1k) {
      return;
    }
    final hasEv1Sectors = await _communicate(
      () => port.isBlockAvailable(71),
      'Communication with Chameleon was lost while checking the 1K variant',
      block: 71,
      verifiedBlocks: verifiedBlocks,
    );
    if (hasEv1Sectors != geometry.isEV1) {
      throw MifareClassicMaintenanceException(
        MifareClassicMaintenanceFailure.wrongCardType,
        'The presented card does not match the selected 1K variant',
        block: 71,
      );
    }
  }

  Future<void> _requireExpectedCard(
    Uint8List uid,
    int sak,
    Uint8List atqa, {
    required int sector,
  }) async {
    final card = await _requireCard();
    if (!_sameBytes(card.uid, uid) ||
        card.sak != sak ||
        !_sameBytes(card.atqa, atqa)) {
      throw MifareClassicMaintenanceException(
        MifareClassicMaintenanceFailure.identityMismatch,
        'The card changed during the operation',
        sector: sector,
      );
    }
  }

  void _throwIfCancelled(bool Function()? shouldCancel) {
    if (shouldCancel?.call() ?? false) {
      throw const MifareClassicMaintenanceException(
        MifareClassicMaintenanceFailure.cancelled,
        'The operation was cancelled before the next block',
      );
    }
  }

  void _throwIfCancelledBeforeBlock(
    bool Function()? shouldCancel,
    _MifareClassicMaintenanceOperation operation,
    int verifiedBlocks,
  ) {
    if (shouldCancel?.call() ?? false) {
      throw MifareClassicMaintenanceException(
        MifareClassicMaintenanceFailure.cancelled,
        'The operation was cancelled before the next block',
        sector: operation.sector,
        block: operation.block,
        verifiedBlocks: verifiedBlocks,
      );
    }
  }

  void _throwIfCancelledBeforePrecondition(
    bool Function()? shouldCancel,
    _MifareClassicMaintenancePrecondition precondition,
  ) {
    if (shouldCancel?.call() ?? false) {
      throw MifareClassicMaintenanceException(
        MifareClassicMaintenanceFailure.cancelled,
        'The operation was cancelled before writing',
        sector: precondition.sector,
        block: precondition.block,
      );
    }
  }

  Future<MifareClassicIoResult> _readWithAnyCredential(
    int block,
    Iterable<_MifareClassicCredential> credentials, {
    required int sector,
  }) async {
    MifareClassicIoResult? lastResult;
    for (final credential in credentials) {
      final result = await _communicate(
        () => port.readBlock(block, credential.keyType, credential.key),
        'Communication with Chameleon was lost while reading the sector trailer',
        sector: sector,
        block: block,
      );
      lastResult = result;
      if (result.isSuccess && result.data.length == 16) {
        return result;
      }
    }
    throw MifareClassicMaintenanceException(
      MifareClassicMaintenanceFailure.readFailed,
      'Could not read the current sector trailer',
      sector: sector,
      block: block,
      status: lastResult?.status,
    );
  }

  _MifareClassicCredential? _selectCredential(
      int permissionMask, Map<int, _MifareClassicCredential> credentials) {
    if ((permissionMask & 1) != 0 && credentials.containsKey(0)) {
      return credentials[0];
    }
    if ((permissionMask & 2) != 0 && credentials.containsKey(1)) {
      return credentials[1];
    }
    return null;
  }

  bool _startsWith(Uint8List block, Uint8List prefix) {
    if (prefix.isEmpty || prefix.length > block.length) {
      return false;
    }
    for (var index = 0; index < prefix.length; index++) {
      if (block[index] != prefix[index]) {
        return false;
      }
    }
    return true;
  }

  bool _sameBytes(Uint8List first, Uint8List second) {
    if (first.length != second.length) {
      return false;
    }
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) {
        return false;
      }
    }
    return true;
  }
}
