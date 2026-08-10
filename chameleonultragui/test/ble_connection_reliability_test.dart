import 'dart:async';

import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/connector/serial_ble.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart' as app_logger;

void main() {
  test('one BLE connect retries after a stalled attempt', () async {
    final reactiveBle = _StallThenConnectBle();
    final serial = BLESerial(
      log: app_logger.Logger(output: app_logger.MemoryOutput()),
      reactiveBle: reactiveBle,
    )
      ..chameleonMap['device'] = const Chameleon(
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
  });
}

class _StallThenConnectBle implements FlutterReactiveBle {
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
  ) => const Stream.empty();

  @override
  Future<void> writeCharacteristicWithResponse(
    QualifiedCharacteristic characteristic, {
    required List<int> value,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
