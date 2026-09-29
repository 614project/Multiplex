import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/testing.dart';
import 'package:multiplex/src/services/app_paths.dart';
import 'package:multiplex/src/state/app_messenger.dart';
import 'package:multiplex/src/state/app_state.dart';

import 'fake_sd_server.dart';

class TestApp {
  TestApp(this.app, this.directory, this.messages);

  final AppState app;
  final Directory directory;
  final List<AppMessage> messages;

  List<String> get messageTexts => messages.map((message) => message.text).toList();

  Future<void> dispose() async {
    app.dispose();
    try {
      await directory.delete(recursive: true);
    } catch (_) {
      // Temporary folder cleanup is best effort.
    }
  }
}

/// Creates an initialized [AppState] in a temporary folder whose HTTP traffic goes to [server].
Future<TestApp> createTestApp(FakeSdServer server, {Map<String, Object?> preferences = const {}}) async {
  final directory = await Directory.systemTemp.createTemp('multiplex-test-');
  final paths = AppPaths(directory.path);
  await File(paths.preferencesFile).create(recursive: true);
  await File(
    paths.preferencesFile,
  ).writeAsString(jsonEncode({'promptAutocompleteEnabled': false, 'pollingRecoveryGraceSeconds': 0, ...preferences}));

  final app = AppState(paths: paths, httpClientFactory: () => MockClient(server.handle));
  final messages = <AppMessage>[];
  app.messenger.stream.listen(messages.add);
  await app.initialize();
  return TestApp(app, directory, messages);
}

/// Polls [condition] until it holds or [timeout] passes.
Future<void> waitFor(bool Function() condition, {Duration timeout = const Duration(seconds: 15)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not met within $timeout');
    }

    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
