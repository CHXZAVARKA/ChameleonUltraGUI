import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

// Regular
Uuid nrfUUID = Uuid.parse("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
Uuid uartRX = Uuid.parse("6E400002-B5A3-F393-E0A9-E50E24DCCA9E");
Uuid uartTX = Uuid.parse("6E400003-B5A3-F393-E0A9-E50E24DCCA9E");

// DFU
Uuid dfuUUID = Uuid.parse("FE59");
Uuid dfuControl = Uuid.parse("8EC90001-F315-4F60-9FB8-838830DAEA50");
Uuid dfuFirmware = Uuid.parse("8EC90002-F315-4F60-9FB8-838830DAEA50");

abstract interface class ReactiveBleClient {
  Stream<DiscoveredDevice> scanForDevices({
    required List<Uuid> withServices,
    ScanMode scanMode = ScanMode.balanced,
    bool requireLocationServicesEnabled = true,
  });

  Stream<ConnectionStateUpdate> connectToAdvertisingDevice({
    required String id,
    required List<Uuid> withServices,
    required Duration prescanDuration,
    Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover,
    Duration? connectionTimeout,
  });

  Stream<List<int>> subscribeToCharacteristic(
    QualifiedCharacteristic characteristic,
  );

  Future<void> writeCharacteristicWithResponse(
    QualifiedCharacteristic characteristic, {
    required List<int> value,
  });

  Future<void> writeCharacteristicWithoutResponse(
    QualifiedCharacteristic characteristic, {
    required List<int> value,
  });
}

class FlutterReactiveBleClient implements ReactiveBleClient {
  FlutterReactiveBleClient([FlutterReactiveBle? client])
      : _client = client ?? FlutterReactiveBle();

  final FlutterReactiveBle _client;

  @override
  Stream<DiscoveredDevice> scanForDevices({
    required List<Uuid> withServices,
    ScanMode scanMode = ScanMode.balanced,
    bool requireLocationServicesEnabled = true,
  }) =>
      _client.scanForDevices(
        withServices: withServices,
        scanMode: scanMode,
        requireLocationServicesEnabled: requireLocationServicesEnabled,
      );

  @override
  Stream<ConnectionStateUpdate> connectToAdvertisingDevice({
    required String id,
    required List<Uuid> withServices,
    required Duration prescanDuration,
    Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover,
    Duration? connectionTimeout,
  }) =>
      _client.connectToAdvertisingDevice(
        id: id,
        withServices: withServices,
        prescanDuration: prescanDuration,
        servicesWithCharacteristicsToDiscover:
            servicesWithCharacteristicsToDiscover,
        connectionTimeout: connectionTimeout,
      );

  @override
  Stream<List<int>> subscribeToCharacteristic(
    QualifiedCharacteristic characteristic,
  ) =>
      _client.subscribeToCharacteristic(characteristic);

  @override
  Future<void> writeCharacteristicWithResponse(
    QualifiedCharacteristic characteristic, {
    required List<int> value,
  }) =>
      _client.writeCharacteristicWithResponse(
        characteristic,
        value: value,
      );

  @override
  Future<void> writeCharacteristicWithoutResponse(
    QualifiedCharacteristic characteristic, {
    required List<int> value,
  }) =>
      _client.writeCharacteristicWithoutResponse(
        characteristic,
        value: value,
      );
}

class BLESerial extends AbstractSerial {
  BLESerial({
    required super.log,
    ReactiveBleClient? reactiveBle,
    Duration handshakeTimeout = defaultHandshakeTimeout,
    Duration connectionAttemptTimeout = defaultConnectionAttemptTimeout,
    Duration retryDelay = defaultRetryDelay,
  })  : _reactiveBle = reactiveBle ?? FlutterReactiveBleClient(),
        _handshakeTimeout = handshakeTimeout,
        _connectionAttemptTimeout = connectionAttemptTimeout,
        _retryDelay = retryDelay;

  static const defaultConnectionAttemptTimeout = Duration(seconds: 7);
  static const defaultHandshakeTimeout = Duration(seconds: 3);
  static const defaultRetryDelay = Duration(milliseconds: 250);
  static const _connectionCleanupTimeout = Duration(milliseconds: 250);

  final ReactiveBleClient _reactiveBle;
  final Duration _handshakeTimeout;
  final Duration _connectionAttemptTimeout;
  final Duration _retryDelay;
  QualifiedCharacteristic? txCharacteristic;
  QualifiedCharacteristic? rxCharacteristic;
  QualifiedCharacteristic? firmwareCharacteristic;
  Stream<List<int>>? receivedDataStream;
  StreamSubscription<ConnectionStateUpdate>? connection;
  _BleConnectionAttempt? _activeConnectionAttempt;
  _BleScanAttempt? _activeScan;
  Map<String, Chameleon> chameleonMap = {};
  bool inSearch = false;

  Future<List> availableDevices() async {
    if (connected || pendingConnection || connection != null) {
      return [];
    }
    if (inSearch) {
      log.w("Multiple searches in one time not allowed! FIXME");
      return [];
    }

    final attempt = _BleScanAttempt();
    _activeScan = attempt;
    inSearch = true;
    final subscription = _reactiveBle.scanForDevices(
      withServices: [nrfUUID, dfuUUID],
      scanMode: ScanMode.lowLatency,
    ).listen((device) {
      if (!attempt.foundDevices.contains(device)) {
        for (var foundDevice in attempt.foundDevices) {
          if (foundDevice.id == device.id) {
            return;
          }
        }
        attempt.foundDevices.add(device);
      }
    }, onError: (Object error) async {
      await _finishScan(
        attempt,
        error: Platform.isIOS ? error : null,
      );
      log.e("Got BLE search error: $error");
    });
    attempt.subscription = subscription;

    attempt.timer = Timer(const Duration(seconds: 2), () async {
      await _finishScan(attempt);
    });

    return attempt.result.future;
  }

  Future<void> _finishScan(
    _BleScanAttempt attempt, {
    Object? error,
  }) {
    final existing = attempt.finishFuture;
    if (existing != null) {
      return existing;
    }
    final finishing = _finishScanOnce(attempt, error: error);
    attempt.finishFuture = finishing;
    return finishing;
  }

  Future<void> _finishScanOnce(
    _BleScanAttempt attempt, {
    Object? error,
  }) async {
    attempt.timer?.cancel();
    attempt.timer = null;
    final subscription = attempt.subscription;
    attempt.subscription = null;
    if (subscription != null) {
      try {
        await subscription.cancel().timeout(_connectionCleanupTimeout);
      } on TimeoutException {
        log.w('BLE scan cleanup timed out');
      }
    }
    if (identical(_activeScan, attempt)) {
      _activeScan = null;
      inSearch = false;
    }
    if (!attempt.result.isCompleted) {
      if (error != null) {
        attempt.result.completeError(error);
      } else {
        attempt.result.complete(attempt.foundDevices);
        log.d('Found BLE devices: ${attempt.foundDevices.length}');
      }
    }
  }

  @override
  bool isManualConnectionSupported() {
    return false;
  }

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async {
    List<Chameleon> output = [];
    for (var bleDevice in await availableDevices()) {
      var dfuMode = false;
      if (bleDevice.name.startsWith('ChameleonUltra')) {
        device = ChameleonDevice.ultra;
      } else if (bleDevice.name.startsWith('ChameleonLite')) {
        device = ChameleonDevice.lite;
      } else if (bleDevice.name.startsWith('CU-')) {
        device = ChameleonDevice.ultra;
        dfuMode = true;
      } else if (bleDevice.name.startsWith('CL-')) {
        device = ChameleonDevice.lite;
        dfuMode = true;
      } else {
        // regular nRF device with UART
        continue;
      }

      connectionType = ConnectionType.ble;

      log.d("Found Chameleon ${chameleonDeviceName(device)}!");
      if (!onlyDFU || onlyDFU && dfuMode) {
        output.add(Chameleon(
            port: bleDevice.id,
            device: device,
            type: connectionType,
            dfu: dfuMode));
      }

      chameleonMap[bleDevice.id] = Chameleon(
          port: bleDevice.id,
          device: device,
          type: connectionType,
          dfu: dfuMode);
    }

    return output;
  }

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async {
    // As BLE is unstable, we try to connect 5 times
    // And fail only then
    bool ret = false;
    for (var i = 0; i < 5; i++) {
      ret = await connectSpecificInternal(devicePort);
      if (ret) {
        break;
      }
      if (i < 4) {
        await Future<void>.delayed(_retryDelay);
      }
    }

    if (!ret) {
      notifyConnectionStateChanged();
    }

    return ret;
  }

  Future<bool> connectSpecificInternal(dynamic devicePort) async {
    List<Uuid> services = [nrfUUID, uartRX, uartTX];
    if (chameleonMap[devicePort]!.dfu) {
      services = [dfuUUID, dfuControl, dfuFirmware];
    }

    await _performDisconnect(notify: false);
    final attempt = _BleConnectionAttempt();
    _activeConnectionAttempt = attempt;
    pendingConnection = true;
    notifyConnectionStateChanged();
    final connectionStream = _reactiveBle.connectToAdvertisingDevice(
      id: devicePort,
      withServices: services,
      prescanDuration: const Duration(seconds: 5),
      connectionTimeout: _connectionAttemptTimeout,
    );
    attempt.connectionWatchdog = Timer(_connectionAttemptTimeout, () async {
      await _disconnectConnectionAttempt(attempt);
    });
    final subscription = connectionStream.listen((connectionState) async {
      log.w(connectionState);
      if (!_ownsConnectionAttempt(attempt)) {
        return;
      }
      if (connectionState.connectionState == DeviceConnectionState.connected) {
        attempt.connectionWatchdog?.cancel();
        attempt.connectionWatchdog = null;
        if (chameleonMap[devicePort]!.dfu) {
          connected = true;
          pendingConnection = false;
          txCharacteristic = QualifiedCharacteristic(
              serviceId: dfuUUID,
              characteristicId: dfuControl,
              deviceId: connectionState.deviceId);
          receivedDataStream =
              _reactiveBle.subscribeToCharacteristic(txCharacteristic!);
          receivedDataStream!.listen((data) async {
            if (!_ownsConnectionAttempt(attempt)) {
              return;
            }
            if (messageCallback != null) {
              try {
                await messageCallback(Uint8List.fromList(data));
              } catch (_) {
                logUnexpectedSerialData(Uint8List.fromList(data));
              }
            }
          }, onError: (dynamic error) async {
            await _disconnectConnectionAttempt(attempt);
            log.e(error);
          });

          rxCharacteristic = QualifiedCharacteristic(
              serviceId: dfuUUID,
              characteristicId: dfuControl,
              deviceId: connectionState.deviceId);

          firmwareCharacteristic = QualifiedCharacteristic(
              serviceId: dfuUUID,
              characteristicId: dfuFirmware,
              deviceId: connectionState.deviceId);

          portName = devicePort;
          device = chameleonMap[devicePort]!.device;
          activeDevicePort = devicePort;

          isDFU = true;
          attempt.result.complete(true);
        } else {
          txCharacteristic = QualifiedCharacteristic(
              serviceId: nrfUUID,
              characteristicId: uartTX,
              deviceId: connectionState.deviceId);
          receivedDataStream =
              _reactiveBle.subscribeToCharacteristic(txCharacteristic!);
          receivedDataStream!.listen((data) async {
            if (!_ownsConnectionAttempt(attempt)) {
              return;
            }
            if (messageCallback != null) {
              try {
                await messageCallback(Uint8List.fromList(data));
              } catch (_) {
                logUnexpectedSerialData(Uint8List.fromList(data));
              }
            }
          }, onError: (dynamic error) async {
            await _disconnectConnectionAttempt(attempt);
            log.e(error);
          });

          rxCharacteristic = QualifiedCharacteristic(
              serviceId: nrfUUID,
              characteristicId: uartRX,
              deviceId: connectionState.deviceId);

          try {
            await _reactiveBle
                .writeCharacteristicWithResponse(
                  rxCharacteristic!,
                  value: Uint8List.fromList([
                    0x11,
                    0xef,
                    0x03,
                    0xfb,
                    0x00,
                    0x00,
                    0x00,
                    0x00,
                    0x02,
                    0x00
                  ]),
                )
                .timeout(_handshakeTimeout);

            if (!_ownsConnectionAttempt(attempt)) {
              return;
            }
            connected = true;
            pendingConnection = false;
            portName = devicePort;
            device = chameleonMap[devicePort]!.device;
            activeDevicePort = devicePort;

            connectionType = ConnectionType.ble;
            isDFU = false;

            attempt.result.complete(true);
          } catch (error) {
            log.w('BLE handshake failed', error: error);
            await _disconnectConnectionAttempt(attempt);
          }
        }
      } else if (connectionState.connectionState ==
          DeviceConnectionState.disconnected) {
        await _disconnectConnectionAttempt(attempt);
      }
    }, onError: (Object error) async {
      log.e(error);
      await _disconnectConnectionAttempt(attempt);
    });
    attempt.subscription = subscription;
    if (_ownsConnectionAttempt(attempt)) {
      connection = subscription;
    } else {
      await _cancelConnectionSubscription(subscription);
    }

    return attempt.result.future;
  }

  @override
  Future<bool> performDisconnect() => _performDisconnect();

  Future<bool> _performDisconnect({bool notify = true}) async {
    final scan = _activeScan;
    if (scan != null) {
      await _finishScan(scan);
    }
    final attempt = _activeConnectionAttempt;
    if (attempt != null) {
      return _disconnectConnectionAttempt(attempt, notify: notify);
    }

    final hadState = hasConnectionState || connection != null;
    resetConnectionState();
    txCharacteristic = null;
    rxCharacteristic = null;
    firmwareCharacteristic = null;
    receivedDataStream = null;
    if (connection != null) {
      await connection!.cancel();
      connection = null;
      connected = false;
      if (hadState && notify) {
        notifyConnectionStateChanged();
      }
      return true;
    }
    connected = false; // For debug button
    if (hadState && notify) {
      notifyConnectionStateChanged();
    }
    return false;
  }

  bool _ownsConnectionAttempt(_BleConnectionAttempt attempt) =>
      identical(_activeConnectionAttempt, attempt);

  Future<bool> _disconnectConnectionAttempt(
    _BleConnectionAttempt attempt, {
    bool? notify,
  }) async {
    if (!_ownsConnectionAttempt(attempt)) {
      return false;
    }

    final shouldNotify = notify ?? attempt.result.isCompleted;
    final subscription = attempt.subscription;
    final hadState = hasConnectionState || subscription != null;
    attempt.connectionWatchdog?.cancel();
    attempt.connectionWatchdog = null;
    _activeConnectionAttempt = null;
    if (identical(connection, subscription)) {
      connection = null;
    }
    resetConnectionState();
    txCharacteristic = null;
    rxCharacteristic = null;
    firmwareCharacteristic = null;
    receivedDataStream = null;
    if (subscription != null) {
      await _cancelConnectionSubscription(subscription);
    }
    if (!attempt.result.isCompleted) {
      attempt.result.complete(false);
    }
    if (hadState && shouldNotify) {
      notifyConnectionStateChanged();
    }
    return hadState;
  }

  Future<void> _cancelConnectionSubscription(
    StreamSubscription<ConnectionStateUpdate> subscription,
  ) async {
    try {
      await subscription.cancel().timeout(_connectionCleanupTimeout);
    } on TimeoutException {
      log.w('BLE connection cleanup timed out');
    }
  }

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async {
    if (firmware) {
      await _reactiveBle.writeCharacteristicWithoutResponse(
          firmwareCharacteristic!,
          value: command);
    } else {
      await _reactiveBle.writeCharacteristicWithResponse(rxCharacteristic!,
          value: command);
    }

    return true;
  }
}

class _BleConnectionAttempt {
  final result = Completer<bool>();
  StreamSubscription<ConnectionStateUpdate>? subscription;
  Timer? connectionWatchdog;
}

class _BleScanAttempt {
  final foundDevices = <DiscoveredDevice>[];
  final result = Completer<List<DiscoveredDevice>>();
  StreamSubscription<DiscoveredDevice>? subscription;
  Timer? timer;
  Future<void>? finishFuture;
}
