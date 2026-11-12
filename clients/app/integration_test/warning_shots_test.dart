// Screenshots of the full-screen red warning before "Bit-perfect over USB" (0.3.2) in the Linux app under
// Xvfb, for the user's check of look and texts (ImageMagick "import" of the X screen):
//
//   LANG=de_DE.UTF-8 xvfb-run -a -s "-screen 0 1280x800x24" \
//     flutter test integration_test/warning_shots_test.dart -d linux --dart-define=SHOTS=DIR
//
// Writes DIR/warnung-android-1.png, -2-haken.png and the same for desktop; without SHOTS it only checks that
// the page opens and the tick unlocks "Switch on".
import 'dart:io';

import 'package:audiojoe/ui/bit_perfect_warning.dart';
import 'package:audiojoe/ui/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const shots = String.fromEnvironment('SHOTS');

Future<void> shot(WidgetTester tester, String name) async {
  if (shots.isEmpty) return;
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  final r = await Process.run('import', ['-window', 'root', '$shots/$name.png']);
  expect(r.exitCode, 0, reason: '${r.stderr}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final desktop in [false, true]) {
    final name = desktop ? 'desktop' : 'android';
    testWidgets('warning $name', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (c) => Center(
              child: FilledButton(onPressed: () => confirmBitPerfect(c, desktop: desktop), child: const Text('open')),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bit-perfect-confirm')), findsOneWidget);
      await shot(tester, 'warnung-$name-1');
      await tester.tap(find.byKey(const ValueKey('bit-perfect-read')));
      await tester.pump();
      expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('bit-perfect-on'))).onPressed, isNotNull);
      await shot(tester, 'warnung-$name-2-haken');
    });
  }
}
