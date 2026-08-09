import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/connected_device_session.dart';
import 'package:chameleonultragui/helpers/read_card_session.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';

void main() {
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
      fixture.appState.connector = _TestSerial(log: fixture.logger)
        ..connected = true;
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

  test('session-bound foreground exposes the captured session and value',
      () async {
    final fixture = _connectedAppState();
    addTearDown(fixture.logger.close);

    final result = await fixture.appState.runSessionBoundForeground(
      (session) async => 42,
    );

    expect(result.executed, isTrue);
    expect(result.value, 42);
    expect(result.session!.connector, same(fixture.connector));
    expect(result.session!.communicator, same(fixture.communicator));
  });

  test('session-bound foreground preserves a nullable success', () async {
    final fixture = _connectedAppState();
    addTearDown(fixture.logger.close);

    final result = await fixture.appState.runSessionBoundForeground<int?>(
      (session) async => null,
    );

    expect(result.executed, isTrue);
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
  });

  for (final invalidation in <String, void Function(_Fixture)>{
    'connector replacement': (fixture) {
      fixture.appState.connector = _TestSerial(log: fixture.logger)
        ..connected = true;
    },
    'DFU transition': (fixture) => fixture.connector.isDFU = true,
    'reconnect': (fixture) {
      fixture.connector.connected = false;
      fixture.appState.onConnectorStateChanged();
      fixture.connector.connected = true;
      fixture.appState.communicator = ChameleonCommunicator(
        fixture.logger,
        port: fixture.connector,
      );
    },
  }.entries) {
    test('queued session-bound foreground rejects ${invalidation.key}',
        () async {
      final fixture = _connectedAppState();
      addTearDown(fixture.logger.close);
      final release = Completer<void>();
      final blocker = fixture.appState.rfOperations.runForeground(
        () => release.future,
      );
      var callbackRan = false;
      final queued = fixture.appState.runSessionBoundForeground(
        (session) async {
          callbackRan = true;
          return 42;
        },
      );

      invalidation.value(fixture);
      release.complete();
      await blocker;

      expect(callbackRan, isFalse);
      expect((await queued).executed, isFalse);
    });
  }

  test('throwing callback releases the shared FIFO lease', () async {
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
    expect(resumed.value, 42);
  });
}

typedef _Fixture = ({
  ChameleonGUIState appState,
  _TestSerial connector,
  ChameleonCommunicator communicator,
  Logger logger,
});

_Fixture _connectedAppState() {
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
