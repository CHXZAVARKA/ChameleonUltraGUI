import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
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
    ConnectedDeviceSession? observedSession;
    await controller.start(
      appState: fixture.appState,
      isAvailable: () => true,
      read: (session, canContinue) async {
        observedSession = session;
        reads++;
        return canContinue();
      },
      hasResult: () => false,
    );

    expect(controller.isActive, isTrue);
    expect(observedSession?.connector, same(fixture.connector));
    expect(observedSession?.communicator, same(fixture.communicator));
    expect(reads, 1);

    await tester.pump(const Duration(minutes: 5));
    expect(reads, 2);

    controller.stop();

    expect(controller.isActive, isFalse);
    await tester.pump(const Duration(minutes: 5));
    expect(reads, 2);
  });

  testWidgets('background ticks yield to queued foreground work and resume', (
    tester,
  ) async {
    final fixture = _connectedAppState();
    addTearDown(fixture.logger.close);
    final controller = ContinuousScanController(
      interval: const Duration(seconds: 1),
      maxDuration: const Duration(minutes: 1),
    );
    addTearDown(controller.dispose);
    final firstRead = Completer<bool>();
    final foregroundGate = Completer<void>();
    var reads = 0;
    var foregroundStarted = false;

    final scan = controller.start(
      appState: fixture.appState,
      isAvailable: () => true,
      read: (session, canContinue) {
        reads++;
        return reads == 1 ? firstRead.future : Future.value(true);
      },
      hasResult: () => false,
    );
    await tester.pump();
    expect(reads, 1);

    final foreground = fixture.appState.rfOperations.runForeground(() async {
      foregroundStarted = true;
      await foregroundGate.future;
    });
    await tester.pump(const Duration(seconds: 2));
    expect(reads, 1);
    expect(foregroundStarted, isFalse);

    firstRead.complete(true);
    await scan;
    await tester.pump();
    expect(foregroundStarted, isTrue);

    await tester.pump(const Duration(seconds: 2));
    expect(reads, 1);

    foregroundGate.complete();
    await foreground;
    await tester.pump(const Duration(seconds: 1));
    expect(reads, 2);
    controller.stop();
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
  });

  testWidgets('start rolls back when its active-state callback throws', (
    tester,
  ) async {
    final fixture = _connectedAppState();
    addTearDown(fixture.logger.close);
    final controller = ContinuousScanController(
      interval: const Duration(minutes: 5),
      maxDuration: const Duration(minutes: 20),
    );
    addTearDown(controller.dispose);
    final callbackError = StateError('active state callback failed');
    final states = <bool>[];
    var reads = 0;

    await expectLater(
      controller.start(
        appState: fixture.appState,
        isAvailable: () => true,
        read: (session, canContinue) async {
          reads++;
          return true;
        },
        hasResult: () => false,
        onStateChanged: (active) {
          states.add(active);
          if (active) {
            throw callbackError;
          }
        },
      ),
      throwsA(same(callbackError)),
    );

    expect(controller.isActive, isFalse);
    expect(states, [true]);
    expect(reads, 0);
    await tester.pump(const Duration(minutes: 5));
    expect(reads, 0);
  });

  testWidgets('read and observer failures cannot strand an active scan', (
    tester,
  ) async {
    final fixture = _connectedAppState();
    addTearDown(fixture.logger.close);
    final controller = ContinuousScanController(
      interval: const Duration(minutes: 5),
      maxDuration: const Duration(minutes: 20),
    );
    addTearDown(controller.dispose);
    final readError = StateError('read failed');
    final onErrorFailure = StateError('error observer failed');
    final stoppedStateFailure = StateError('stopped state observer failed');
    final states = <bool>[];
    Object? observedReadError;
    StackTrace? observedReadStackTrace;
    var reads = 0;

    await expectLater(
      controller.start(
        appState: fixture.appState,
        isAvailable: () => true,
        read: (session, canContinue) async {
          reads++;
          throw readError;
        },
        hasResult: () => false,
        onStateChanged: (active) {
          states.add(active);
          if (!active) {
            throw stoppedStateFailure;
          }
        },
        onError: (error, stackTrace, session) {
          observedReadError = error;
          observedReadStackTrace = stackTrace;
          throw onErrorFailure;
        },
      ),
      throwsA(same(onErrorFailure)),
    );

    expect(observedReadError, same(readError));
    expect(observedReadStackTrace, isNotNull);
    expect(controller.isActive, isFalse);
    expect(states, [true, false]);
    expect(reads, 1);
    await tester.pump(const Duration(minutes: 5));
    expect(reads, 1);
  });

  testWidgets('availability callback failure is reported and cleaned up', (
    tester,
  ) async {
    final fixture = _connectedAppState();
    addTearDown(fixture.logger.close);
    final controller = ContinuousScanController(
      interval: const Duration(minutes: 5),
      maxDuration: const Duration(minutes: 20),
    );
    addTearDown(controller.dispose);
    final availabilityError = StateError('availability failed');
    Object? reportedError;
    StackTrace? reportedStackTrace;
    var reads = 0;

    await controller.start(
      appState: fixture.appState,
      isAvailable: () => throw availabilityError,
      read: (session, canContinue) async {
        reads++;
        return true;
      },
      hasResult: () => false,
      onError: (error, stackTrace, session) {
        reportedError = error;
        reportedStackTrace = stackTrace;
      },
    );

    expect(reportedError, same(availabilityError));
    expect(reportedStackTrace, isNotNull);
    expect(controller.isActive, isFalse);
    expect(reads, 0);
    await tester.pump(const Duration(minutes: 5));
    expect(reads, 0);
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
