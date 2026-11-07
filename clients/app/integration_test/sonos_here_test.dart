// "Here" from a real Sonos speaker in the middle of an album, run by hand (it plays aloud, quietly):
//
//   flutter test integration_test/sonos_here_test.dart -d linux --dart-define=SERVER=… --dart-define=USER=… \
//     --dart-define=PASS=… --dart-define=TOTP_SECRET=… --dart-define=ROOM=6 \
//     --dart-define=FIRST=jellyfin:… --dart-define=NEXT=jellyfin:… --dart-define=THIRD=jellyfin:…
//
// FIRST, NEXT, THIRD: three titles of one album in this order. Twice: FIRST 25 s before its end goes
// to room ROOM (volume 10, restored afterwards); when the speaker is on NEXT, "Here" continues it in
// the app. 1: as the user did it (2026-11-07: only the fetched title played) – the app plays THIRD
// after NEXT. 2: after a restart, i.e. the app shows NEXT without its album – the album comes back
// from the server.

import 'package:audiojoe/api.dart';
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
const third = String.fromEnvironment('THIRD');

// ignore: avoid_print
void log(String s) => print('${DateTime.now().toIso8601String().substring(11, 19)} $s');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sonos: "Here" in the middle of an album continues the album', (tester) async {
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
    final a = (await player.meta(first))!, b = (await player.meta(next))!, c = (await player.meta(third))!;
    List<String> keys() => [for (final q in player.queue) q.key];

    // Plays FIRST here, sends it to the speaker shortly before its end and waits until it plays NEXT.
    Future<void> toSonosUntilNext() async {
      await player.play([a, b, c]);
      await waitUntil(tester, () => player.audio.playing, what: 'playing here');
      await player.seekTo(a.durationMs! - 25000);
      await tester.pump(const Duration(seconds: 1));
      await sonos.playOn(room);
      log('on Sonos at ${player.position} of ${a.durationMs}');
      await waitUntil(tester, () => player.item?.key == next && player.position > 3000, seconds: 90,
          what: 'speaker plays the next title (${player.item?.key} ${player.position})');
      log('speaker on NEXT at ${player.position}');
    }

    try {
      await api.call('POST', '/sonos/$roomId/command', body: {'action': 'volume', 'volume': 10});

      // 1 – as the user did it.
      await toSonosUntilNext();
      await remote.takeHere(remote.target!);
      await waitUntil(tester, () => player.audio.playing, what: 'NEXT plays here');
      log('1: here ${player.item?.key} at ${player.position}, queue ${keys()} index ${player.index}');
      expect(keys(), [first, next, third], reason: 'the album stays the queue');
      expect(player.index, 1);
      await player.seekTo(b.durationMs! - 6000);
      await waitUntil(tester, () => player.item?.key == third && player.audio.playing, seconds: 40,
          what: 'THIRD follows NEXT here (${player.item?.key})');
      log('1: THIRD follows: ${player.item?.key} at ${player.position}');
      await player.pauseHere();

      // 2 – after a restart the app shows NEXT without its album.
      await toSonosUntilNext();
      player.queue = [player.item!];
      player.index = 0;
      await remote.takeHere(remote.target!);
      await waitUntil(tester, () => player.audio.playing, what: 'NEXT plays here');
      log('2: here ${player.item?.key} at ${player.position}, queue ${keys()} index ${player.index}');
      expect(keys(), [first, next, third], reason: 'the album comes back from the server');
      expect(player.index, 1);
    } finally {
      await remote.command('pause').catchError((_) => null);
      remote.release();
      await api.call('POST', '/sonos/$roomId/command', body: {'action': 'volume', 'volume': volume});
      await player.stop();
      await api.call('POST', '/auth/logout');
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}
