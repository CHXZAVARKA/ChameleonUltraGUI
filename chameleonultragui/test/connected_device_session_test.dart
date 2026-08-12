import 'dart:async';
import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
import 'package:chameleonultragui/helpers/read_card_session.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'support/connected_device_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Read Card model remains stable for the current device session', () {
    final fixture = _connectedAppState();
    addTearDown(fixture.logger.close);

    final model = fixture.appState.readCardSession;
    model.hfInfo.uid = 'persisted';

    fixture.appState
      ..changesMade()
      ..connector = fixture.connector
      ..communicator = fixture.communicator;

    expect(fixture.appState.readCardSession, same(model));
    expect(fixture.appState.readCardSession.hfInfo.uid, 'persisted');
  });

  for (final invalidation in <String, void Function(_Fixture)>{
    'disconnect': (fixture) {
      fixture.connector.connected = false;
      fixture.appState.onConnectorStateChanged();
    },
    'reconnect': (fixture) {
      fixture.connector.connected = false;
      fixture.appState.onConnectorStateChanged();
      fixture.connector.connected = true;
      fixture.appState.communicator = ChameleonCommunicator(
        fixture.logger,
        port: fixture.connector,
      );
      fixture.appState.changesMade();
    },
    'connector replacement': (fixture) {
      fixture.appState.connector = TestSerial(log: fixture.logger);
    },
    'communicator replacement': (fixture) {
      fixture.appState.communicator = ChameleonCommunicator(
        fixture.logger,
        port: fixture.connector,
      );
    },
    'DFU transition': (fixture) {
      fixture.connector.isDFU = true;
      fixture.appState.changesMade();
    },
  }.entries) {
    test('Read Card model rotates on ${invalidation.key}', () {
      final fixture = _connectedAppState();
      addTearDown(fixture.logger.close);
      final original = fixture.appState.readCardSession;
      original
        ..dumpName = 'old dump'
        ..hfInfo.uid = 'old uid'
        ..mfcInfo.state = MifareClassicState.save;

      invalidation.value(fixture);

      final replacement = fixture.appState.readCardSession;
      expect(replacement, isNot(same(original)));
      expect(replacement.dumpName, isEmpty);
      expect(replacement.hfInfo.uid, isEmpty);
      expect(replacement.mfcInfo.state, MifareClassicState.none);
    });
  }

  test('device-session replacement releases its wakelock lease', () async {
    final previousWakelock = wakelockPlusPlatformInstance;
    final wakelock = _RecordingWakelock();
    wakelockPlusPlatformInstance = wakelock;
    addTearDown(() => wakelockPlusPlatformInstance = previousWakelock);
    final fixture = _connectedAppState();
    addTearDown(fixture.logger.close);

    final owner = fixture.appState.acquireSessionWakelock(
      connector: fixture.connector,
      communicator: fixture.communicator,
    );
    await Future<void>.delayed(Duration.zero);
    expect(owner, isNotNull);
    expect(wakelock.states.last, isTrue);

    fixture.appState.communicator = ChameleonCommunicator(
      fixture.logger,
      port: fixture.connector,
    );
    await Future<void>.delayed(Duration.zero);

    expect(wakelock.states.last, isFalse);
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
        fixture.appState.connector = TestSerial(log: fixture.logger);
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

typedef _Fixture = ({
  ChameleonGUIState appState,
  TestSerial connector,
  ChameleonCommunicator communicator,
  Logger logger,
});

_Fixture _connectedAppState() {
  final harness = connectedDeviceSessionHarness();
  return (
    appState: harness.appState,
    connector: harness.serial,
    communicator: harness.communicator,
    logger: harness.logger,
  );
}

class _RecordingWakelock extends WakelockPlusPlatformInterface {
  final List<bool> states = [];

  @override
  Future<bool> get enabled async => states.isNotEmpty && states.last;

  @override
  Future<void> toggle({required bool enable}) async {
    states.add(enable);
  }
}

Future<({SessionBoundRfResult<int> result, bool callbackRan})>
    _runQueuedSessionBound(
  ({
    ChameleonGUIState appState,
    TestSerial connector,
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
