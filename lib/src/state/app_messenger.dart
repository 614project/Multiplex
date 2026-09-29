import 'dart:async';

enum MessageSeverity { info, success, warning, error }

class AppMessage {
  AppMessage(this.text, this.severity) : time = DateTime.now();

  final String text;
  final MessageSeverity severity;
  final DateTime time;
}

/// Collects user facing notifications (the WinUI InfoBar of WebuiMultiflex). The UI shows them as
/// snack bars; the recent history is kept for the activity sheet.
class AppMessenger {
  static const historyLimit = 100;

  final StreamController<AppMessage> _controller = StreamController<AppMessage>.broadcast();
  final List<AppMessage> _history = [];

  Stream<AppMessage> get stream => _controller.stream;
  List<AppMessage> get history => List.unmodifiable(_history.reversed);

  void show(String text, [MessageSeverity severity = MessageSeverity.info]) {
    final message = AppMessage(text, severity);
    _history.add(message);
    if (_history.length > historyLimit) {
      _history.removeAt(0);
    }

    _controller.add(message);
  }

  void info(String text) => show(text, MessageSeverity.info);
  void success(String text) => show(text, MessageSeverity.success);
  void warning(String text) => show(text, MessageSeverity.warning);
  void error(String text) => show(text, MessageSeverity.error);

  Future<void> dispose() => _controller.close();
}
