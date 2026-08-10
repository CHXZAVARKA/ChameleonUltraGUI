import 'dart:async';
import 'dart:typed_data';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/connector/serial_ble.dart';
import 'package:chameleonultragui/connector/serial_mobile.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

// Class combines Android OTG and BLE serial
class AndroidSerial extends AbstractSerial {
  late BLESerial bleSerial;
  late MobileSerial mobileSerial;
  Future<bool>? permissionRequestFuture;
  late bool hasAllPermissions = true;

  AndroidSerial({
    required super.log,
    BLESerial? bleSerial,
    MobileSerial? mobileSerial,
  }) {
    this.bleSerial = bleSerial ?? BLESerial(log: log);
    this.mobileSerial = mobileSerial ?? MobileSerial(log: log);
    this.bleSerial.connectionStateCallback = notifyConnectionStateChanged;
    this.mobileSerial.connectionStateCallback = notifyConnectionStateChanged;
  }

  @override
  Future<bool> performDisconnect() async {
    bool ble = await bleSerial.performDisconnect();
    bool otg = await mobileSerial.performDisconnect();
    final wasPending = pendingConnection;
    pendingConnection = false;
    if (wasPending) {
      notifyConnectionStateChanged();
    }
    return (ble || otg || wasPending);
  }

  @override
  bool isManualConnectionSupported() {
    return false;
  }

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async {
    if (connected || pendingConnection) {
      return [];
    }
    List<Chameleon> output = [];

    output.addAll(await mobileSerial.availableChameleons(onlyDFU));
    hasAllPermissions = await checkPermissions();
    if (hasAllPermissions) {
      output.addAll(await bleSerial.availableChameleons(onlyDFU));
    }

    return output;
  }

  @override
  Future<bool> connectDiscoveredDevice(Chameleon chameleon) {
    switch (chameleon.type) {
      case ConnectionType.ble:
        return bleSerial.connectSpecificDevice(chameleon.port);
      case ConnectionType.usb:
        return mobileSerial.connectSpecificDevice(chameleon.port);
      case ConnectionType.none:
        return Future.value(false);
    }
  }

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async {
    if (devicePort.contains(":")) {
      return await bleSerial.connectSpecificDevice(devicePort);
    } else {
      return await mobileSerial.connectSpecificDevice(devicePort);
    }
  }

  Future<bool> checkPermissions() async {
    if (permissionRequestFuture != null) {
      return await permissionRequestFuture!;
    }

    final completer = Completer<bool>();
    permissionRequestFuture = completer.future;

    try {
      final statuses = await [
        Permission.location,
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect
      ].request();

      final allGranted = statuses.values.every((status) => status.isGranted);
      completer.complete(allGranted);
      return allGranted;
    } catch (e) {
      completer.completeError(e);
      rethrow;
    } finally {
      permissionRequestFuture = null;
    }
  }

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async {
    if (bleSerial.connected) {
      return await bleSerial.write(command, firmware: firmware);
    } else {
      return await mobileSerial.write(command, firmware: firmware);
    }
  }

  @override
  Future<void> registerCallback(dynamic callback) async {
    await bleSerial.registerCallback(callback);
    await mobileSerial.registerCallback(callback);
  }

  @override
  dynamic get activeDevicePort => (bleSerial.connected)
      ? bleSerial.activeDevicePort
      : mobileSerial.activeDevicePort;

  @override
  ChameleonDevice get device =>
      (bleSerial.connected) ? bleSerial.device : mobileSerial.device;

  @override
  bool get connected => (bleSerial.connected || mobileSerial.connected);

  @override
  String get portName =>
      (bleSerial.connected) ? bleSerial.portName : mobileSerial.portName;

  @override
  ConnectionType get connectionType => (bleSerial.connected)
      ? bleSerial.connectionType
      : mobileSerial.connectionType;

  @override
  bool get isOpen => (bleSerial.isOpen || mobileSerial.isOpen);

  @override
  set isOpen(open) => {bleSerial.isOpen = mobileSerial.isOpen = open};

  @override
  bool get isDFU => (bleSerial.isDFU || mobileSerial.isDFU);
}
