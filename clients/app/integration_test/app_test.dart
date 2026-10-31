// End-to-end test of the desktop app against a running server (Linux, under Xvfb).
//
//   flutter test integration_test -d linux \
//     --dart-define=SERVER=https://audio.example.org --dart-define=USER=… \
//     --dart-define=PASS=… --dart-define=TOTP_SECRET=…
//
// Signs in through the UI, opens podcasts, plays an episode, checks that the position
// reaches the server, saves it offline and plays it from the offline copy.

import 'dart:typed_data';

import 'package:audiojoe/api.dart';
import 'package:audiojoe/downloads.dart';
import 'package:audiojoe/main.dart' as app;
import 'package:audiojoe/models.dart';
import 'package:audiojoe/player.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const server = String.fromEnvironment('SERVER');
const user = String.fromEnvironment('USER');
const pass = String.fromEnvironment('PASS');
const secret = String.fromEnvironment('TOTP_SECRET');
const feed = 'https://feeds.lagedernation.org/feeds/ldn-mp3.xml';

String totp(String base32, DateTime now) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final bits = base32.replaceAll('=', '').split('').map((c) => alphabet.indexOf(c).toRadixString(2).padLeft(5, '0')).join();
  final key = [for (var i = 0; i + 8 <= bits.length; i += 8) int.parse(bits.substring(i, i + 8), radix: 2)];
  final counter = now.millisecondsSinceEpoch ~/ 1000 ~/ 30;
  final msg = ByteData(8)..setInt64(0, counter);
  final h = Hmac(sha1, key).convert(msg.buffer.asUint8List()).bytes;
  final o = h.last & 15;
  final v = ((h[o] & 0x7f) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) | h[o + 3];
  return (v % 1000000).toString().padLeft(6, '0');
}

Future<void> waitFor(WidgetTester tester, Finder f, {int seconds = 30}) async {
  for (var i = 0; i < seconds * 4; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (f.evaluate().isNotEmpty) return;
  }
  throw TestFailure('not found within $seconds s: $f');
}

Future<void> waitUntil(WidgetTester tester, bool Function() cond, {int seconds = 30, String what = ''}) async {
  for (var i = 0; i < seconds * 4; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (cond()) return;
  }
  throw TestFailure('condition not met within $seconds s: $what');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sign in, podcast, play, sync, offline', (tester) async {
    await app.main();
    await tester.pumpAndSettle();

    // ---------------------------------------------------------- sign in through the UI
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(5));
    // The code may be used only once: wait for a fresh 30 s step.
    await Future.delayed(Duration(seconds: 31 - DateTime.now().second % 30));
    await tester.enterText(fields.at(0), server);
    await tester.enterText(fields.at(1), user);
    await tester.enterText(fields.at(2), pass);
    await tester.enterText(fields.at(3), totp(secret, DateTime.now()));
    await tester.enterText(fields.at(4), 'Linux (Test)');
    await tester.tap(find.byType(FilledButton));
    await waitFor(tester, find.text('Server reachable'));

    // ---------------------------------------------------------- podcast
    final sub = await api.call('POST', '/podcasts', body: {'feed_url': feed}) as Map;
    await tester.tap(find.text('Podcasts').last);
    await waitFor(tester, find.textContaining('LdN'));
    final eps = (await api.call('GET', '/podcasts/${sub['id']}/episodes', query: {'limit': '200'}) as List)
        .map((e) => Item.fromJson((e as Map).cast<String, dynamic>()))
        .where((e) => e.durationMs != null)
        .toList()
      ..sort((a, b) => a.durationMs!.compareTo(b.durationMs!));
    final ep = Item(key: eps.first.key, kind: 'episode', title: eps.first.title, subtitle: eps.first.subtitle);

    // ---------------------------------------------------------- play, position on the server
    await player.play([ep]);
    await waitUntil(tester, () => player.playing && player.position > 3000, what: 'playing');
    await player.seekTo(120000);
    await tester.pump(const Duration(seconds: 2));
    player.toggle(); // pause → saves
    await tester.pump(const Duration(seconds: 3));
    final pb = await api.call('GET', '/playback/${Uri.encodeComponent(ep.key)}') as Map;
    expect(pb['device'], 'Linux (Test)');
    expect((pb['position_ms'] as int) >= 120000 && (pb['position_ms'] as int) < 130000, isTrue, reason: 'position ${pb['position_ms']}');

    // ---------------------------------------------------------- offline copy
    await downloads.add([ep]);
    await waitUntil(tester, () => downloads.isOffline(ep.key), seconds: 300, what: 'offline download');
    await player.play([ep]);
    expect(player.fromCache, isTrue);
    await waitUntil(tester, () => player.playing, what: 'playing from file');
    final at = player.position;
    await tester.pump(const Duration(seconds: 3));
    expect(player.position > at, isTrue, reason: 'position advances from the offline file');
    await player.stop();

    // ---------------------------------------------------------- cleanup
    await downloads.remove(ep.key);
    await api.call('DELETE', '/podcasts/${sub['id']}');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
