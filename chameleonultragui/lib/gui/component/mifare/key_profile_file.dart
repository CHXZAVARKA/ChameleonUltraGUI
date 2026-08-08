import 'dart:convert';
import 'dart:typed_data';

import 'package:chameleonultragui/helpers/mifare_classic/key_profile.dart';
import 'package:file_picker/file_picker.dart';

Future<MifareClassicKeyProfile?> pickMifareClassicKeyProfileFile() async {
  final result = await FilePicker.pickFiles();
  final picked =
      result == null || result.files.isEmpty ? null : result.files.first;
  if (picked == null) {
    return null;
  }
  final bytes = Uint8List.fromList(
    await picked.readAsByteStream().expand((chunk) => chunk).toList(),
  );
  return MifareClassicKeyProfile.fromJson(const Utf8Decoder().convert(bytes));
}
