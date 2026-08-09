import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';

void main() {
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

  test('session-bound foreground preserves an explicitly nullable success',
      () async {
    final fixture = _connectedAppState();
    addTearDown(fixture.logger.close);
    ConnectedDeviceSession? callbackSession;

    final result = await fixture.appState.runSessionBoundForeground<int?>(
      (session) async {
        callbackSession = session;
        return null;
      },
    );

    expect(result.executed, isTrue);
    expect(result.session, same(callbackSession));
    expect(result.session, isNotNull);
    expect(result.value, isNull);
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

  test('catching session-bound foreground returns the session and error',
      () async {
    final fixture = _connectedAppState();
    addTearDown(fixture.logger.close);
    final failure = StateError('boom');

    final result = await fixture.appState
        .runSessionBoundForegroundCatching<Object?>((session) async {
      throw failure;
    });

    expect(result.executed, isTrue);
    expect(result.session, isNotNull);
    expect(result.session!.connector, same(fixture.connector));
    expect(result.session!.communicator, same(fixture.communicator));
    expect(result.error, same(failure));
    expect(result.stackTrace, isNotNull);
    expect(result.value, isNull);
  });

  test('queued catching session-bound foreground rejects a stale session',
      () async {
    final fixture = _connectedAppState();
    addTearDown(fixture.logger.close);
    final blocker = Completer<void>();
    final blockingOperation = fixture.appState.rfOperations.runForeground(
      () => blocker.future,
    );
    var callbackRan = false;

    final queued = fixture.appState.runSessionBoundForegroundCatching<void>(
      (session) async {
        callbackRan = true;
      },
    );
    fixture.appState.communicator = ChameleonCommunicator(
      fixture.logger,
      port: fixture.connector,
    );
    blocker.complete();
    await blockingOperation;

    final result = await queued;
    expect(callbackRan, isFalse);
    expect(result.executed, isFalse);
    expect(result.session, isNull);
    expect(result.error, isNull);
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
