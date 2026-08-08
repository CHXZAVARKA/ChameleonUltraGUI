import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/main.dart';

class ConnectedDeviceSession {
  final ChameleonGUIState appState;
  final AbstractSerial connector;
  final ChameleonCommunicator communicator;

  const ConnectedDeviceSession._({
    required this.appState,
    required this.connector,
    required this.communicator,
  });

  static ConnectedDeviceSession? capture(ChameleonGUIState appState) {
    final connector = appState.connector;
    final communicator = appState.communicator;
    if (connector == null ||
        communicator == null ||
        !connector.connected ||
        connector.isDFU) {
      return null;
    }
    return ConnectedDeviceSession._(
      appState: appState,
      connector: connector,
      communicator: communicator,
    );
  }

  bool get isCurrent =>
      identical(appState.connector, connector) &&
      appState.hasConnectedCommunicator(communicator);
}
