import 'dart:io';

import 'package:chameleonultragui/gui/component/mifare/key_profile_file.dart';
import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('profile file import uses the single-file picker API', () async {
    final profile = MifareClassicKeyProfile(
      id: 'picked-profile',
      name: 'Picked keys',
      cardType: 'm1k',
      sectorCount: 16,
      assignments: [
        MifareClassicKeyAssignment(
          sector: 0,
          keyA: Uint8List.fromList([1, 2, 3, 4, 5, 6]),
        ),
      ],
    );
    final directory = await Directory.systemTemp.createTemp('mf1-profile-');
    final file = File('${directory.path}/picked.mf1keys.json');
    await file.writeAsString(profile.toJson());
    addTearDown(() => directory.delete(recursive: true));

    const channel = MethodChannel(
      'miguelruivo.flutter.plugins.filepicker',
      StandardMethodCodec(),
    );
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
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
        .setMockMethodCallHandler(channel, null));

    final imported = await pickMifareClassicKeyProfileFile();

    expect(calls, hasLength(1));
    expect((calls.single.arguments as Map)['allowMultipleSelection'], isFalse);
    expect(imported?.id, 'picked-profile');
  });
}
