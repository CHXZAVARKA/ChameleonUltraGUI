import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/connector/serial_ble.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart' as app_logger;

void main() {
  test('BLE connect does not publish an idle state after the user starts it',
      () async {
    final reactiveBle = _ImmediateConnectBle();
    final serial = BLESerial(
      log: app_logger.Logger(output: app_logger.MemoryOutput()),
      reactiveBle: reactiveBle,
      connectionAttemptTimeout: const Duration(milliseconds: 20),
    )..chameleonMap['device'] = const Chameleon(
        port: 'device',
        device: ChameleonDevice.ultra,
        type: ConnectionType.ble,
        dfu: false,
      );
    addTearDown(() async {
      await serial.performDisconnect();
      serial.log.close();
    });
    final publishedPendingStates = <bool>[];
    serial
      ..pendingConnection = true
      ..connectionStateCallback = () {
        publishedPendingStates.add(serial.pendingConnection);
      };

    final connected = await serial.connectSpecificDevice('device');

    expect(connected, isTrue);
    expect(publishedPendingStates, isNot(contains(false)));
  });

  test('background BLE discovery keeps an active connection alive', () async {
    final reactiveBle = _ImmediateConnectBle();
    final serial = BLESerial(
      log: app_logger.Logger(output: app_logger.MemoryOutput()),
      reactiveBle: reactiveBle,
      connectionAttemptTimeout: const Duration(milliseconds: 20),
    )..chameleonMap['device'] = const Chameleon(
        port: 'device',
        device: ChameleonDevice.ultra,
        type: ConnectionType.ble,
        dfu: false,
      );
    addTearDown(() async {
      await serial.performDisconnect();
      serial.log.close();
    });

    expect(await serial.connectSpecificDevice('device'), isTrue);

    final discovery = serial.availableChameleons(false);
    await Future<void>.delayed(Duration.zero);

    expect(serial.connected, isTrue);
    await discovery;
  });

  test('BLE discovery finishes native scan cleanup before connecting',
      () async {
    final reactiveBle = _ScanCleanupThenConnectBle();
    final serial = BLESerial(
      log: app_logger.Logger(output: app_logger.MemoryOutput()),
      reactiveBle: reactiveBle,
      connectionAttemptTimeout: const Duration(milliseconds: 20),
      retryDelay: Duration.zero,
    );
    addTearDown(() async {
      await serial.performDisconnect();
      serial.log.close();
    });

    final devices = await serial.availableChameleons(false);
    expect(devices, hasLength(1));

    final connected = await serial
        .connectSpecificDevice('device')
        .timeout(const Duration(milliseconds: 500));

    expect(connected, isTrue);
    expect(reactiveBle.connectedWhileScanning, isFalse);
    expect(reactiveBle.connectionAttempts, 1);
  });

  test('one BLE connect retries when the plugin ignores its timeout', () async {
    final reactiveBle = _IgnoreTimeoutThenConnectBle();
    final serial = BLESerial(
      log: app_logger.Logger(output: app_logger.MemoryOutput()),
      reactiveBle: reactiveBle,
      connectionAttemptTimeout: const Duration(milliseconds: 20),
      retryDelay: Duration.zero,
    )..chameleonMap['device'] = const Chameleon(
        port: 'device',
        device: ChameleonDevice.ultra,
        type: ConnectionType.ble,
        dfu: false,
      );
    addTearDown(() async {
      await serial.performDisconnect();
      serial.log.close();
    });
    final publishedPendingStates = <bool>[];
    serial
      ..pendingConnection = true
      ..connectionStateCallback = () {
        publishedPendingStates.add(serial.pendingConnection);
      };

    final connected = await serial
        .connectSpecificDevice('device')
        .timeout(const Duration(milliseconds: 100));

    expect(connected, isTrue);
    expect(reactiveBle.connectionAttempts, 2);
    expect(publishedPendingStates, isNot(contains(false)));
  });

  test('one BLE connect retries after a stalled attempt', () async {
    final reactiveBle = _StallThenConnectBle();
    final serial = BLESerial(
      log: app_logger.Logger(output: app_logger.MemoryOutput()),
      reactiveBle: reactiveBle,
      retryDelay: Duration.zero,
    )..chameleonMap['device'] = const Chameleon(
        port: 'device',
        device: ChameleonDevice.ultra,
        type: ConnectionType.ble,
        dfu: false,
      );
    addTearDown(serial.log.close);

    final connected = await serial
        .connectSpecificDevice('device')
        .timeout(const Duration(milliseconds: 250));

    expect(connected, isTrue);
    expect(reactiveBle.connectionAttempts, 2);
    expect(reactiveBle.connectionTimeouts, everyElement(isNotNull));
    expect(serial.pendingConnection, isFalse);
  });

  test('BLE retry waits for the native connection task to settle', () async {
    final reactiveBle = _RequiresConnectionCleanupBle();
    final serial = BLESerial(
      log: app_logger.Logger(output: app_logger.MemoryOutput()),
      reactiveBle: reactiveBle,
    )..chameleonMap['device'] = const Chameleon(
        port: 'device',
        device: ChameleonDevice.ultra,
        type: ConnectionType.ble,
        dfu: false,
      );
    addTearDown(() async {
      await serial.performDisconnect();
      serial.log.close();
    });

    final connected = await serial
        .connectSpecificDevice('device')
        .timeout(const Duration(seconds: 1));

    expect(connected, isTrue);
    expect(reactiveBle.connectionAttempts, 2);
    expect(reactiveBle.retriedBeforeCleanup, isFalse);
  });

  test('BLE watchdog recovers when native cancellation never completes',
      () async {
    final reactiveBle = _CancellationNeverCompletesThenConnectBle();
    final serial = BLESerial(
      log: app_logger.Logger(output: app_logger.MemoryOutput()),
      reactiveBle: reactiveBle,
      connectionAttemptTimeout: const Duration(milliseconds: 20),
      retryDelay: Duration.zero,
    )..chameleonMap['device'] = const Chameleon(
        port: 'device',
        device: ChameleonDevice.ultra,
        type: ConnectionType.ble,
        dfu: false,
      );
    addTearDown(serial.log.close);

    final connected = await serial
        .connectSpecificDevice('device')
        .timeout(const Duration(milliseconds: 800));

    expect(connected, isTrue);
    expect(reactiveBle.connectionAttempts, 2);
  });

  test('one BLE connect retries after a stalled handshake', () async {
    final reactiveBle = _StallHandshakeThenConnectBle();
    final serial = BLESerial(
      log: app_logger.Logger(output: app_logger.MemoryOutput()),
      reactiveBle: reactiveBle,
      handshakeTimeout: const Duration(milliseconds: 20),
      retryDelay: Duration.zero,
    )..chameleonMap['device'] = const Chameleon(
        port: 'device',
        device: ChameleonDevice.ultra,
        type: ConnectionType.ble,
        dfu: false,
      );
    addTearDown(serial.log.close);

    final connected = await serial
        .connectSpecificDevice('device')
        .timeout(const Duration(milliseconds: 250));

    expect(connected, isTrue);
    expect(reactiveBle.connectionAttempts, 2);
    expect(reactiveBle.handshakeAttempts, 2);
  });

  test('final stalled handshake disconnects before returning failure',
      () async {
    final reactiveBle = _AlwaysStallHandshakeBle();
    final serial = BLESerial(
      log: app_logger.Logger(output: app_logger.MemoryOutput()),
      reactiveBle: reactiveBle,
      handshakeTimeout: const Duration(milliseconds: 10),
      retryDelay: Duration.zero,
    )..chameleonMap['device'] = const Chameleon(
        port: 'device',
        device: ChameleonDevice.ultra,
        type: ConnectionType.ble,
        dfu: false,
      );
    addTearDown(serial.log.close);

    final connected = await serial
        .connectSpecificDevice('device')
        .timeout(const Duration(milliseconds: 500));

    expect(connected, isFalse);
    expect(reactiveBle.connectionAttempts, 5);
    expect(reactiveBle.handshakeAttempts, 5);
    expect(reactiveBle.cancelledConnections, 5);
  });

  test('final connection error disconnects before returning failure', () async {
    final reactiveBle = _AlwaysFailConnectionBle();
    final serial = BLESerial(
      log: app_logger.Logger(output: app_logger.MemoryOutput()),
      reactiveBle: reactiveBle,
      retryDelay: Duration.zero,
    )..chameleonMap['device'] = const Chameleon(
        port: 'device',
        device: ChameleonDevice.ultra,
        type: ConnectionType.ble,
        dfu: false,
      );
    addTearDown(serial.log.close);
    final publishedPendingStates = <bool>[];
    serial
      ..pendingConnection = true
      ..connectionStateCallback = () {
        publishedPendingStates.add(serial.pendingConnection);
      };

    final connected = await serial
        .connectSpecificDevice('device')
        .timeout(const Duration(milliseconds: 500));

    expect(connected, isFalse);
    expect(reactiveBle.connectionAttempts, 5);
    expect(reactiveBle.cancelledConnections, 5);
    expect(serial.pendingConnection, isFalse);
    expect(publishedPendingStates.where((pending) => !pending), hasLength(1));
    expect(publishedPendingStates.last, isFalse);
  });

  test('late handshake cannot overwrite a newer successful retry', () async {
    final reactiveBle = _DisconnectThenConnectBle();
    final serial = BLESerial(
      log: app_logger.Logger(output: app_logger.MemoryOutput()),
      reactiveBle: reactiveBle,
      handshakeTimeout: const Duration(seconds: 1),
      retryDelay: Duration.zero,
    )..chameleonMap['device'] = const Chameleon(
        port: 'device',
        device: ChameleonDevice.ultra,
        type: ConnectionType.ble,
        dfu: false,
      );
    addTearDown(serial.log.close);

    final connecting = serial.connectSpecificDevice('device');
    await reactiveBle.firstHandshakeStarted.future;
    reactiveBle.disconnectFirstAttempt();

    expect(await connecting, isTrue);
    expect(reactiveBle.connectionAttempts, 2);
    expect(serial.connected, isTrue);
    expect(serial.pendingConnection, isFalse);

    reactiveBle.completeFirstHandshake();
    await Future<void>.delayed(Duration.zero);

    expect(serial.connected, isTrue);
    expect(serial.activeDevicePort, 'device');
    expect(reactiveBle.cancelledConnections, 1);
  });
}

class _ImmediateConnectBle extends _StallThenConnectBle {
  @override
  Stream<ConnectionStateUpdate> connectToAdvertisingDevice({
    required String id,
    required List<Uuid> withServices,
    required Duration prescanDuration,
    Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover,
    Duration? connectionTimeout,
  }) {
    connectionAttempts++;
    connectionTimeouts.add(connectionTimeout);
    return Stream.value(
      const ConnectionStateUpdate(
        deviceId: 'device',
        connectionState: DeviceConnectionState.connected,
        failure: null,
      ),
    );
  }
}

class _IgnoreTimeoutThenConnectBle extends _StallThenConnectBle {
  final _ignoredTimeout = StreamController<ConnectionStateUpdate>();

  @override
  Stream<ConnectionStateUpdate> connectToAdvertisingDevice({
    required String id,
    required List<Uuid> withServices,
    required Duration prescanDuration,
    Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover,
    Duration? connectionTimeout,
  }) {
    connectionAttempts++;
    connectionTimeouts.add(connectionTimeout);
    if (connectionAttempts == 1) {
      return _ignoredTimeout.stream;
    }
    return Stream.value(
      const ConnectionStateUpdate(
        deviceId: 'device',
        connectionState: DeviceConnectionState.connected,
        failure: null,
      ),
    );
  }
}

class _ScanCleanupThenConnectBle extends _StallThenConnectBle {
  var scanActive = false;
  var connectedWhileScanning = false;

  @override
  Stream<DiscoveredDevice> scanForDevices({
    required List<Uuid> withServices,
    ScanMode scanMode = ScanMode.balanced,
    bool requireLocationServicesEnabled = true,
  }) {
    late StreamController<DiscoveredDevice> controller;
    controller = StreamController<DiscoveredDevice>(
      onListen: () {
        scanActive = true;
        controller.add(
          DiscoveredDevice(
            id: 'device',
            name: 'ChameleonUltra',
            serviceData: const {},
            manufacturerData: Uint8List(0),
            rssi: -40,
            serviceUuids: [nrfUUID],
          ),
        );
      },
      onCancel: () async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        scanActive = false;
      },
    );
    return controller.stream;
  }

  @override
  Stream<ConnectionStateUpdate> connectToAdvertisingDevice({
    required String id,
    required List<Uuid> withServices,
    required Duration prescanDuration,
    Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover,
    Duration? connectionTimeout,
  }) {
    connectionAttempts++;
    connectionTimeouts.add(connectionTimeout);
    if (scanActive) {
      connectedWhileScanning = true;
      return Stream<ConnectionStateUpdate>.error(
        StateError('simulated native scan is still running'),
      );
    }
    return Stream.value(
      const ConnectionStateUpdate(
        deviceId: 'device',
        connectionState: DeviceConnectionState.connected,
        failure: null,
      ),
    );
  }
}

class _StallThenConnectBle implements ReactiveBleClient {
  final _stalledAttempt = StreamController<ConnectionStateUpdate>();
  var connectionAttempts = 0;
  final List<Duration?> connectionTimeouts = [];

  @override
  Stream<ConnectionStateUpdate> connectToAdvertisingDevice({
    required String id,
    required List<Uuid> withServices,
    required Duration prescanDuration,
    Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover,
    Duration? connectionTimeout,
  }) {
    connectionAttempts++;
    connectionTimeouts.add(connectionTimeout);
    if (connectionAttempts == 1 && connectionTimeout == null) {
      return _stalledAttempt.stream;
    }
    if (connectionAttempts == 1) {
      return Stream<ConnectionStateUpdate>.error(
        TimeoutException('simulated stalled BLE connection'),
      );
    }
    return Stream.value(
      const ConnectionStateUpdate(
        deviceId: 'device',
        connectionState: DeviceConnectionState.connected,
        failure: null,
      ),
    );
  }

  @override
  Stream<List<int>> subscribeToCharacteristic(
    QualifiedCharacteristic characteristic,
  ) =>
      const Stream.empty();

  @override
  Stream<DiscoveredDevice> scanForDevices({
    required List<Uuid> withServices,
    ScanMode scanMode = ScanMode.balanced,
    bool requireLocationServicesEnabled = true,
  }) =>
      const Stream.empty();

  @override
  Future<void> writeCharacteristicWithResponse(
    QualifiedCharacteristic characteristic, {
    required List<int> value,
  }) async {}

  @override
  Future<void> writeCharacteristicWithoutResponse(
    QualifiedCharacteristic characteristic, {
    required List<int> value,
  }) async {}
}

class _StallHandshakeThenConnectBle extends _StallThenConnectBle {
  var handshakeAttempts = 0;

  @override
  Stream<ConnectionStateUpdate> connectToAdvertisingDevice({
    required String id,
    required List<Uuid> withServices,
    required Duration prescanDuration,
    Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover,
    Duration? connectionTimeout,
  }) {
    connectionAttempts++;
    connectionTimeouts.add(connectionTimeout);
    return Stream.value(
      const ConnectionStateUpdate(
        deviceId: 'device',
        connectionState: DeviceConnectionState.connected,
        failure: null,
      ),
    );
  }

  @override
  Future<void> writeCharacteristicWithResponse(
    QualifiedCharacteristic characteristic, {
    required List<int> value,
  }) {
    handshakeAttempts++;
    if (handshakeAttempts == 1) {
      return Completer<void>().future;
    }
    return Future.value();
  }
}

class _RequiresConnectionCleanupBle extends _StallThenConnectBle {
  var cleanupComplete = false;
  var retriedBeforeCleanup = false;

  @override
  Stream<ConnectionStateUpdate> connectToAdvertisingDevice({
    required String id,
    required List<Uuid> withServices,
    required Duration prescanDuration,
    Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover,
    Duration? connectionTimeout,
  }) {
    connectionAttempts++;
    connectionTimeouts.add(connectionTimeout);
    if (connectionAttempts == 1) {
      late StreamController<ConnectionStateUpdate> controller;
      controller = StreamController<ConnectionStateUpdate>(
        onListen: () {
          controller.addError(
            TimeoutException('simulated native connection timeout'),
          );
        },
        onCancel: () {
          Timer(const Duration(milliseconds: 10), () {
            cleanupComplete = true;
          });
        },
      );
      return controller.stream;
    }
    if (!cleanupComplete) {
      retriedBeforeCleanup = true;
      throw StateError('native connection task is still registered');
    }
    return Stream.value(
      const ConnectionStateUpdate(
        deviceId: 'device',
        connectionState: DeviceConnectionState.connected,
        failure: null,
      ),
    );
  }
}

class _CancellationNeverCompletesThenConnectBle extends _StallThenConnectBle {
  final _neverCancelled = Completer<void>();

  @override
  Stream<ConnectionStateUpdate> connectToAdvertisingDevice({
    required String id,
    required List<Uuid> withServices,
    required Duration prescanDuration,
    Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover,
    Duration? connectionTimeout,
  }) {
    connectionAttempts++;
    connectionTimeouts.add(connectionTimeout);
    if (connectionAttempts == 1) {
      return StreamController<ConnectionStateUpdate>(
        onCancel: () => _neverCancelled.future,
      ).stream;
    }
    return Stream.value(
      const ConnectionStateUpdate(
        deviceId: 'device',
        connectionState: DeviceConnectionState.connected,
        failure: null,
      ),
    );
  }
}

class _AlwaysStallHandshakeBle extends _StallHandshakeThenConnectBle {
  var cancelledConnections = 0;

  @override
  Stream<ConnectionStateUpdate> connectToAdvertisingDevice({
    required String id,
    required List<Uuid> withServices,
    required Duration prescanDuration,
    Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover,
    Duration? connectionTimeout,
  }) {
    connectionAttempts++;
    connectionTimeouts.add(connectionTimeout);
    late StreamController<ConnectionStateUpdate> controller;
    controller = StreamController<ConnectionStateUpdate>(
      onListen: () {
        controller.add(
          const ConnectionStateUpdate(
            deviceId: 'device',
            connectionState: DeviceConnectionState.connected,
            failure: null,
          ),
        );
      },
      onCancel: () {
        cancelledConnections++;
      },
    );
    return controller.stream;
  }

  @override
  Future<void> writeCharacteristicWithResponse(
    QualifiedCharacteristic characteristic, {
    required List<int> value,
  }) {
    handshakeAttempts++;
    return Completer<void>().future;
  }
}

class _AlwaysFailConnectionBle extends _StallThenConnectBle {
  var cancelledConnections = 0;

  @override
  Stream<ConnectionStateUpdate> connectToAdvertisingDevice({
    required String id,
    required List<Uuid> withServices,
    required Duration prescanDuration,
    Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover,
    Duration? connectionTimeout,
  }) {
    connectionAttempts++;
    connectionTimeouts.add(connectionTimeout);
    late StreamController<ConnectionStateUpdate> controller;
    controller = StreamController<ConnectionStateUpdate>(
      onListen: () {
        controller.addError(
          TimeoutException('simulated BLE connection timeout'),
        );
      },
      onCancel: () {
        cancelledConnections++;
      },
    );
    return controller.stream;
  }
}

class _DisconnectThenConnectBle extends _StallThenConnectBle {
  final firstHandshakeStarted = Completer<void>();
  final _firstHandshake = Completer<void>();
  StreamController<ConnectionStateUpdate>? _firstConnection;
  var handshakeAttempts = 0;
  var cancelledConnections = 0;

  void disconnectFirstAttempt() {
    _firstConnection!.add(
      const ConnectionStateUpdate(
        deviceId: 'device',
        connectionState: DeviceConnectionState.disconnected,
        failure: null,
      ),
    );
  }

  void completeFirstHandshake() => _firstHandshake.complete();

  @override
  Stream<ConnectionStateUpdate> connectToAdvertisingDevice({
    required String id,
    required List<Uuid> withServices,
    required Duration prescanDuration,
    Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover,
    Duration? connectionTimeout,
  }) {
    connectionAttempts++;
    connectionTimeouts.add(connectionTimeout);
    late StreamController<ConnectionStateUpdate> controller;
    controller = StreamController<ConnectionStateUpdate>(
      onListen: () {
        controller.add(
          const ConnectionStateUpdate(
            deviceId: 'device',
            connectionState: DeviceConnectionState.connected,
            failure: null,
          ),
        );
      },
      onCancel: () {
        cancelledConnections++;
      },
    );
    if (connectionAttempts == 1) {
      _firstConnection = controller;
    }
    return controller.stream;
  }

  @override
  Future<void> writeCharacteristicWithResponse(
    QualifiedCharacteristic characteristic, {
    required List<int> value,
  }) {
    handshakeAttempts++;
    if (handshakeAttempts == 1) {
      firstHandshakeStarted.complete();
      return _firstHandshake.future;
    }
    return Future.value();
  }
}
