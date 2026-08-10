import 'dart:async';
import 'dart:typed_data';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/connector/serial_ble.dart';
import 'package:chameleonultragui/connector/serial_native.dart';

// Class combines macOS Native Serial and BLE serial
class MacOSSerial extends AbstractSerial {
  late BLESerial bleSerial;
  late NativeSerial nativeSerial;

  MacOSSerial({
    required super.log,
    BLESerial? bleSerial,
    NativeSerial? nativeSerial,
  }) {
    this.bleSerial = bleSerial ?? BLESerial(log: log);
    this.nativeSerial = nativeSerial ?? NativeSerial(log: log);
    this.bleSerial.connectionStateCallback = notifyConnectionStateChanged;
    this.nativeSerial.connectionStateCallback = notifyConnectionStateChanged;
  }

  @override
  Future<bool> performDisconnect() async {
    bool ble = await bleSerial.performDisconnect();
    bool native = await nativeSerial.performDisconnect();
    final wasPending = pendingConnection;
    pendingConnection = false;
    if (wasPending) {
      notifyConnectionStateChanged();
    }
    return (ble || native || wasPending);
  }

  @override
  bool isManualConnectionSupported() {
    return nativeSerial.isManualConnectionSupported();
  }

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async {
    if (connected || pendingConnection) {
      return [];
    }
    List<Chameleon> output = [];

    output.addAll(await nativeSerial.availableChameleons(onlyDFU));
    output.addAll(await bleSerial.availableChameleons(onlyDFU));

    return output;
  }

  @override
  Future<bool> connectDiscoveredDevice(Chameleon chameleon) {
    switch (chameleon.type) {
      case ConnectionType.ble:
        return bleSerial.connectSpecificDevice(chameleon.port);
      case ConnectionType.usb:
        return nativeSerial.connectSpecificDevice(chameleon.port);
      case ConnectionType.none:
        return Future.value(false);
    }
  }

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async {
    if (devicePort.contains("/dev")) {
      return await nativeSerial.connectSpecificDevice(devicePort);
    } else {
      return await bleSerial.connectSpecificDevice(devicePort);
    }
  }

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async {
    if (bleSerial.connected) {
      return await bleSerial.write(command, firmware: firmware);
    } else {
      return await nativeSerial.write(command, firmware: firmware);
    }
  }

  @override
  Future<void> registerCallback(dynamic callback) async {
    await bleSerial.registerCallback(callback);
    await nativeSerial.registerCallback(callback);
  }

  @override
  dynamic get activeDevicePort => (bleSerial.connected)
      ? bleSerial.activeDevicePort
      : nativeSerial.activeDevicePort;

  @override
  ChameleonDevice get device =>
      (bleSerial.connected) ? bleSerial.device : nativeSerial.device;

  @override
  bool get connected => (bleSerial.connected || nativeSerial.connected);

  @override
  String get portName =>
      (bleSerial.connected) ? bleSerial.portName : nativeSerial.portName;

  @override
  ConnectionType get connectionType => (bleSerial.connected)
      ? bleSerial.connectionType
      : nativeSerial.connectionType;

  @override
  bool get isOpen => (bleSerial.isOpen || nativeSerial.isOpen);

  @override
  set isOpen(open) => {bleSerial.isOpen = nativeSerial.isOpen = open};

  @override
  bool get isDFU => (bleSerial.isDFU || nativeSerial.isDFU);

  @override
  Future<void> open() async {
    if (bleSerial.connected) {
      await bleSerial.open();
    } else {
      await nativeSerial.open();
    }
  }
}
