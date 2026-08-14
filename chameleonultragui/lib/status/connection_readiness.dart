import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:flutter/foundation.dart';

enum ConnectionReadinessStage {
  disconnected,
  discovering,
  connectingTransport,
  waitingForProtocol,
  loadingStatus,
  ready,
  degraded,
  failed,
}

enum ConnectionReadinessErrorCategory {
  timeout,
  transport,
  protocol,
  status,
  disconnected,
  unknown,
}

@immutable
class ConnectionReadinessRecord {
  const ConnectionReadinessRecord({
    required this.stage,
    required this.elapsed,
    this.errorCategory,
  });

  final ConnectionReadinessStage stage;
  final Duration elapsed;
  final ConnectionReadinessErrorCategory? errorCategory;
}

@immutable
class ConnectionReadinessSnapshot {
  const ConnectionReadinessSnapshot({
    required this.stage,
    required this.transport,
    required this.stageStartedAt,
    required this.history,
    this.errorCategory,
    this.terminalElapsed,
  });

  factory ConnectionReadinessSnapshot.disconnected(DateTime now) =>
      ConnectionReadinessSnapshot(
        stage: ConnectionReadinessStage.disconnected,
        transport: ConnectionType.none,
        stageStartedAt: now,
        history: const [],
      );

  final ConnectionReadinessStage stage;
  final ConnectionType transport;
  final DateTime stageStartedAt;
  final List<ConnectionReadinessRecord> history;
  final ConnectionReadinessErrorCategory? errorCategory;
  final Duration? terminalElapsed;

  Duration elapsedAt(DateTime now) =>
      terminalElapsed ?? now.difference(stageStartedAt);

  bool get isTerminal =>
      stage == ConnectionReadinessStage.disconnected ||
      stage == ConnectionReadinessStage.ready ||
      stage == ConnectionReadinessStage.degraded ||
      stage == ConnectionReadinessStage.failed;
}

@immutable
class ConnectionReadinessTimeouts {
  const ConnectionReadinessTimeouts({
    this.discovery = const Duration(seconds: 4),
    this.transport = const Duration(seconds: 40),
    this.protocol = const Duration(seconds: 8),
    this.statusFacet = const Duration(seconds: 30),
  });

  final Duration discovery;
  final Duration transport;
  final Duration protocol;
  final Duration statusFacet;
}

class ConnectionReadinessAttempt {
  const ConnectionReadinessAttempt._(this._generation);

  final int _generation;
}

class ConnectionReadinessTracker extends ChangeNotifier {
  ConnectionReadinessTracker({
    this.timeouts = const ConnectionReadinessTimeouts(),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _snapshot = ConnectionReadinessSnapshot.disconnected(_now());
  }

  final ConnectionReadinessTimeouts timeouts;
  final DateTime Function() _now;

  late ConnectionReadinessSnapshot _snapshot;
  ConnectionReadinessSnapshot get snapshot => _snapshot;

  int _generation = 0;

  ConnectionReadinessAttempt beginDiscovery() => _begin(
        ConnectionReadinessStage.discovering,
        ConnectionType.none,
      );

  ConnectionReadinessAttempt beginTransport(ConnectionType transport) {
    if (_snapshot.stage == ConnectionReadinessStage.discovering) {
      final now = _now();
      final attempt = ConnectionReadinessAttempt._(_generation);
      _publish(
        ConnectionReadinessSnapshot(
          stage: ConnectionReadinessStage.connectingTransport,
          transport: transport,
          stageStartedAt: now,
          history: _completedHistory(now),
        ),
      );
      return attempt;
    }
    return _begin(ConnectionReadinessStage.connectingTransport, transport);
  }

  ConnectionReadinessAttempt attachSession(ConnectionType transport) {
    final canReuse = _snapshot.transport == transport &&
        (_snapshot.stage == ConnectionReadinessStage.connectingTransport ||
            _snapshot.stage == ConnectionReadinessStage.waitingForProtocol);
    final attempt = canReuse
        ? ConnectionReadinessAttempt._(_generation)
        : _begin(ConnectionReadinessStage.waitingForProtocol, transport);
    if (canReuse) {
      transition(attempt, ConnectionReadinessStage.waitingForProtocol);
    }
    return attempt;
  }

  bool isCurrent(ConnectionReadinessAttempt attempt) =>
      attempt._generation == _generation;

  void transition(
    ConnectionReadinessAttempt attempt,
    ConnectionReadinessStage stage, {
    ConnectionReadinessErrorCategory? errorCategory,
  }) {
    if (!isCurrent(attempt) || _snapshot.stage == stage) {
      return;
    }
    final now = _now();
    final elapsed = now.difference(_snapshot.stageStartedAt);
    final history = _completedHistory(now, errorCategory: errorCategory);
    _publish(
      ConnectionReadinessSnapshot(
        stage: stage,
        transport: _snapshot.transport,
        stageStartedAt: now,
        history: history,
        errorCategory: errorCategory,
        terminalElapsed: stage == ConnectionReadinessStage.ready ||
                stage == ConnectionReadinessStage.degraded
            ? elapsed
            : null,
      ),
    );
  }

  void fail(
    ConnectionReadinessAttempt attempt,
    ConnectionReadinessErrorCategory category,
  ) {
    if (!isCurrent(attempt)) {
      return;
    }
    final now = _now();
    final elapsed = now.difference(_snapshot.stageStartedAt);
    final history = _completedHistory(now, errorCategory: category);
    _publish(
      ConnectionReadinessSnapshot(
        stage: ConnectionReadinessStage.failed,
        transport: _snapshot.transport,
        stageStartedAt: now,
        history: history,
        errorCategory: category,
        terminalElapsed: elapsed,
      ),
    );
  }

  void markDisconnected() {
    final now = _now();
    _generation++;
    final history = _snapshot.stage == ConnectionReadinessStage.disconnected
        ? _snapshot.history
        : _completedHistory(
            now,
            errorCategory: ConnectionReadinessErrorCategory.disconnected,
          );
    _publish(
      ConnectionReadinessSnapshot(
        stage: ConnectionReadinessStage.disconnected,
        transport: ConnectionType.none,
        stageStartedAt: now,
        history: history,
        errorCategory: _snapshot.stage == ConnectionReadinessStage.disconnected
            ? null
            : ConnectionReadinessErrorCategory.disconnected,
      ),
    );
  }

  ConnectionReadinessAttempt _begin(
    ConnectionReadinessStage stage,
    ConnectionType transport,
  ) {
    _generation++;
    final now = _now();
    _publish(
      ConnectionReadinessSnapshot(
        stage: stage,
        transport: transport,
        stageStartedAt: now,
        history: const [],
      ),
    );
    return ConnectionReadinessAttempt._(_generation);
  }

  List<ConnectionReadinessRecord> _completedHistory(
    DateTime now, {
    ConnectionReadinessErrorCategory? errorCategory,
  }) =>
      List.unmodifiable([
        ..._snapshot.history,
        ConnectionReadinessRecord(
          stage: _snapshot.stage,
          elapsed: now.difference(_snapshot.stageStartedAt),
          errorCategory: errorCategory,
        ),
      ]);

  void _publish(ConnectionReadinessSnapshot next) {
    _snapshot = next;
    notifyListeners();
  }
}
