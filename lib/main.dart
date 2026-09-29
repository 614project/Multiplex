import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'src/app.dart';
import 'src/services/app_log.dart';
import 'src/services/app_paths.dart';
import 'src/state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    AppLog.write('Unhandled Flutter error', details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    AppLog.write('Unhandled error', error, stackTrace);
    return true;
  };

  // MULTIPLEX_DATA_DIR points the app at another data folder (portable installs, demos, tests).
  final override = Platform.environment['MULTIPLEX_DATA_DIR'];
  final root = override != null && override.trim().isNotEmpty
      ? override.trim()
      : (await getApplicationSupportDirectory()).path;

  final appState = AppState(paths: AppPaths(root));
  runApp(MultiplexApp(appState: appState, initialization: appState.initialize()));
}
