import 'dart:io';

import 'package:chameleonultragui/gui/component/mifare/key_profile_file.dart';
import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _filePickerChannel = MethodChannel(
  'miguelruivo.flutter.plugins.filepicker',
  StandardMethodCodec(),
);

MifareClassicKeyProfile _profile({String name = 'Picked keys'}) =>
    MifareClassicKeyProfile(
      id: 'picked-profile',
      name: name,
      cardType: 'm1k',
      sectorCount: 16,
      assignments: [
        MifareClassicKeyAssignment(
          sector: 0,
          keyA: Uint8List.fromList([1, 2, 3, 4, 5, 6]),
        ),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('profile file export writes canonical bytes with a safe name', () async {
    final profile = _profile(name: 'Office / west');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_filePickerChannel, (call) async {
      calls.add(call);
      return '/tmp/Office_west.mf1keys.json';
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_filePickerChannel, null));

    final exported = await exportMifareClassicKeyProfileFile(
      profile,
      dialogTitle: 'Output file:',
    );

    expect(exported, isTrue);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'save');
    final arguments = calls.single.arguments as Map;
    expect(arguments['fileName'], 'Office_west.mf1keys.json');
    expect(arguments['bytes'], profile.toFile());
  });

  test('profile file export reports picker cancellation', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_filePickerChannel, (call) async => null);
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_filePickerChannel, null));

    final exported = await exportMifareClassicKeyProfileFile(
      _profile(),
      dialogTitle: 'Output file:',
    );

    expect(exported, isFalse);
  });

  test('profile file import uses the single-file picker API', () async {
    final profile = _profile();
    final directory = await Directory.systemTemp.createTemp('mf1-profile-');
    final file = File('${directory.path}/picked.mf1keys.json');
    await file.writeAsString(profile.toJson());
    addTearDown(() => directory.delete(recursive: true));

    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_filePickerChannel, (call) async {
      calls.add(call);
      return [
        {
          'path': file.path,
          'name': file.uri.pathSegments.last,
          'size': await file.length(),
          'bytes': null,
        },
      ];
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_filePickerChannel, null));

    final imported = await pickMifareClassicKeyProfileFile();

    expect(calls, hasLength(1));
    expect((calls.single.arguments as Map)['allowMultipleSelection'], isFalse);
    expect(imported?.id, 'picked-profile');
  });
}
