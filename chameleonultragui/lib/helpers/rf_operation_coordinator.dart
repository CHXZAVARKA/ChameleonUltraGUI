import 'dart:async';
import 'dart:collection';

class RfBackgroundResult<T> {
  const RfBackgroundResult._({required this.acquired, this.value});

  const RfBackgroundResult.skipped() : this._(acquired: false);

  const RfBackgroundResult.completed(T value)
      : this._(acquired: true, value: value);

  final bool acquired;
  final T? value;
}

class RfOperationCoordinator {
  final Queue<Future<void> Function()> _foregroundQueue = Queue();
  bool _active = false;
  Object? _activeBackgroundGroup;
  int _activeBackgroundOperations = 0;
  Completer<void>? _idleWaiter;

  Future<T> runForeground<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _foregroundQueue.add(() async {
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      } finally {
        _release();
      }
    });
    _startNextForeground();
    return result.future;
  }

  Future<RfBackgroundResult<T>> tryRunBackground<T>(
    Future<T> Function() operation, {
    Object? group,
  }) async {
    if (_foregroundQueue.isNotEmpty ||
        (_active &&
            (group == null || !identical(_activeBackgroundGroup, group)))) {
      return const RfBackgroundResult.skipped();
    }

    if (!_active) {
      _active = true;
      _activeBackgroundGroup = group;
    }
    _activeBackgroundOperations++;
    try {
      return RfBackgroundResult.completed(await operation());
    } finally {
      _releaseBackground();
    }
  }

  Future<void> waitUntilIdle() {
    if (!_active && _foregroundQueue.isEmpty) {
      return Future.value();
    }
    return (_idleWaiter ??= Completer<void>()).future;
  }

  void _startNextForeground() {
    if (_active || _foregroundQueue.isEmpty) {
      return;
    }

    _active = true;
    unawaited(_foregroundQueue.removeFirst()());
  }

  void _release() {
    _active = false;
    _startNextForeground();
    if (!_active && _foregroundQueue.isEmpty) {
      final waiter = _idleWaiter;
      _idleWaiter = null;
      waiter?.complete();
    }
  }

  void _releaseBackground() {
    _activeBackgroundOperations--;
    if (_activeBackgroundOperations > 0) {
      return;
    }
    _activeBackgroundGroup = null;
    _release();
  }
}
