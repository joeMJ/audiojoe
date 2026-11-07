// Error log and error box (0.2.3, user 2026-11-07, way C).

import 'package:audiojoe/errors.dart';
import 'package:audiojoe/ui/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => errorLog.entries = []);

  test('newest first, at most 50, the same message again counts up', () {
    errorLog.record('A', null);
    errorLog.record('A', StackTrace.current);
    expect(errorLog.entries.length, 1);
    expect(errorLog.entries.first.count, 2);
    for (var i = 0; i < 60; i++) {
      errorLog.record('E$i', null);
    }
    expect(errorLog.entries.length, ErrorLog.max);
    expect(errorLog.entries.first.message, 'E59');
    expect(errorLog.entries.last.message, 'E10');
  });

  test('text: version, then each entry with its count and stack', () {
    errorLog.record('Null check operator used on a null value', StackTrace.current);
    errorLog.record('Null check operator used on a null value', StackTrace.current);
    final s = errorLog.text('0.2.3');
    expect(s, startsWith('audiojoe 0.2.3 · '));
    expect(s, contains('(2×)\nNull check operator used on a null value\n'));
    expect(s.split('\n').length, lessThan(2 + 3 + ErrorLog.stackLines + 2));
  });

  testWidgets('error box: the sentence and the message, no grey area', (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(body: ListView(children: const [ErrorBox('RangeError (index): Invalid value')]))));
    expect(find.text('Error showing this page:'), findsOneWidget);
    expect(find.text('RangeError (index): Invalid value'), findsOneWidget);
    expect(tester.getSize(find.byType(ErrorBox)).height, lessThan(200));
  });
}
