import 'dart:typed_data';

import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/connector/serial_android.dart';
import 'package:chameleonultragui/connector/serial_ble.dart';
import 'package:chameleonultragui/connector/serial_macos.dart';
import 'package:chameleonultragui/connector/serial_mobile.dart';
import 'package:chameleonultragui/connector/serial_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('macOS routes discovered devices by their selected transport', () async {
    final logger = Logger(output: MemoryOutput());
    final ble = _RecordingBleSerial(log: logger);
    final usb = _RecordingNativeSerial(log: logger);
    final serial = MacOSSerial(
      log: logger,
      bleSerial: ble,
      nativeSerial: usb,
    );
    addTearDown(logger.close);

    await serial.connectDiscoveredDevice(
      const Chameleon(
        port: '/dev/identifier-that-must-stay-ble',
        device: ChameleonDevice.ultra,
        type: ConnectionType.ble,
        dfu: false,
      ),
    );
    await serial.connectDiscoveredDevice(
      const Chameleon(
        port: 'identifier:that:must:stay:usb',
        device: ChameleonDevice.ultra,
        type: ConnectionType.usb,
        dfu: false,
      ),
    );

    expect(ble.connectAttempts, ['/dev/identifier-that-must-stay-ble']);
    expect(usb.connectAttempts, ['identifier:that:must:stay:usb']);
  });

  test('Android routes discovered devices by their selected transport',
      () async {
    final logger = Logger(output: MemoryOutput());
    final ble = _RecordingBleSerial(log: logger);
    final usb = _RecordingMobileSerial(log: logger);
    final serial = AndroidSerial(
      log: logger,
      bleSerial: ble,
      mobileSerial: usb,
    );
    addTearDown(logger.close);

    await serial.connectDiscoveredDevice(
      const Chameleon(
        port: 'identifier-without-colons-that-must-stay-ble',
        device: ChameleonDevice.ultra,
        type: ConnectionType.ble,
        dfu: false,
      ),
    );
    await serial.connectDiscoveredDevice(
      const Chameleon(
        port: 'usb:identifier:with:colons',
        device: ChameleonDevice.ultra,
        type: ConnectionType.usb,
        dfu: false,
      ),
    );

    expect(
      ble.connectAttempts,
      ['identifier-without-colons-that-must-stay-ble'],
    );
    expect(usb.connectAttempts, ['usb:identifier:with:colons']);
  });

  test('composite connectors keep an attempt pending across child resets',
      () async {
    final logger = Logger(output: MemoryOutput());
    final macBle = _RecordingBleSerial(log: logger);
    final macUsb = _RecordingNativeSerial(log: logger);
    final mac = MacOSSerial(
      log: logger,
      bleSerial: macBle,
      nativeSerial: macUsb,
    )..pendingConnection = true;
    final androidBle = _RecordingBleSerial(log: logger);
    final androidUsb = _RecordingMobileSerial(log: logger);
    final android = AndroidSerial(
      log: logger,
      bleSerial: androidBle,
      mobileSerial: androidUsb,
    )..pendingConnection = true;
    addTearDown(logger.close);

    macBle.pendingConnection = false;
    androidBle.pendingConnection = false;

    expect(mac.pendingConnection, isTrue);
    expect(android.pendingConnection, isTrue);
    expect(await mac.availableChameleons(false), isEmpty);
    expect(await android.availableChameleons(false), isEmpty);
    expect(macBle.discoveryCalls, 0);
    expect(macUsb.discoveryCalls, 0);
    expect(androidBle.discoveryCalls, 0);
    expect(androidUsb.discoveryCalls, 0);
    expect(await mac.performDisconnect(), isTrue);
    expect(await android.performDisconnect(), isTrue);
    expect(mac.pendingConnection, isFalse);
    expect(android.pendingConnection, isFalse);
  });
}

class _RecordingBleSerial extends BLESerial {
  _RecordingBleSerial({required super.log})
      : super(reactiveBle: _NoopReactiveBleClient());

  final List<dynamic> connectAttempts = [];
  int discoveryCalls = 0;

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async {
    connectAttempts.add(devicePort);
    return true;
  }

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async {
    discoveryCalls++;
    return const [];
  }
}

class _NoopReactiveBleClient extends Fake implements ReactiveBleClient {}

class _RecordingNativeSerial extends NativeSerial {
  _RecordingNativeSerial({required super.log})
      : super(discoveryCallback: _noNativeDevices);

  final List<dynamic> connectAttempts = [];
  int discoveryCalls = 0;

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async {
    connectAttempts.add(devicePort);
    return true;
  }

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async {
    discoveryCalls++;
    return const [];
  }
}

class _RecordingMobileSerial extends MobileSerial {
  _RecordingMobileSerial({required super.log});

  final List<dynamic> connectAttempts = [];
  int discoveryCalls = 0;

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async {
    connectAttempts.add(devicePort);
    return true;
  }

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async {
    discoveryCalls++;
    return const [];
  }

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => true;
}

List<Chameleon> _noNativeDevices(bool onlyDfu) => const [];
