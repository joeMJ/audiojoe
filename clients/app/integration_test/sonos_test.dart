// Playback on a real Sonos speaker, run by hand (it plays aloud, quietly):
//
//   flutter test integration_test/sonos_test.dart -d linux --dart-define=SERVER=… --dart-define=USER=… \
//     --dart-define=PASS=… --dart-define=TOTP_SECRET=… --dart-define=ROOM=6 \
//     --dart-define=FIRST=jellyfin:… --dart-define=NEXT=jellyfin:…
//
// Starts FIRST 40 s before its end on room ROOM (volume 5, restored afterwards), with NEXT after it
// in the queue. Checks that the shown position follows the speaker and that the app switches to
// NEXT when the speaker gets there, that ⏮ and ⏭ play on the speaker, not here. Then prints "CUT <port>": the event stream is cut without
// notice from outside (tools/dev/cut-events.sh), and positions must arrive again after reconnecting.

import 'dart:io';

import 'package:audiojoe/api.dart';
import 'package:audiojoe/l10n.dart';
import 'package:audiojoe/main.dart' as app;
import 'package:audiojoe/player.dart';
import 'package:audiojoe/remote.dart';
import 'package:audiojoe/sonos.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'app_test.dart' show totp, waitFor, waitUntil;

const server = String.fromEnvironment('SERVER');
const user = String.fromEnvironment('USER');
const pass = String.fromEnvironment('PASS');
const secret = String.fromEnvironment('TOTP_SECRET');
const roomId = int.fromEnvironment('ROOM');
const first = String.fromEnvironment('FIRST');
const next = String.fromEnvironment('NEXT');
const shots = String.fromEnvironment('SHOTS');

// ignore: avoid_print
void log(String s) => print('${DateTime.now().toIso8601String().substring(11, 19)} $s');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sonos: position, next title, stream cut', (tester) async {
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

    final room = (await sonos.rooms()).firstWhere((r) => r.id == roomId);
    final volume = room.volume ?? 15;
    try {
      await api.call('POST', '/sonos/$roomId/command', body: {'action': 'volume', 'volume': 5});
      final a = (await player.meta(first))!, b = (await player.meta(next))!;
      await player.play([a, b]);
      await waitUntil(tester, () => player.audio.playing, what: 'playing here');
      await player.seekTo(a.durationMs! - 40000);
      await tester.pump(const Duration(seconds: 1));
      await sonos.playOn(room);
      final start = player.position;
      log('on Sonos at $start of ${a.durationMs}');

      // The shown position moves with the speaker (the server reports about every 10 s).
      await waitUntil(tester, () => player.item?.key == first && player.position > start + 5000, seconds: 30,
          what: 'position follows the speaker (${player.position})');
      log('position follows: ${player.position}');
      // The shown time runs on every second between the speaker's reports (screenshots 1 s apart).
      if (shots.isNotEmpty) {
        for (var i = 0; i < 10; i++) {
          await Process.run('import', ['-window', 'root', '$shots/sonos-clock-$i.png']);
          log('clock $i: ${clock(player.position)}');
          await tester.pump(const Duration(seconds: 1));
        }
      }
      expect(player.audio.playing, isFalse, reason: 'the app does not play along');

      // The speaker reaches the next title by itself; the app shows it.
      await waitUntil(tester, () => player.item?.key == next, seconds: 60, what: 'app switches to the next title');
      await waitUntil(tester, () => player.position > 3000, seconds: 30, what: 'position of the next title');
      log('next title shown at ${player.position}, queue index ${player.index}');
      expect(player.audio.playing, isFalse);

      // ⏮ while the speaker plays: the speaker plays the title before, this device stays silent.
      await player.skip(-1);
      await tester.pump(const Duration(seconds: 2));
      expect(player.audio.playing, isFalse, reason: '⏮ must not play here');
      await waitUntil(tester, () => player.item?.key == first && player.position > 5000, seconds: 40,
          what: 'speaker plays the title before (${player.item?.key} ${player.position})');
      expect(player.audio.playing, isFalse, reason: 'still not playing here');
      log('skip back on the speaker: ${player.position}, queue index ${player.index}');
      // And ⏭ again, so the rest of the test runs on the next title as before.
      await player.skip(1);
      await waitUntil(tester, () => player.item?.key == next && player.position > 3000, seconds: 40,
          what: 'speaker plays the next title again');
      expect(player.audio.playing, isFalse);
      log('skip forward on the speaker: ${player.position}');

      // Cut the event stream without notice; the app must notice the silence and reconnect.
      final cut = DateTime.now();
      log('CUT');
      await tester.pump(const Duration(seconds: 15));
      // The clock runs on by itself; the speaker's reports must come again over a new stream.
      final frozen = remote.reports;
      await waitUntil(tester, () => remote.reports > frozen + 1, seconds: 120,
          what: 'reports arrive again after the cut');
      log('reports again after ${DateTime.now().difference(cut).inSeconds} s: ${player.position}');
    } finally {
      await remote.command('pause').catchError((_) => null);
      remote.release();
      await api.call('POST', '/sonos/$roomId/command', body: {'action': 'volume', 'volume': volume});
      await player.stop();
      await api.call('POST', '/auth/logout');
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
