// The title line: centred when it fits, flowing again and again when it does not.

import 'package:audiojoe/ui/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _box(double width, String text) => MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: width, child: Marquee(TextSpan(text: text), style: const TextStyle(fontSize: 20)))),
      ),
    );

final _shift = find.descendant(of: find.byType(Marquee), matching: find.byType(Transform));
double _offset(WidgetTester t) => t.widget<Transform>(_shift).transform.getTranslation().x;

void main() {
  testWidgets('a short title stays still', (t) async {
    await t.pumpWidget(_box(400, 'Short'));
    expect(find.text('Short'), findsOneWidget);
    expect(_shift, findsNothing);
  });

  testWidgets('a long title flows after 2 s and starts over', (t) async {
    await t.pumpWidget(_box(200, 'A very long title that does not fit (3 of 19)'));
    await t.pump();
    expect(find.text('A very long title that does not fit (3 of 19)'), findsNWidgets(2));
    expect(_offset(t), 0);
    await t.pump(const Duration(milliseconds: 1900));
    expect(_offset(t), 0);
    await t.pump(const Duration(seconds: 2));
    await t.pump(const Duration(milliseconds: 500));
    expect(_offset(t), lessThan(0));
    // At the end of a round it starts over (back at 0 for the next pause).
    var back = false;
    for (var i = 0; i < 80 && !back; i++) {
      await t.pump(const Duration(milliseconds: 500));
      back = _offset(t) == 0;
    }
    expect(back, isTrue);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 3)); // the pending pause ends without a widget
  });
}
