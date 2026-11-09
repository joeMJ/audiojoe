// A Sonos session another device started (user 2026-11-09: the notebook sent an album to the
// bedroom, the open app on Office PC showed neither it nor a way to fetch it until a restart). Run by
// hand against a real speaker, quietly (tools/dev/sonos-follow-test-linux.sh):
//
//   flutter test integration_test/sonos_follow_test.dart -d linux --dart-define=SERVER=… --dart-define=USER=…
//     --dart-define=PASS=… --dart-define=TOTP_SECRET=… --dart-define=ROOM=<id> --dart-define=KEY=jellyfin:…
//
// A second session "Notebook (Test)" starts KEY on room ROOM (volume 5, restored afterwards) while
// this app plays nothing:
// B  the app shows the speaker and controls it by itself (event "device");
// A  after "release", the output overlay shows the room with "started by Notebook (Test)", and
//    "Control" and "Here" work ("Here" ends the session and plays here);
// B2 the event stream is cut ("CUT", tools/dev/cut-events.sh) and the session starts during the cut:
//    after reconnecting the app shows and controls the speaker.

import 'dart:convert';

import 'package:audiojoe/api.dart';
import 'package:audiojoe/main.dart' as app;
import 'package:audiojoe/player.dart';
import 'package:audiojoe/remote.dart';
import 'package:audiojoe/sonos.dart';
import 'package:audiojoe/ui/output.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';

import 'app_test.dart' show totp, waitFor, waitUntil;

const server = String.fromEnvironment('SERVER');
const user = String.fromEnvironment('USER');
const pass = String.fromEnvironment('PASS');
const secret = String.fromEnvironment('TOTP_SECRET');
const roomId = int.fromEnvironment('ROOM');
const key = String.fromEnvironment('KEY');

// ignore: avoid_print
void log(String s) => print('${DateTime.now().toIso8601String().substring(11, 19)} $s');

/// The second device ("Notebook (Test)"), plain HTTP.
class Other {
  String token = '';
  Future<dynamic> call(String method, String path, [Map<String, dynamic>? body]) async {
    final req = http.Request(method, Uri.parse('$server/api/v1$path'))
      ..headers['content-type'] = 'application/json'
      ..headers['authorization'] = 'Bearer $token';
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(await req.send());
    if (res.statusCode >= 300) throw Exception('$method $path: ${res.statusCode} ${res.body}');
    return res.body.isEmpty ? null : jsonDecode(res.body);
  }

  Future<void> login() async {
    // Each code counts once: the next 30-second window.
    await Future.delayed(Duration(seconds: 31 - DateTime.now().second % 30));
    final r = await call('POST', '/auth/login',
        {'username': user, 'password': pass, 'totp': totp(secret, DateTime.now()), 'device': 'Notebook (Test)'});
    token = r['token'] as String;
  }

  Future<void> play() => call('POST', '/sonos/$roomId/play', {'key': key, 'position_ms': 30000});
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sonos: a session of another device shows and can be fetched', (tester) async {
    await app.main();
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await Future.delayed(Duration(seconds: 31 - DateTime.now().second % 30));
    await tester.enterText(fields.at(0), server);
    await tester.enterText(fields.at(1), user);
    await tester.enterText(fields.at(2), pass);
    await tester.enterText(fields.at(3), totp(secret, DateTime.now()));
    await tester.enterText(fields.at(4), 'Linux (Test)');
    await tester.tap(find.byType(FilledButton));
    await waitFor(tester, find.byTooltip('Server reachable'));
    final other = Other();
    await other.login();
    log('second session ready');

    final room = (await sonos.rooms()).firstWhere((r) => r.id == roomId);
    final volume = room.volume ?? 15;
    Finder inRoomCard(String label) => find.descendant(
        of: find.ancestor(of: find.byKey(ValueKey('room-line-$roomId')), matching: find.byType(Card)),
        matching: find.widgetWithText(FilledButton, label));
    Future<void> idle() async {
      remote.release();
      await player.pauseHere();
      await tester.pump(const Duration(seconds: 1));
    }
    bool controlling() => remote.active && sonos.output?.id == roomId && player.item?.key == key && !player.audio.playing;

    try {
      await api.call('POST', '/sonos/$roomId/command', body: {'action': 'volume', 'volume': 5});
      await idle();

      // B: the other device starts the speaker; the app follows by itself.
      await other.play();
      final t0 = DateTime.now();
      await waitUntil(tester, controlling, seconds: 30, what: 'B: app controls the speaker the other device started');
      log('B ok after ${DateTime.now().difference(t0).inSeconds} s: ${remote.target}, ${player.item?.title}');

      // A: released, the overlay shows the room with who started it; "Control", then "Here".
      await idle();
      outputOpen.value = true;
      await waitFor(tester, find.byKey(const ValueKey('room-line-$roomId')), seconds: 20);
      final line = (tester.widget(find.byKey(const ValueKey('room-line-$roomId'))) as Text).data ?? '';
      log('A line: $line');
      expect(line, contains('Notebook (Test)'));
      await tester.tap(inRoomCard('Control'));
      await waitUntil(tester, controlling, seconds: 20, what: 'A: "Control" controls the room');
      log('A control ok');
      await idle();
      outputOpen.value = true;
      await waitFor(tester, inRoomCard('Here'), seconds: 20);
      await tester.tap(inRoomCard('Here'));
      await waitUntil(tester, () => player.audio.playing && !remote.active && player.item?.key == key, seconds: 30,
          what: 'A: "Here" plays here');
      final after = (await sonos.rooms()).firstWhere((r) => r.id == roomId);
      log('A here ok: playing here at ${player.position}, room session ${after.startedBy}');
      expect(after.startedBy, isNull, reason: '"Here" ends the session on the speaker');
      await idle();

      // B2: the session starts while the event stream is cut; after reconnecting the app follows.
      log('CUT');
      await tester.pump(const Duration(seconds: 8));
      await other.play();
      final t1 = DateTime.now();
      log('B2 session started during the cut');
      await waitUntil(tester, controlling, seconds: 150, what: 'B2: app controls the speaker after reconnecting');
      log('B2 ok after ${DateTime.now().difference(t1).inSeconds} s');
    } finally {
      await other.call('POST', '/sonos/$roomId/command', {'action': 'stop'}).catchError((_) => null);
      remote.release();
      await api.call('POST', '/sonos/$roomId/command', body: {'action': 'volume', 'volume': volume}).catchError((_) => null);
      await player.stop();
      await other.call('POST', '/auth/logout').catchError((_) => null);
      await api.call('POST', '/auth/logout').catchError((_) => null);
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}
