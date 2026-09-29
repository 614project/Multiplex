import 'dart:async';

/// Thrown when an operation observes a cancelled [CancellationToken].
class OperationCanceledException implements Exception {
  const OperationCanceledException([this.message = 'The operation was cancelled.']);

  final String message;

  @override
  String toString() => message;
}

/// A cooperative cancellation signal, modelled after .NET's `CancellationToken`.
class CancellationToken {
  CancellationToken._(this._source);

  final CancellationSource? _source;

  /// A token that is never cancelled.
  static final CancellationToken none = CancellationToken._(null);

  bool get isCancelled => _source?.isCancelled ?? false;

  /// Completes when the token is cancelled; never completes for [none].
  Future<void> get whenCancelled => _source?._completer.future ?? Completer<void>().future;

  void throwIfCancelled() {
    if (isCancelled) {
      throw const OperationCanceledException();
    }
  }

  /// Waits for [duration], throwing [OperationCanceledException] as soon as the token is cancelled.
  Future<void> delay(Duration duration) async {
    throwIfCancelled();
    await sleep(duration);
    throwIfCancelled();
  }

  /// Waits for [duration] or until the token is cancelled, whichever comes first. Never throws, so
  /// it is safe to race against other futures with `Future.any`.
  Future<void> sleep(Duration duration) async {
    if (isCancelled) {
      return;
    }

    if (_source == null) {
      await Future<void>.delayed(duration);
      return;
    }

    final timer = Completer<void>();
    final handle = Timer(duration, timer.complete);
    try {
      await Future.any([timer.future, whenCancelled]);
    } finally {
      handle.cancel();
    }
  }

  /// Runs [future] but throws [OperationCanceledException] once the token is cancelled, even if the
  /// underlying work keeps going (its eventual error is observed so it is never reported unhandled).
  Future<T> guard<T>(Future<T> future) async {
    throwIfCancelled();
    if (_source == null) {
      return future;
    }

    future.ignore();
    final cancelled = whenCancelled.then<T>((_) => throw const OperationCanceledException());
    cancelled.ignore();
    return Future.any([future, cancelled]);
  }
}

/// Owns a [CancellationToken] and cancels it on request, after a timeout, or when a parent token
/// is cancelled.
class CancellationSource {
  CancellationSource({CancellationToken? parent, Duration? timeout}) {
    token = CancellationToken._(this);
    if (parent != null) {
      if (parent.isCancelled) {
        cancel();
      } else {
        unawaited(parent.whenCancelled.then((_) => cancel()));
      }
    }

    if (timeout != null) {
      cancelAfter(timeout);
    }
  }

  late final CancellationToken token;
  final Completer<void> _completer = Completer<void>();
  Timer? _timer;

  bool get isCancelled => _completer.isCompleted;

  void cancel() {
    _timer?.cancel();
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }

  void cancelAfter(Duration duration) {
    _timer?.cancel();
    if (isCancelled) {
      return;
    }

    _timer = Timer(duration, cancel);
  }

  /// Stops a pending timeout without cancelling.
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
