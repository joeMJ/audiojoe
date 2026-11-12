// The full-screen red warning before "Bit-perfect over USB" (0.3.2, user 2026-11-12 „246 ja“, „251 ja“):
// texts for Android and the desktop, "Switch on" only after the tick, "Cancel" and Back give false.
import 'package:audiojoe/ui/bit_perfect_warning.dart';
import 'package:audiojoe/ui/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens the warning from a button; the result lands in [result].
Future<List<bool?>> open(WidgetTester tester, {required bool desktop, Size size = const Size(400, 860)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final result = <bool?>[];
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.dark),
    home: Scaffold(
      body: Builder(
        builder: (c) => TextButton(
          onPressed: () async => result.add(await confirmBitPerfect(c, desktop: desktop)),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

bool enabled(WidgetTester tester) =>
    tester.widget<OutlinedButton>(find.byKey(const ValueKey('bit-perfect-on'))).onPressed != null;

void main() {
  testWidgets('Android: red page over the whole display with the approved texts', (tester) async {
    await open(tester, desktop: false);
    final page = tester.widget<Dialog>(find.byKey(const ValueKey('bit-perfect-confirm')));
    expect(page.backgroundColor, warningRed);
    expect(tester.getSize(find.byKey(const ValueKey('bit-perfect-confirm'))), const Size(400, 860));
    expect(find.text('Danger to hearing and headphones'), findsOneWidget);
    expect(find.text('With bit-perfect, music goes to the USB DAC without the volume control of the phone.'), findsOneWidget);
    expect(find.textContaining('The volume buttons of the phone and the lowering to 20 % then have no effect.'), findsOneWidget);
    expect(find.text('The change takes effect from the next music title. The current title can be quiet, and the next one starts at full volume.'),
        findsOneWidget);
    expect(find.text('Full volume can destroy in-ear headphones and permanently damage hearing.'), findsOneWidget);
    expect(find.textContaining('Check the volume at the next title'), findsOneWidget);
    expect(find.textContaining('system sounds such as touch tones are muted'), findsOneWidget);
    expect(find.textContaining('system can operate'), findsNothing);
    expect(find.text('I have read the warning'), findsOneWidget);
  });

  testWidgets('Switch on only after the tick, then true', (tester) async {
    final result = await open(tester, desktop: false);
    // On a phone the tick and the buttons are below the texts: scroll there first (as a user has to).
    await tester.ensureVisible(find.byKey(const ValueKey('bit-perfect-on')));
    await tester.pumpAndSettle();
    expect(enabled(tester), isFalse);
    await tester.tap(find.byKey(const ValueKey('bit-perfect-on')));
    await tester.pumpAndSettle();
    expect(result, isEmpty, reason: 'disabled button must not close the page');
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    await tester.tap(find.byKey(const ValueKey('bit-perfect-read')));
    await tester.pump();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    expect(enabled(tester), isTrue);
    await tester.tap(find.byKey(const ValueKey('bit-perfect-read')));
    await tester.pump();
    expect(enabled(tester), isFalse, reason: 'removing the tick locks the button again');
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(enabled(tester), isTrue);
    await tester.tap(find.byKey(const ValueKey('bit-perfect-on')));
    await tester.pumpAndSettle();
    expect(result, [true]);
    expect(find.byKey(const ValueKey('bit-perfect-confirm')), findsNothing);
  });

  testWidgets('Cancel gives false, also after the tick', (tester) async {
    final result = await open(tester, desktop: false);
    await tester.ensureVisible(find.byKey(const ValueKey('bit-perfect-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bit-perfect-read')));
    await tester.pump();
    expect(enabled(tester), isTrue, reason: 'the tick is set before Cancel');
    await tester.tap(find.byKey(const ValueKey('bit-perfect-cancel')));
    await tester.pumpAndSettle();
    expect(result, [false]);
  });

  testWidgets('Back gives false', (tester) async {
    final result = await open(tester, desktop: true);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(result, [false]);
  });

  testWidgets('desktop: texts for Ubuntu and Windows', (tester) async {
    await open(tester, desktop: true, size: const Size(1100, 800));
    expect(find.text('Danger to hearing and headphones'), findsOneWidget);
    expect(find.text('With bit-perfect, music bypasses the volume control of the system and goes directly to the USB DAC.'),
        findsOneWidget);
    expect(find.textContaining('The volume control of the system then has no effect.'), findsOneWidget);
    expect(find.text('Full volume can start immediately or with the next music title.'), findsOneWidget);
    expect(find.text('Full volume can destroy in-ear headphones and permanently damage hearing.'), findsOneWidget);
    expect(find.text('While audiojoe plays this way, other programs cannot use the DAC.'), findsOneWidget);
    expect(find.text('Take the headphones out of your ears before switching on. Check the volume with the headphones in your hand.'),
        findsOneWidget);
    expect(find.textContaining('lowering to 20 %'), findsNothing);
    expect(find.textContaining('system sounds such as touch tones'), findsNothing);
    expect(find.textContaining('of the phone'), findsNothing);
    expect(enabled(tester), isFalse);
  });
}
