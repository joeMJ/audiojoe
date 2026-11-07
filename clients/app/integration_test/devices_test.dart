// 0.2.2: own device once in "Output", red "Here"/"There", renaming in the settings (Linux, Xvfb):
//
//   flutter test integration_test/devices_test.dart -d linux --dart-define=SERVER=… --dart-define=USER=… \
//     --dart-define=PASS=… --dart-define=TOTP_SECRET=… [--dart-define=SHOTS=DIR]
//
// Signs in as "e2e-desk" through the UI and as "e2e-fold" over the API (an open event stream and
// a position, so it is online with a title). Sonos only as shown state, nothing goes to a speaker.

import 'dart:convert';

import 'package:audiojoe/api.dart';
import 'package:audiojoe/main.dart' as app;
import 'package:audiojoe/models.dart';
import 'package:audiojoe/player.dart';
import 'package:audiojoe/remote.dart';
import 'package:audiojoe/sonos.dart';
import 'package:audiojoe/ui/output.dart' show outputOpen;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';

import 'app_test.dart' show shot, totp, waitFor, waitUntil;

const server = String.fromEnvironment('SERVER');
const user = String.fromEnvironment('USER');
const pass = String.fromEnvironment('PASS');
const secret = String.fromEnvironment('TOTP_SECRET');

/// Sets the rename field (enterText loses the field after the light/dark switch of `shot`).
void typeName(WidgetTester tester, String text) =>
    tester.widget<TextField>(find.byKey(const ValueKey('rename-field'))).controller!.text = text;

Future<void> nextStep() => Future.delayed(Duration(seconds: 31 - DateTime.now().second % 30));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('own device once, red Here/There, rename', (tester) async {
    await app.main();
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await nextStep();
    await tester.enterText(fields.at(0), server);
    await tester.enterText(fields.at(1), user);
    await tester.enterText(fields.at(2), pass);
    await tester.enterText(fields.at(3), totp(secret, DateTime.now()));
    await tester.enterText(fields.at(4), 'e2e-desk');
    await tester.tap(find.byType(FilledButton));
    await waitFor(tester, find.byTooltip('Server reachable'));
    expect(api.device, 'e2e-desk');

    // The second device: signed in, event stream open, a position reported.
    await nextStep();
    final login = await http.post(Uri.parse('$server/api/v1/auth/login'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'username': user, 'password': pass, 'totp': totp(secret, DateTime.now()), 'device': 'e2e-fold'}));
    expect(login.statusCode, 200, reason: login.body);
    final b = {'authorization': 'Bearer ${jsonDecode(login.body)['token']}', 'content-type': 'application/json'};
    final stream = http.Client();
    final events = await stream.send(http.Request('GET', Uri.parse('$server/api/v1/events'))..headers.addAll(b));
    final sub = events.stream.listen((_) {});
    final now = DateTime.now().toUtc().toIso8601String();
    final put = await http.put(Uri.parse('$server/api/v1/playback/e2e:devices'), headers: b,
        body: jsonEncode({'position_ms': 60000, 'duration_ms': 600000, 'updated_at': now, 'title': 'Test title', 'subtitle': 'e2e',
          'state': 'paused', 'kind': 'android'}));
    expect(put.statusCode, 200, reason: put.body);

    final sessions = (await api.call('GET', '/sessions') as List).cast<Map>();
    final own = sessions.firstWhere((s) => s['current'] == true)['id'];
    final fold = sessions.firstWhere((s) => s['device'] == 'e2e-fold')['id'];
    try {
      // 1 – the own device's event (here: renamed) keeps it "this device": no second row.
      await remote.refresh();
      await api.call('PUT', '/sessions/$own/label', body: {'label': 'Office PC'});
      await waitUntil(tester, () => remote.device('e2e-desk')?.label == 'Office PC', seconds: 10,
          what: 'event with the new name');
      expect(remote.device('e2e-desk')!.current, isTrue, reason: 'the event marks the own device');
      expect(remote.devices.where((d) => d.current).length, 1);

      // 2 – Output: own device once, under its new name; Here/There red.
      final rooms = [Room(1, 'Wohnzimmer', 'One', true, true, 'STOPPED', 20)];
      sonos.all = rooms;
      player.queue = [const Item(key: 'e2e:devices', kind: 'episode', title: 'Test title', subtitle: 'e2e')];
      player.index = 0;
      outputOpen.value = true;
      await tester.pump(const Duration(seconds: 3));
      await waitFor(tester, find.text('e2e-fold'));
      expect(find.textContaining('Office PC'), findsOneWidget);
      expect(find.text('e2e-desk'), findsNothing);
      final red = Theme.of(tester.element(find.text('e2e-fold'))).brightness == Brightness.dark
          ? const Color(0xFFFF9A94)
          : const Color(0xFFA3231F);
      Color? fill(String label) {
        final w = tester.widget<FilledButton>(find.ancestor(of: find.text(label), matching: find.byType(FilledButton)).first);
        return w.style?.backgroundColor?.resolve({});
      }
      expect(fill('Here'), red);
      expect(fill('There'), red);
      expect(fill('Stop'), isNot(red));
      // Stays one row across the next refreshes (10 s) and events.
      await api.call('PUT', '/sessions/$own/label', body: {'label': 'Office PC'});
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(seconds: 1));
        expect(find.textContaining('Office PC'), findsOneWidget, reason: 'second ${i + 1}');
      }
      await shot(tester, 'output-022');
      expect(tester.takeException(), isNull, reason: 'after output shot');
      outputOpen.value = false;
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull, reason: 'after closing output');

      // 3 – Settings → Devices: rename the other device, a name taken, back to the device name.
      await tester.tap(find.text('Settings').first);
      await waitFor(tester, find.text('Add source'));
      await tester.tap(find.byKey(const ValueKey('settings-page-devices')));
      await waitFor(tester, find.byKey(ValueKey('rename-$fold')));
      await tester.tap(find.byKey(ValueKey('rename-$fold')));
      await waitFor(tester, find.byKey(const ValueKey('rename-field')));
      await tester.enterText(find.byKey(const ValueKey('rename-field')), 'OFFICE PC');
      await tester.tap(find.byKey(const ValueKey('rename-save')));
      await waitFor(tester, find.text('Name already taken'));
      expect(tester.takeException(), isNull, reason: 'after taken');
      await shot(tester, 'rename-taken-022');
      expect(tester.takeException(), isNull, reason: 'after taken shot');
      typeName(tester, 'Kitchen phone');
      await tester.tap(find.byKey(const ValueKey('rename-save')));
      await waitFor(tester, find.text('Kitchen phone'));
      expect(tester.takeException(), isNull, reason: 'after Kitchen phone');
      await waitUntil(tester, () => remote.device('e2e-fold')?.label == 'Kitchen phone', seconds: 10, what: 'other devices learn it');
      await shot(tester, 'settings-devices-022');
      expect(tester.takeException(), isNull, reason: 'after settings shot');
      // Frames after the light/dark switch of `shot` (one 1 s pump and a dialog right after it: null check in
      // flushSemantics, test only, 2026-11-07).
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(tester.takeException(), isNull, reason: 'R0 after shot, 3 s');
      await tester.tap(find.byKey(ValueKey('rename-$fold')));
      await waitFor(tester, find.byKey(const ValueKey('rename-field')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull, reason: 'R1 dialog open');
      await tester.enterText(find.byKey(const ValueKey('rename-field')), ''); // a new dialog: typing works
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull, reason: 'R2 typed empty');
      await tester.tap(find.byKey(const ValueKey('rename-save')));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'R3 tapped save');
      await waitFor(tester, find.text('e2e-fold'));
      expect(find.text('Kitchen phone'), findsNothing);
      expect(tester.takeException(), isNull, reason: 'after reset');
    } finally {
      outputOpen.value = false;
      sonos.all = [];
      await api.call('PUT', '/sessions/$own/label', body: {'label': ''}).catchError((_) => null);
      await api.call('PUT', '/sessions/$fold/label', body: {'label': ''}).catchError((_) => null);
      await sub.cancel();
      stream.close();
      await api.call('DELETE', '/sessions/$fold').catchError((_) => null);
      await api.call('POST', '/auth/logout');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
