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
    Future<T> Function() operation,
  ) async {
    if (_active || _foregroundQueue.isNotEmpty) {
      return const RfBackgroundResult.skipped();
    }

    _active = true;
    try {
      return RfBackgroundResult.completed(await operation());
    } finally {
      _release();
    }
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
  }
}
