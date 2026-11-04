import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

class TestFilePicker extends FilePickerPlatform {
  Uri? savedUri;
  Object? pickError;
  void Function(String name, Uint8List bytes)? onSave;
  String? savedName;
  Uint8List? savedBytes;
  PlatformFile? picked;
  int saveCalls = 0;
  int pickCalls = 0;

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    saveCalls++;
    onSave?.call(fileName, bytes);
    savedName = fileName;
    savedBytes = bytes;
    return savedUri;
  }

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    pickCalls++;
    if (pickError != null) throw pickError!;
    return picked;
  }
}
