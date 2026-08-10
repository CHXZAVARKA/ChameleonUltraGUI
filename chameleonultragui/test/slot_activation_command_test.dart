import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';

void main() {
  test('slot activation accepts the firmware success response', () async {
    final fixture = _fixture(ChameleonStatus.success);
    addTearDown(fixture.logger.close);

    await expectLater(fixture.communicator.activateSlot(1), completes);
  });

  test('slot activation rejects a non-success firmware response', () async {
    final fixture = _fixture(0x66);
    addTearDown(fixture.logger.close);

    await expectLater(
      fixture.communicator.activateSlot(1),
      throwsA(
        isA<SlotActivationRejected>()
            .having(
              (error) => error.status,
              'status',
              0x66,
            )
            .having(
              (error) => error.toString(),
              'description',
              contains('0x66'),
            ),
      ),
    );
  });
}

({
  ChameleonCommunicator communicator,
  Logger logger,
}) _fixture(int responseStatus) {
  final logger = Logger();
  final serial = _RespondingSerial(log: logger);
  final communicator = ChameleonCommunicator(logger, port: serial);
  serial.response = communicator.makeDataFrameBytes(
    ChameleonCommand.setActiveSlot,
    responseStatus,
    Uint8List(0),
  );
  return (communicator: communicator, logger: logger);
}

class _RespondingSerial extends AbstractSerial {
  _RespondingSerial({required super.log});

  late Uint8List response;

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => const [];

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => true;

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async {
    await messageCallback(response);
    return true;
  }
}
