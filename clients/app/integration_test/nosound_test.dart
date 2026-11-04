// Playback without an audio output (seen in a Windows VM over RDP: "playing", the clock stood
// still, "Here" jumped to the next title). Run by tools/dev/nosound-test-linux.sh twice:
//
//   SOUND=none    no audio output: the app says so, pauses and stays on the title.
//   SOUND=silent  a silent output as the counter-check: the clock runs, no message.
//
//   flutter test integration_test/nosound_test.dart -d linux --dart-define=SERVER=… --dart-define=USER=… \
//     --dart-define=PASS=… --dart-define=TOTP_SECRET=… --dart-define=FIRST=jellyfin:… \
//     --dart-define=NEXT=jellyfin:… --dart-define=SOUND=none|silent

import 'package:audiojoe/main.dart' as app;
import 'package:audiojoe/player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'app_test.dart' show totp, waitFor, waitUntil;

const server = String.fromEnvironment('SERVER');
const user = String.fromEnvironment('USER');
const pass = String.fromEnvironment('PASS');
const secret = String.fromEnvironment('TOTP_SECRET');
const first = String.fromEnvironment('FIRST');
const next = String.fromEnvironment('NEXT');
const sound = String.fromEnvironment('SOUND');

// ignore: avoid_print
void log(String s) => print('${DateTime.now().toIso8601String().substring(11, 19)} $s');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('playback without an audio output: $sound', (tester) async {
    final problems = <String>[];
    player.problems.stream.listen(problems.add);
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

    // The album as the queue, then "Here" at 50 s into the first title (the path that failed on Windows).
    final a = (await player.meta(first))!, b = (await player.meta(next))!;
    await player.play([a, b]);
    await tester.pump(const Duration(seconds: 2));
    await player.audio.pause();
    await tester.pump(const Duration(seconds: 1));
    // Only what "Here" causes counts (without sound the first start already says so).
    problems.clear();
    await player.takeOver(first, 50000);
    final start = DateTime.now();
    log('"Here" ${a.title} at 50 s, sound $sound');

    if (sound == 'none') {
      await waitUntil(tester, () => problems.isNotEmpty, seconds: 20, what: 'message "nothing plays"');
      log('message after ${DateTime.now().difference(start).inSeconds} s: ${problems.first}');
      expect(problems.first, Player.cannotPlayText);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(SnackBar), findsOneWidget, reason: 'the message is shown');
      expect(player.audio.playing, isFalse, reason: 'paused');
      expect(player.item?.key, first, reason: 'stays on the title, no jump to the next one');
      expect(player.position, 50000, reason: 'keeps the taken-over position');
      log('paused on ${player.item?.title} at ${player.position}');
    } else {
      await tester.pump(const Duration(seconds: 10));
      final p1 = player.position;
      await tester.pump(const Duration(seconds: 4));
      final p2 = player.position;
      log('after 10 s: $p1, after 14 s: $p2, playing ${player.audio.playing}, messages ${problems.length}');
      expect(p1, greaterThan(50000), reason: 'starts at the taken-over position');
      expect(p2 - p1, greaterThan(3000), reason: 'the clock runs');
      expect(problems, isEmpty, reason: 'no message when it plays');
      expect(player.item?.key, first);
      await player.audio.pause();
    }
  });
}
