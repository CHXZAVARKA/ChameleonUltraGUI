import 'package:chameleonultragui/helpers/general.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'serial_abstract.dart';

typedef NativeDiscoveryCallback = List<Chameleon> Function(bool onlyDFU);

class NativeSerial extends AbstractSerial {
  // Class for PC Serial Communication
  SerialPort? port;
  SerialPort? checkPort;
  bool checkDFU = true;
  SerialPortReader? reader;

  NativeSerial({
    required super.log,
    @visibleForTesting NativeDiscoveryCallback? discoveryCallback,
  }) : _discoveryCallback = discoveryCallback ?? _discoverNativeChameleons;

  final NativeDiscoveryCallback _discoveryCallback;
  static const int _flowControl = SerialPortFlowControl.none;

  @override
  bool isManualConnectionSupported() {
    return true;
  }

  Future<List> availableDevices() async {
    return SerialPort.availablePorts;
  }

  @override
  Future<bool> performConnect() async {
    for (final port in await availableDevices()) {
      if (await connectDevice(port, true)) {
        portName = port;
        connected = true;
        return true;
      }
    }
    return false;
  }

  @override
  Future<bool> performDisconnect() async {
    final hadState = hasConnectionState || port != null || reader != null;
    resetConnectionState();
    if (port != null) {
      reader?.close();
      port?.close();
      reader = null;
      port = null;
      if (hadState) {
        notifyConnectionStateChanged();
      }
      return true;
    }
    if (hadState) {
      notifyConnectionStateChanged();
    }
    return false;
  }

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async {
    // flutter_libserialport owns native FFI state that is not safe to probe
    // from a temporary background isolate on macOS. Yield once so the loader
    // can paint, then keep the short metadata probe on the caller isolate.
    await Future<void>.delayed(Duration.zero);
    final output = _discoveryCallback(onlyDFU);
    for (final chameleon in output) {
      log.d("Found Chameleon ${chameleonDeviceName(chameleon.device)}!");
    }
    return output;
  }

  static ChameleonDevice? _detectedDevice({
    required String? manufacturer,
    required String? description,
    required String? productName,
  }) {
    final normalizedDescription = description?.toLowerCase();
    if (manufacturer != "Proxgrind" &&
        !(normalizedDescription?.contains("chameleon") ?? false)) {
      return null;
    }

    if ((productName?.contains('ChameleonUltra') ?? false) ||
        (normalizedDescription?.contains('ultra') ?? false)) {
      return ChameleonDevice.ultra;
    }
    return ChameleonDevice.lite;
  }

  static SerialPortConfig _serialConfig() {
    return SerialPortConfig()
      ..baudRate = 115200
      ..bits = 8
      ..stopBits = 1
      ..parity = SerialPortParity.none
      ..rts = SerialPortRts.flowControl
      ..cts = SerialPortCts.flowControl
      ..dsr = SerialPortDsr.flowControl
      ..dtr = SerialPortDtr.flowControl
      ..setFlowControl(_flowControl);
  }

  @visibleForTesting
  static int get flowControlForTesting => _flowControl;

  static List<Chameleon> _discoverNativeChameleons(bool onlyDFU) {
    final output = <Chameleon>[];
    for (final address in SerialPort.availablePorts) {
      final candidate = SerialPort(address);
      var opened = false;
      try {
        opened = candidate.openReadWrite();
        if (!opened) {
          continue;
        }
        candidate.config = _serialConfig();
        final detectedDevice = _detectedDevice(
          manufacturer: candidate.manufacturer,
          description: candidate.description,
          productName: candidate.productName,
        );
        if (detectedDevice == null) {
          continue;
        }

        final dfu = candidate.vendorId == 0x1915;
        if (!onlyDFU || dfu) {
          output.add(
            Chameleon(
              port: address,
              device: detectedDevice,
              type: ConnectionType.usb,
              dfu: dfu,
            ),
          );
        }
      } on SerialPortError {
        // Ports can disappear or become busy between enumeration and probing.
      } finally {
        if (opened) {
          candidate.close();
        }
        candidate.dispose();
      }
    }
    return output;
  }

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async {
    if (await connectDevice(devicePort, true)) {
      portName = devicePort;
      connected = true;
      activeDevicePort = devicePort;
      return true;
    }
    return false;
  }

  Future<bool> connectDevice(String address, bool setPort) async {
    if (port != null && port!.isOpen && !setPort) {
      log.d("Chameleon is connected now");
    }

    log.d("Connecting to $address");
    try {
      checkPort = SerialPort(address);
      checkPort!.openReadWrite();
      checkPort!.config = _serialConfig();
      log.d("Connected to $address");
      log.d("Manufacturer: ${checkPort!.manufacturer}");
      log.d("Product: ${checkPort!.productName}");

      final detectedDevice = _detectedDevice(
        manufacturer: checkPort!.manufacturer,
        description: checkPort!.description,
        productName: checkPort!.productName,
      );
      final isChameleon = detectedDevice != null || setPort;
      device = detectedDevice ?? ChameleonDevice.ultra;

      if (isChameleon) {
        log.d("Found Chameleon ${chameleonDeviceName(device)}!");

        connectionType = ConnectionType.usb;

        checkDFU = checkPort!.vendorId == 0x1915;

        checkPort!.close();

        if (setPort) {
          port = checkPort;
          isDFU = checkDFU;
        }

        return true;
      }

      checkPort!.close();
      return false;
    } on SerialPortError catch (e) {
      log.e(e);
      try {
        checkPort?.close();
      } catch (_) {}
      return false;
    }
  }

  @override
  Future<void> open() async {
    port!.openReadWrite();
    reader = SerialPortReader(port!, timeout: 2500);
    reader?.stream.listen((data) async {
      try {
        await messageCallback(data);
      } catch (_) {
        logUnexpectedSerialData(data);
      }
    }, onDone: () async {
      await performDisconnect();
    }, onError: (_) async {
      await performDisconnect();
    });
  }

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async {
    port!.write(command);
    port!.drain();
    return true;
  }
}
