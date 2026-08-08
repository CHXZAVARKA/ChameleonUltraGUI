import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
import 'package:chameleonultragui/helpers/rf_operation_coordinator.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';

void main() {
  test('background operations skip while an operation is active', () async {
    final coordinator = RfOperationCoordinator();
    final firstOperation = Completer<void>();
    var operationsStarted = 0;

    final first = coordinator.tryRunBackground(() async {
      operationsStarted++;
      await firstOperation.future;
      return 'first';
    });
    await Future<void>.delayed(Duration.zero);

    final skipped = await coordinator.tryRunBackground(() async {
      operationsStarted++;
      return 'overlap';
    });

    expect(skipped.acquired, isFalse);
    expect(operationsStarted, 1);

    firstOperation.complete();
    expect((await first).value, 'first');

    final resumed = await coordinator.tryRunBackground(() async {
      operationsStarted++;
      return 'resumed';
    });
    expect(resumed.acquired, isTrue);
    expect(resumed.value, 'resumed');
    expect(operationsStarted, 2);
  });

  test('foreground operations are FIFO and are not starved by background',
      () async {
    final coordinator = RfOperationCoordinator();
    final backgroundOperation = Completer<void>();
    final firstForeground = Completer<void>();
    final order = <String>[];

    final background = coordinator.tryRunBackground(() async {
      order.add('background');
      await backgroundOperation.future;
    });
    await Future<void>.delayed(Duration.zero);

    final first = coordinator.runForeground(() async {
      order.add('foreground-1');
      await firstForeground.future;
    });
    final second = coordinator.runForeground(() async {
      order.add('foreground-2');
    });

    final skipped = await coordinator.tryRunBackground(() async {
      order.add('background-overlap');
    });
    expect(skipped.acquired, isFalse);

    backgroundOperation.complete();
    await background;
    await Future<void>.delayed(Duration.zero);
    expect(order, ['background', 'foreground-1']);

    final skippedForWaiter = await coordinator.tryRunBackground(() async {
      order.add('background-between-waiters');
    });
    expect(skippedForWaiter.acquired, isFalse);

    firstForeground.complete();
    await first;
    await second;
    expect(order, ['background', 'foreground-1', 'foreground-2']);
  });

  test('throwing operations always release their lease', () async {
    final coordinator = RfOperationCoordinator();

    await expectLater(
      coordinator.tryRunBackground<void>(() async => throw StateError('boom')),
      throwsStateError,
    );

    final foreground = await coordinator.runForeground(() async => 42);
    expect(foreground, 42);

    await expectLater(
      coordinator.runForeground<void>(() async => throw StateError('boom')),
      throwsStateError,
    );

    final background =
        await coordinator.tryRunBackground(() async => 'available');
    expect(background.acquired, isTrue);
    expect(background.value, 'available');
  });

  test('session-bound foreground exposes its captured session and value',
      () async {
    final fixture = _connectedAppState();
    addTearDown(fixture.logger.close);
    ConnectedDeviceSession? callbackSession;

    final result =
        await fixture.appState.runSessionBoundForeground((session) async {
      callbackSession = session;
      return 42;
    });

    expect(result.executed, isTrue);
    expect(result.value, 42);
    expect(result.session, same(callbackSession));
    expect(result.session!.connector, same(fixture.connector));
    expect(result.session!.communicator, same(fixture.communicator));
  });

  test('session-bound foreground rejects a missing connection', () async {
    final appState = ChameleonGUIState(SharedPreferencesProvider());
    var callbackRan = false;

    final result = await appState.runSessionBoundForeground((session) async {
      callbackRan = true;
      return 42;
    });

    expect(callbackRan, isFalse);
    expect(result.executed, isFalse);
    expect(result.session, isNull);
    expect(result.value, isNull);
  });

  test('queued session-bound foreground rejects connector replacement',
      () async {
    final fixture = _connectedAppState();
    addTearDown(fixture.logger.close);

    final outcome = await _runQueuedSessionBound(
      fixture,
      beforeLease: () {
        fixture.appState.connector = _TestSerial(log: fixture.logger)
          ..connected = true;
      },
    );

    expect(outcome.callbackRan, isFalse);
    expect(outcome.result.executed, isFalse);
  });

  test('queued session-bound foreground rejects DFU transition', () async {
    final fixture = _connectedAppState();
    addTearDown(fixture.logger.close);

    final outcome = await _runQueuedSessionBound(
      fixture,
      beforeLease: () => fixture.connector.isDFU = true,
    );

    expect(outcome.callbackRan, isFalse);
    expect(outcome.result.executed, isFalse);
  });

  test('queued session-bound foreground rejects reconnect', () async {
    final fixture = _connectedAppState();
    addTearDown(fixture.logger.close);

    final outcome = await _runQueuedSessionBound(
      fixture,
      beforeLease: () {
        fixture.connector.connected = false;
        fixture.appState.onConnectorStateChanged();
        fixture.connector.connected = true;
        fixture.appState.communicator = ChameleonCommunicator(
          fixture.logger,
          port: fixture.connector,
        );
      },
    );

    expect(outcome.callbackRan, isFalse);
    expect(outcome.result.executed, isFalse);
  });

  test('session-bound foreground operations share the foreground FIFO',
      () async {
    final fixture = _connectedAppState();
    addTearDown(fixture.logger.close);
    final releaseFirst = Completer<void>();
    final order = <String>[];

    final first = fixture.appState.runSessionBoundForeground((session) async {
      order.add('session-1');
      await releaseFirst.future;
    });
    final legacy = fixture.appState.rfOperations.runForeground(() async {
      order.add('legacy');
    });
    final second = fixture.appState.runSessionBoundForeground((session) async {
      order.add('session-2');
    });

    expect(order, ['session-1']);
    releaseFirst.complete();
    await first;
    await legacy;
    await second;

    expect(order, ['session-1', 'legacy', 'session-2']);
  });

  test('throwing session-bound foreground releases its FIFO lease', () async {
    final fixture = _connectedAppState();
    addTearDown(fixture.logger.close);

    await expectLater(
      fixture.appState.runSessionBoundForeground<void>(
        (session) async => throw StateError('boom'),
      ),
      throwsStateError,
    );

    final resumed = await fixture.appState.runSessionBoundForeground(
      (session) async => 42,
    );
    expect(resumed.executed, isTrue);
    expect(resumed.value, 42);
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

Future<({SessionBoundRfResult<int> result, bool callbackRan})>
    _runQueuedSessionBound(
  ({
    ChameleonGUIState appState,
    _TestSerial connector,
    ChameleonCommunicator communicator,
    Logger logger,
  }) fixture, {
  required void Function() beforeLease,
}) async {
  final blocker = Completer<void>();
  final blockingOperation = fixture.appState.rfOperations.runForeground(
    () => blocker.future,
  );
  var callbackRan = false;
  final queued = fixture.appState.runSessionBoundForeground((session) async {
    callbackRan = true;
    return 42;
  });

  beforeLease();
  blocker.complete();
  await blockingOperation;

  return (result: await queued, callbackRan: callbackRan);
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
