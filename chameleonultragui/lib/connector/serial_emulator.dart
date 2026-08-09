import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:flutter/services.dart';

// Class for fake Chameleon Ultra device, aka emulator/demo
// Not all commands are implemented, nor should be
// For now main purpose is Apple reviews, maybe should be used for tests in future

class EmulatorSerial extends AbstractSerial {
  EmulatorSerial({required super.log, math.Random? random})
      : _random = random ?? math.Random() {
    _resetDemoState();
  }

  final math.Random _random;
  late List<_DemoSlot> _slots;
  late int _activeSlot;
  late bool _readerMode;
  late int _batteryPercent;
  late int _batteryVoltage;

  void _resetDemoState() {
    final templates = <_DemoSlotTemplate>[
      const _DemoSlotTemplate(hf: true, hfEnabled: true),
      const _DemoSlotTemplate(lf: true, lfEnabled: true),
      const _DemoSlotTemplate(
        hf: true,
        lf: true,
        hfEnabled: true,
        lfEnabled: false,
      ),
      const _DemoSlotTemplate(hf: true, hfEnabled: false),
      const _DemoSlotTemplate(lf: true, lfEnabled: false),
      const _DemoSlotTemplate(),
      const _DemoSlotTemplate(
        hf: true,
        lf: true,
        hfEnabled: true,
        lfEnabled: true,
      ),
      const _DemoSlotTemplate(hf: true, hfEnabled: true),
    ]..shuffle(_random);
    _slots = List.generate(
      templates.length,
      (index) => _DemoSlot.fromTemplate(templates[index], _random, index),
    );
    _activeSlot = _random.nextInt(_slots.length);
    _readerMode = _random.nextBool();
    _batteryPercent = 35 + _random.nextInt(61);
    _batteryVoltage = 3700 + (_batteryPercent * 5);
  }

  @override
  Future<bool> performConnect() async {
    return true;
  }

  @override
  Future<bool> performDisconnect() async {
    final hadState = hasConnectionState;
    resetConnectionState();
    if (hadState) {
      notifyConnectionStateChanged();
    }
    return true;
  }

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async {
    return [
      Chameleon(
          port: "Demo",
          device: ChameleonDevice.ultra,
          type: ConnectionType.usb,
          dfu: false)
    ];
  }

  Future<bool> connectDevice(String address, bool setPort) async {
    return true;
  }

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async {
    final dynamicResponse = _handleStatefulCommand(command);
    if (dynamicResponse != null) {
      await messageCallback(dynamicResponse);
    } else if (emulatedCommands.containsKey(bytesToHex(command))) {
      await messageCallback(hexToBytes(emulatedCommands[bytesToHex(command)]!));
    } else {
      log.e('Missing response for ${bytesToHex(command)}');
    }

    return true;
  }

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async {
    _resetDemoState();
    portName = "Demo";
    connected = true;
    device = ChameleonDevice.ultra;
    connectionType = ConnectionType.usb;
    activeDevicePort = devicePort;
    return true;
  }

  @override
  bool isManualConnectionSupported() {
    return false;
  }

  Uint8List? _handleStatefulCommand(Uint8List frame) {
    if (frame.length < 10) {
      return null;
    }
    final commandValue = (frame[2] << 8) | frame[3];
    final dataLength = (frame[6] << 8) | frame[7];
    final data = frame.sublist(9, 9 + dataLength);
    final command = ChameleonCommand.values
        .where((candidate) => candidate.value == commandValue)
        .firstOrNull;
    if (command == null) {
      return null;
    }

    Uint8List? responseData;
    var handled = true;
    switch (command) {
      case ChameleonCommand.getBatteryCharge:
        responseData = Uint8List.fromList([
          ...u16ToBytes(_batteryVoltage),
          _batteryPercent,
        ]);
      case ChameleonCommand.getDeviceMode:
        responseData = Uint8List.fromList([_readerMode ? 1 : 0]);
      case ChameleonCommand.changeDeviceMode:
        _readerMode = data.first == 1;
        responseData = Uint8List(0);
      case ChameleonCommand.getActiveSlot:
        responseData = Uint8List.fromList([_activeSlot]);
      case ChameleonCommand.setActiveSlot:
        _activeSlot = data.first.clamp(0, 7);
        responseData = Uint8List(0);
      case ChameleonCommand.getSlotInfo:
        responseData = Uint8List.fromList([
          for (final slot in _slots) ...[
            ...u16ToBytes(slot.hfType.value),
            ...u16ToBytes(slot.lfType.value),
          ],
        ]);
      case ChameleonCommand.getEnabledSlots:
        responseData = Uint8List.fromList([
          for (final slot in _slots) ...[
            slot.hfEnabled ? 1 : 0,
            slot.lfEnabled ? 1 : 0,
          ],
        ]);
      case ChameleonCommand.getAllSlotNicks:
        responseData = Uint8List.fromList([
          for (final slot in _slots) ...[
            utf8.encode(slot.hfName).length,
            ...utf8.encode(slot.hfName),
            utf8.encode(slot.lfName).length,
            ...utf8.encode(slot.lfName),
          ],
        ]);
      case ChameleonCommand.getSlotTagNick:
        final slot = _slots[data[0]];
        responseData = Uint8List.fromList(
          utf8.encode(
              data[1] == TagFrequency.hf.value ? slot.hfName : slot.lfName),
        );
      case ChameleonCommand.setSlotTagNick:
        final slot = _slots[data[0]];
        final name = utf8.decode(data.sublist(2), allowMalformed: true);
        if (data[1] == TagFrequency.hf.value) {
          slot.hfName = name;
        } else {
          slot.lfName = name;
        }
        responseData = Uint8List(0);
      case ChameleonCommand.setSlotEnable:
        final slot = _slots[data[0]];
        if (data[1] == TagFrequency.hf.value) {
          slot.hfEnabled = data[2] == 1;
        } else {
          slot.lfEnabled = data[2] == 1;
        }
        responseData = Uint8List(0);
      case ChameleonCommand.setSlotTagType:
        final slot = _slots[data[0]];
        final type = numberToChameleonTag(bytesToU16(data.sublist(1, 3)));
        if (chameleonTagToFrequency(type) == TagFrequency.hf) {
          slot.hfType = type;
        } else {
          slot.lfType = type;
        }
        responseData = Uint8List(0);
      case ChameleonCommand.deleteSlotInfo:
        final slot = _slots[data[0]];
        if (data[1] == TagFrequency.hf.value) {
          slot
            ..hfType = TagType.unknown
            ..hfEnabled = false
            ..hfName = '';
        } else {
          slot
            ..lfType = TagType.unknown
            ..lfEnabled = false
            ..lfName = '';
        }
        responseData = Uint8List(0);
      case ChameleonCommand.setSlotDataDefault:
      case ChameleonCommand.saveSlotNicks:
        responseData = Uint8List(0);
      default:
        handled = false;
    }
    return handled ? _makeResponseFrame(commandValue, responseData!) : null;
  }

  Uint8List _makeResponseFrame(int command, Uint8List data) {
    final frame = <int>[
      0x11,
      0xef,
      ...u16ToBytes(command),
      ...u16ToBytes(0x68),
      ...u16ToBytes(data.length),
    ];
    frame.add(_lrc(frame.sublist(2, 8)));
    frame.addAll(data);
    frame.add(_lrc(frame));
    return Uint8List.fromList(frame);
  }

  int _lrc(List<int> bytes) {
    var sum = 0;
    for (final byte in bytes) {
      sum = (sum + byte) & 0xff;
    }
    return (0x100 - sum) & 0xff;
  }
}

class _DemoSlotTemplate {
  const _DemoSlotTemplate({
    this.hf = false,
    this.lf = false,
    this.hfEnabled = false,
    this.lfEnabled = false,
  });

  final bool hf;
  final bool lf;
  final bool hfEnabled;
  final bool lfEnabled;
}

class _DemoSlot {
  _DemoSlot({
    required this.hfType,
    required this.lfType,
    required this.hfEnabled,
    required this.lfEnabled,
    required this.hfName,
    required this.lfName,
  });

  factory _DemoSlot.fromTemplate(
    _DemoSlotTemplate template,
    math.Random random,
    int index,
  ) {
    const hfTypes = [
      TagType.mifareMini,
      TagType.mifare1K,
      TagType.mifare4K,
      TagType.ntag213,
      TagType.ntag215,
      TagType.ultralight,
    ];
    const lfTypes = [
      TagType.em410X,
      TagType.hidProx,
      TagType.viking,
      TagType.pac,
      TagType.ioProx,
      TagType.idteck,
    ];
    const names = [
      'Office',
      'Garage',
      'Transit',
      'Studio',
      'Lab',
      'Archive',
      'Guest',
      'Alarm',
    ];
    String nameFor(String frequency) =>
        '${names[random.nextInt(names.length)]} $frequency${index + 1}';
    return _DemoSlot(
      hfType: template.hf
          ? hfTypes[random.nextInt(hfTypes.length)]
          : TagType.unknown,
      lfType: template.lf
          ? lfTypes[random.nextInt(lfTypes.length)]
          : TagType.unknown,
      hfEnabled: template.hfEnabled,
      lfEnabled: template.lfEnabled,
      hfName: template.hf ? nameFor('HF') : '',
      lfName: template.lf ? nameFor('LF') : '',
    );
  }

  TagType hfType;
  TagType lfType;
  bool hfEnabled;
  bool lfEnabled;
  String hfName;
  String lfName;
}

// write: read
Map<String, String> emulatedCommands = {
  '11ef03fb000000000200':
      '11ef03fb006800207a03e9000000000064044d00c803eb00000000000000000000044c000003e80096d8',
  '11ef040100000000fb00': '11ef0401006800039010846408',
  '11ef03e8000000001500': '11ef03e800680002ab0200fe',
  '11ef03f9000000000400':
      '11ef03f9006800138976322e302e302d3234342d67333033643264337e',
  '11ef03ea000000001300': '11ef03ea00680001aa01ff',
  '11ef03fa000000000300': '11ef03fa006800019a0000',
  '11ef03eb000000011101ff': '11ef03eb00680000aa00',
  '11ef03eb000000011102fe': '11ef03eb00680000aa00',
  '11ef03eb000000011103fd': '11ef03eb00680000aa00',
  '11ef03eb000000011104fc': '11ef03eb00680000aa00',
  '11ef03eb000000011105fb': '11ef03eb00680000aa00',
  '11ef03eb000000011106fa': '11ef03eb00680000aa00',
  '11ef03eb000000011107f9': '11ef03eb00680000aa00',
  '11ef03eb00000001110000': '11ef03eb00680000aa00',
  '11ef03e9000000011301ff': '11ef03e900680000ac00',
  '11ef03e900000001130000': '11ef03e900680000ac00',
  '11ef040a00000000f200': '11ef040a0068000d7d05000102030400313233343536bc',
  '11ef03ff00000000fe00':
      '11ef03ff006800108601000001010000000000010000000101fa',
  '11ef03f0000000020b0002fe': '11ef03f0007100009c00',
  '11ef03f0000000020b0001ff': '11ef03f0007100009c00',
  '11ef03f0000000020b0102fd': '11ef03f0007100009c00',
  '11ef03f0000000020b0101fe': '11ef03f0007100009c00',
  '11ef03f0000000020b0202fc': '11ef03f0007100009c00',
  '11ef03f0000000020b0201fd': '11ef03f0007100009c00',
  '11ef03f0000000020b0302fb': '11ef03f0007100009c00',
  '11ef03f0000000020b0301fc': '11ef03f0007100009c00',
  '11ef03f0000000020b0402fa': '11ef03f0007100009c00',
  '11ef03f0000000020b0401fb': '11ef03f0007100009c00',
  '11ef03f0000000020b0502f9': '11ef03f0007100009c00',
  '11ef03f0000000020b0501fa': '11ef03f0007100009c00',
  '11ef03f0000000020b0602f8': '11ef03f0007100009c00',
  '11ef03f0000000020b0601f9': '11ef03f0007100009c00',
  '11ef03f0000000020b0702f7': '11ef03f0007100009c00',
  '11ef03f0000000020b0701f8': '11ef03f0007100009c00',
  '11ef0fb2000000003f00': '11ef0fb200680009ce04deadbeef04000800b8',
  '11ef0fa9000000004800': '11ef0fa900680005db000000000000',
  '11ef1389000000006400': '11ef138900680005f7deadbeef8840',
  '11ef0bb8000000003d00': '11ef0bb800400005f80001111111cc',
  '11ef07d0000000002900': '11ef07d00000000920040000000000000000fc',
  '11ef07d1000000002800': '11ef07d1000200002600',
  '11ef07da0000000619f4006400086040': '11ef07da000100001e00',
  '11ef040b00000000f100':
      '11ef040b006800b2d703e803e903ea03eb03ec03ed03ee03ef03f003f103f203f303f403f503f603f703f803f903fa03fb03fc03fd03ff0400040104020403040404050407040604080409040a040b040c040d040e07d007d107d207d307d407d507d607de07d707d807d907da07db07dc07dd07df0bb80bb90fa00fa10fa40fa50fa60fa70fa80fa90faa0fab0fac0fad0fae0faf0fb00fb10fb20fb30fb40fb50fb60fb70fb80fb90fba0fbb0fbc0fbd0fbe0fbf0fc0138813895e',
  '11ef040e00000000ee00':
      '11ef040e0068004541064f6666696365000006476172616765075472616e73697404446f6f720741726368697665000000074d797374657279000844697361626c656400034c616205416c61726dec',
};
