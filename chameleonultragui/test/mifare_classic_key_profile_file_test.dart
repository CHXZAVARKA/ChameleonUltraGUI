import 'dart:io';

import 'support/file_picker.dart';

import 'package:chameleonultragui/gui/component/mifare/key_profile_file.dart';
import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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
  late TestFilePicker picker;
  setUp(() {
    final previous = FilePickerPlatform.instance;
    picker = TestFilePicker();
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previous);
  });

  test('profile file export writes canonical bytes with a safe name', () async {
    final profile = _profile(name: 'Office / west');
    picker.savedUri = Uri.file('/tmp/Office_west.mf1keys.json');
    expect(
      await exportMifareClassicKeyProfileFile(
        profile,
        dialogTitle: 'Output file:',
      ),
      isTrue,
    );
    expect(picker.savedName, 'Office_west.mf1keys.json');
    expect(picker.savedBytes, profile.toFile());
    expect(picker.saveCalls, 1);
  });

  test('profile file export reports picker cancellation', () async {
    expect(
      await exportMifareClassicKeyProfileFile(
        _profile(),
        dialogTitle: 'Output file:',
      ),
      isFalse,
    );
  });

  test('profile file import uses the single-file picker API', () async {
    final directory = await Directory.systemTemp.createTemp('mf1-profile-');
    final file = File('${directory.path}/picked.mf1keys.json');
    await file.writeAsString(_profile().toJson());
    addTearDown(() => directory.delete(recursive: true));
    picker.picked = _PickedProfile(file);
    expect((await pickMifareClassicKeyProfileFile())?.id, 'picked-profile');
    expect(picker.pickCalls, 1);
  });
}

final class _PickedProfile extends PlatformFile {
  _PickedProfile(this.file);
  final File file;
  @override
  String get name => file.uri.pathSegments.last;
  @override
  Uri get uri => file.uri;
  @override
  int lengthSync() => file.lengthSync();
  @override
  Future<int> length() => file.length();
  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
  @override
  Stream<Uint8List> readAsByteStream() =>
      file.openRead().map(Uint8List.fromList);
  @override
  Never get xFile => throw UnsupportedError('Fixture uses its byte stream');
}
