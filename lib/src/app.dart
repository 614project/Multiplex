import 'dart:async';
import 'dart:ui';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'state/app_messenger.dart';
import 'state/app_state.dart';
import 'ui/desktop/desktop_shell.dart';
import 'ui/layout.dart';
import 'ui/mobile/mobile_shell.dart';
import 'ui/settings/app_settings_page.dart';
import 'ui/theme.dart';

class MultiplexApp extends StatefulWidget {
  const MultiplexApp({super.key, required this.appState, this.initialization});

  final AppState appState;

  /// Completes when [AppState.initialize] finished (or failed).
  final Future<void>? initialization;

  @override
  State<MultiplexApp> createState() => _MultiplexAppState();
}

class _MultiplexAppState extends State<MultiplexApp> {
  final GlobalKey<ScaffoldMessengerState> _messengerKey = GlobalKey<ScaffoldMessengerState>();
  late final StreamSubscription<AppMessage> _messages = widget.appState.messenger.stream.listen(_showMessage);
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onHide: _flush,
    onPause: _flush,
    onDetach: _flush,
    onExitRequested: () async {
      await widget.appState.flush();
      return AppExitResponse.exit;
    },
  );
  Object? _initializationError;

  @override
  void initState() {
    super.initState();
    _lifecycle;
    _messages;
    widget.initialization?.catchError((Object error) {
      if (mounted) {
        setState(() => _initializationError = error);
      }
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    unawaited(_messages.cancel());
    super.dispose();
  }

  void _flush() => unawaited(widget.appState.flush());

  void _showMessage(AppMessage message) {
    final messenger = _messengerKey.currentState;
    final context = _messengerKey.currentContext;
    if (messenger == null || context == null) {
      return;
    }

    final colors = Theme.of(context).colorScheme;
    final (icon, color, duration) = switch (message.severity) {
      MessageSeverity.error => (Icons.error_outline, colors.error, const Duration(seconds: 8)),
      MessageSeverity.warning => (Icons.warning_amber_rounded, Colors.amber.shade400, const Duration(seconds: 6)),
      MessageSeverity.success => (Icons.check_circle_outline, Colors.green.shade400, const Duration(seconds: 3)),
      MessageSeverity.info => (Icons.info_outline, colors.inversePrimary, const Duration(seconds: 4)),
    };
    final wide = !WindowClass.of(context).usesMobileLayout;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          width: wide ? 560 : null,
          duration: duration,
          showCloseIcon: true,
          content: Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 12),
              Expanded(child: Text(message.text)),
            ],
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppState>.value(
      value: widget.appState,
      child: Builder(
        builder: (context) {
          final (themeMode, seed, useDynamic) = context.select<AppState, (ThemeMode, int, bool)>(
            (app) => (app.preferences.themeMode, app.preferences.seedColor, app.preferences.useDynamicColor),
          );
          return DynamicColorBuilder(
            builder: (lightDynamic, darkDynamic) {
              final dynamicAvailable = lightDynamic != null && darkDynamic != null;
              var light = ColorScheme.fromSeed(seedColor: Color(seed), brightness: Brightness.light);
              var dark = ColorScheme.fromSeed(seedColor: Color(seed), brightness: Brightness.dark);
              if (useDynamic && lightDynamic != null && darkDynamic != null) {
                light = lightDynamic.harmonized();
                dark = darkDynamic.harmonized();
              }

              return Provider<DynamicColorSupport>.value(
                value: DynamicColorSupport(available: dynamicAvailable),
                child: MaterialApp(
                  title: 'Multiplex',
                  debugShowCheckedModeBanner: false,
                  scaffoldMessengerKey: _messengerKey,
                  themeMode: themeMode,
                  theme: buildTheme(light),
                  darkTheme: buildTheme(dark),
                  scrollBehavior: const _AppScrollBehavior(),
                  home: _Home(error: _initializationError),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _Home extends StatelessWidget {
  const _Home({required this.error});

  final Object? error;

  @override
  Widget build(BuildContext context) {
    final initialized = context.select<AppState, bool>((app) => app.isInitialized);
    if (error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 48, color: context.colors.error),
                const SizedBox(height: 16),
                Text('Multiplex could not start', style: context.text.titleLarge),
                const SizedBox(height: 8),
                Text('$error', textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      );
    }

    if (!initialized) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_awesome_mosaic_outlined, size: 56, color: context.colors.primary),
              const SizedBox(height: 16),
              Text('Multiplex', style: context.text.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 24),
              const SizedBox(width: 160, child: LinearProgressIndicator()),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) =>
          WindowClass.fromWidth(constraints.maxWidth).usesMobileLayout ? const MobileShell() : const DesktopShell(),
    );
  }
}

/// Lets mouse and trackpad users drag scrollables (galleries, chip rows) like on touch screens.
class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}
