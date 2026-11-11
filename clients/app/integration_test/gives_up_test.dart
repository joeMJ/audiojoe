// Proposal A (user 2026-11-11 „215 ja 216 ja“), Linux app under Xvfb with an audio output that does
// not exist (--dart-define=AUDIOJOE_AO=…): the server delivers the stream, the device cannot play it.
// After 3 attempts in a row the player stops trying: paused at the position, a message, an entry in
// the error log, no further attempt. ▶ tries again (and gives up again).
//
//   tools/dev/gives-up-test-linux.sh SERVER CREDENTIALS_JSON


import 'package:audiojoe/api.dart';
import 'package:audiojoe/errors.dart';
import 'package:audiojoe/main.dart' as app;
import 'package:audiojoe/models.dart';
import 'package:audiojoe/player.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

Future<void> pumpFor(WidgetTester tester, int seconds) async {
  for (var i = 0; i < seconds * 4; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

String state() => 'playing ${player.playing}, waiting ${player.waiting}, audio ${player.audio.playing}/${player.audio.processingState.name}, '
    'position ${player.position ~/ 1000} s';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('no audio output: gives up after 3 attempts with a message', (tester) async {
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

    final sub = await api.call('POST', '/podcasts', body: {'feed_url': feed}) as Map;
    final eps = (await api.call('GET', '/podcasts/${sub['id']}/episodes', query: {'limit': '200'}) as List)
        .map((e) => Item.fromJson((e as Map).cast<String, dynamic>()))
        .where((e) => e.durationMs != null && e.durationMs! > 600000)
        .toList();
    final ep = eps.first;
    final logged = errorLog.entries.length;
    final t0 = DateTime.now();
    await player.play([ep]);
    final message = find.textContaining('Playback is not possible on this device');
    await waitFor(tester, message, seconds: 60);
    final took = DateTime.now().difference(t0).inSeconds;
    // ignore: avoid_print
    print('gave up after $took s: ${state()}');
    expect(took, inInclusiveRange(8, 45), reason: 'about 3 attempts of 5 s');
    expect(player.waiting, isFalse, reason: state());
    expect(player.playing, isFalse, reason: state());
    expect(errorLog.entries.length, greaterThan(logged), reason: 'entry in the error log');
    expect(errorLog.entries.first.message, contains('gave up after 3 attempts'));
    // No further attempt: stays paused, not waiting, for 20 s.
    for (var i = 0; i < 20; i++) {
      await pumpFor(tester, 1);
      expect(player.waiting || player.audio.playing, isFalse, reason: 'no further attempt after ${i + 1} s: ${state()}');
    }
    // ▶ tries again – and gives up again.
    await tester.pump(const Duration(seconds: 5)); // the message goes
    await pumpFor(tester, 5);
    player.toggle();
    await waitUntil(tester, () => player.waiting || player.audio.playing, seconds: 15, what: 'new attempt after ▶ (${state()})');
    await waitFor(tester, message, seconds: 60);
    // ignore: avoid_print
    print('gave up again after ▶: ${state()}');
    await player.stop();
    await api.call('DELETE', '/podcasts/${sub['id']}');
    expect(tester.takeException(), isNull);
  });
}
