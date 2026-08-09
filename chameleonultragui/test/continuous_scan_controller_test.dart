import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/continuous_scan_controller.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';

void main() {
  testWidgets('active scan owns its session and timer as one handle', (
    tester,
  ) async {
    final fixture = _connectedAppState();
    addTearDown(fixture.logger.close);
    final controller = ContinuousScanController(
      interval: const Duration(minutes: 5),
      maxDuration: const Duration(minutes: 20),
    );
    addTearDown(controller.dispose);

    var reads = 0;
    await controller.start(
      appState: fixture.appState,
      isAvailable: () => true,
      read: (session, canContinue) async {
        reads++;
        return canContinue();
      },
      hasResult: () => false,
    );

    expect(controller.isActive, isTrue);
    expect(controller.session?.connector, same(fixture.connector));
    expect(controller.session?.communicator, same(fixture.communicator));
    expect(reads, 1);

    await tester.pump(const Duration(minutes: 5));
    expect(reads, 2);

    controller.stop();

    expect(controller.isActive, isFalse);
    expect(controller.session, isNull);
    await tester.pump(const Duration(minutes: 5));
    expect(reads, 2);
  });

  test('late scan result cannot stop its replacement handle', () async {
    final fixture = _connectedAppState();
    addTearDown(fixture.logger.close);
    final controller = ContinuousScanController(
      interval: const Duration(minutes: 5),
      maxDuration: const Duration(minutes: 20),
    );
    addTearDown(controller.dispose);
    final firstRead = Completer<bool>();

    final firstScan = controller.start(
      appState: fixture.appState,
      isAvailable: () => true,
      read: (session, canContinue) => firstRead.future,
      hasResult: () => false,
    );
    await Future<void>.delayed(Duration.zero);
    controller.stop();
    await controller.start(
      appState: fixture.appState,
      isAvailable: () => true,
      read: (session, canContinue) async => true,
      hasResult: () => false,
    );
    firstRead.complete(false);
    await firstScan;

    expect(controller.isActive, isTrue);
    expect(controller.session?.communicator, same(fixture.communicator));
  });
}

({
  ChameleonGUIState appState,
  _TestSerial connector,
  ChameleonCommunicator communicator,
  Logger logger,
}) _connectedAppState() {
  final logger = Logger(output: MemoryOutput());
  final connector = _TestSerial(log: logger)..connected = true;
  final communicator = ChameleonCommunicator(logger, port: connector);
  final appState = ChameleonGUIState(SharedPreferencesProvider())
    ..log = logger
    ..connector = connector
    ..communicator = communicator;
  return (
    appState: appState,
    connector: connector,
    communicator: communicator,
    logger: logger,
  );
}

class _TestSerial extends AbstractSerial {
  _TestSerial({required super.log}) {
    connectionType = ConnectionType.usb;
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
