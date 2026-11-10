// Settings → Quality on the desktop (0.3.0): "Now playing" with source and libmpv output, no Android part.
import 'package:audiojoe/quality.dart';
import 'package:audiojoe/ui/common.dart';
import 'package:audiojoe/ui/quality_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> show(WidgetTester tester, Widget child, {Size size = const Size(800, 600)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark), home: Scaffold(body: child)));
  await tester.pump();
}

void main() {
  testWidgets('desktop: Now playing with Source and Output, no switch', (tester) async {
    await show(tester, const SingleChildScrollView(child: QualitySettings()), size: const Size(800, 600));
    await tester.pump();
    expect(find.text('Now playing'), findsOneWidget);
    expect(find.text('Source'), findsOneWidget);
    expect(find.text('Output'), findsOneWidget);
    expect(find.text('Bit-perfect over USB'), findsNothing);
    expect(find.text('Handed to Android'), findsNothing);
  });

  test('texts of the diagnostics', () {
    expect(formatText({'encoding': 'float', 'rate': 96000, 'channels': 2}), '32-bit float · 96 kHz · 2 ch');
    expect(formatText({'encoding': '24', 'rate': 44100, 'channels': 2}), '24 bit · 44.1 kHz · 2 ch');
    expect(formatText(null), '–');
    final offered = [
      {'encoding': '24', 'rate': 44100, 'channels': 2, 'bitPerfect': false},
      {'encoding': '32', 'rate': 192000, 'channels': 2, 'bitPerfect': true},
    ];
    expect(offeredText(offered), '24 bit, 32 bit · 44.1–192 kHz');
    expect(offersBitPerfect(offered), isTrue);
    expect(offersBitPerfect(offered.take(1).toList()), isFalse);
  });
}
