import 'package:chameleonultragui/bridge/chameleon.dart';

abstract interface class SlotCommandRunner {
  Future<T> run<T>(
    Future<T> Function(ChameleonCommunicator communicator) operation,
  );
}

abstract interface class SlotCommandRunnerChanged implements Exception {}
