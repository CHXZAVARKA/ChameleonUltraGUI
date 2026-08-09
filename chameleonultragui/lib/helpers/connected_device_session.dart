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

/// The observable outcome of a session-bound foreground RF operation.
///
/// [executed] distinguishes a rejected operation from a callback that
/// successfully returned `null`.
class SessionBoundRfResult<T> {
  const SessionBoundRfResult.rejected()
      : executed = false,
        session = null,
        value = null,
        error = null,
        stackTrace = null;

  const SessionBoundRfResult.completed({
    required ConnectedDeviceSession this.session,
    required this.value,
  })  : executed = true,
        error = null,
        stackTrace = null;

  const SessionBoundRfResult.failed({
    required ConnectedDeviceSession this.session,
    required Object this.error,
    required StackTrace this.stackTrace,
  })  : executed = true,
        value = null;

  final bool executed;
  final ConnectedDeviceSession? session;
  final T? value;
  final Object? error;
  final StackTrace? stackTrace;
}

extension SessionBoundRfOperations on ChameleonGUIState {
  /// Runs [operation] with exclusive foreground RF access for this connection.
  ///
  /// The session is captured before enqueueing and checked again when its FIFO
  /// lease is acquired. Multi-command callbacks should check [session.isCurrent]
  /// before issuing follow-up commands.
  Future<SessionBoundRfResult<T>> runSessionBoundForeground<T>(
    Future<T> Function(ConnectedDeviceSession session) operation,
  ) {
    final session = ConnectedDeviceSession.capture(this);
    if (session == null) {
      return Future.value(const SessionBoundRfResult.rejected());
    }

    return rfOperations.runForeground(() async {
      if (!session.isCurrent) {
        return const SessionBoundRfResult.rejected();
      }

      return SessionBoundRfResult.completed(
        session: session,
        value: await operation(session),
      );
    });
  }

  /// Like [runSessionBoundForeground], but reports callback failures as data.
  Future<SessionBoundRfResult<T>> runSessionBoundForegroundCatching<T>(
    Future<T> Function(ConnectedDeviceSession session) operation,
  ) async {
    final outerResult =
        await runSessionBoundForeground<SessionBoundRfResult<T>>(
      (session) async {
        try {
          return SessionBoundRfResult.completed(
            session: session,
            value: await operation(session),
          );
        } catch (error, stackTrace) {
          return SessionBoundRfResult.failed(
            session: session,
            error: error,
            stackTrace: stackTrace,
          );
        }
      },
    );

    if (!outerResult.executed) {
      return const SessionBoundRfResult.rejected();
    }
    return outerResult.value!;
  }
}
