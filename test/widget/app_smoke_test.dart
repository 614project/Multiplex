import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multiplex/src/app.dart';
import 'package:multiplex/src/state/project_session.dart';
import 'package:multiplex/src/ui/desktop/desktop_shell.dart';
import 'package:multiplex/src/ui/mobile/generation_dock.dart';
import 'package:multiplex/src/ui/mobile/mobile_shell.dart';

import '../support/fake_sd_server.dart';
import '../support/test_app.dart';

void main() {
  late TestApp testApp;

  Future<void> pumpApp(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Everything that touches files or the fake server runs in real async, outside the fake clock.
    await tester.runAsync(() async {
      testApp = await createTestApp(FakeSdServer());
      final project = testApp.app.selected!;
      project.cells.first.prompt = 'a red fox';
      await project.saveNow();
      await waitFor(() => project.serverStatus == ServerStatus.online);
    });
    addTearDown(() => tester.runAsync(testApp.dispose));
    await tester.pumpWidget(MultiplexApp(appState: testApp.app));
    await tester.pumpAndSettle();
  }

  testWidgets('phone layout shows the gallery, dock and navigation', (tester) async {
    await pumpApp(tester, const Size(400, 860));

    expect(find.byType(MobileShell), findsOneWidget);
    expect(find.byType(GenerationDock), findsOneWidget);
    expect(find.text('Generate 4 cells'), findsOneWidget);
    expect(find.text('a red fox'), findsOneWidget);

    await tester.tap(find.text('Setup'));
    await tester.pumpAndSettle();
    expect(find.text('Prompts'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Sampling'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Sampling'), findsOneWidget);

    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();
    expect(find.text('No queued jobs'), findsOneWidget);

    await tester.tap(find.text('Cells'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Cell 2'));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.text('Generate 1 selected'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone cell editor opens from a cell without images', (tester) async {
    await pumpApp(tester, const Size(400, 860));
    await tester.tap(find.text('a red fox'));
    await tester.pumpAndSettle();
    expect(find.text('Generate this cell'), findsOneWidget);
    expect(find.text('Prompt preview'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop layout shows the project pane and tabs', (tester) async {
    await pumpApp(tester, const Size(1440, 900));

    expect(find.byType(DesktopShell), findsOneWidget);
    expect(find.text('New project'), findsOneWidget);
    expect(find.text('Cells (4)'), findsOneWidget);
    expect(find.text('Generate 4 cells'), findsOneWidget);

    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    expect(find.text('Hires.fix'), findsOneWidget);
    expect(find.text('Project overrides'), findsOneWidget);

    await tester.tap(find.textContaining('Queue'));
    await tester.pumpAndSettle();
    expect(find.text('No queued jobs'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('app settings page renders', (tester) async {
    await pumpApp(tester, const Size(1200, 900));
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Generation defaults'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
