// Connection loss while playing (user 2026-11-07), Linux app under Xvfb, through
// tools/dev/cutproxy.py between app and server (tools/dev/connection-test-linux.sh).
//
//  A  stream without a copy: the connection hangs → the player waits at the position and
//     shows as playing, the length stays known (bar); connection back → it continues by itself at that position.
//  B  a copy finished while the episode streams: taken over without stopping (its cover saved
//     with it); then the connection is refused and the episode keeps playing from the copy.
//  C  a book of several files that is only partly saved: its saved first file plays from the copy.

import 'dart:io';

import 'package:audiojoe/api.dart';
import 'package:audiojoe/downloads.dart';
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
const control = String.fromEnvironment('CONTROL');
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

/// Switches the proxy between app and server: hang | refuse | restore.
Future<void> net(String mode) async {
  final c = HttpClient();
  final r = await (await c.getUrl(Uri.parse('$control/$mode'))).close();
  await r.drain<void>();
  c.close();
  // ignore: avoid_print
  print('NET $mode');
}

String state() => 'playing ${player.playing}, waiting ${player.waiting}, audio ${player.audio.playing}/${player.audio.processingState.name}, '
    'position ${player.position ~/ 1000} s, from copy ${player.partFromCopy}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('connection loss: wait and continue, take over the copy, partly saved book', (tester) async {
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
        .where((e) => e.durationMs != null)
        .toList()
      ..sort((a, b) => a.durationMs!.compareTo(b.durationMs!));
    final epB = eps.first;
    final epA = eps.lastWhere((e) => e.durationMs! > 1800000);

    // ---------------------------------------------------------- A: stream, the connection hangs
    // Without a length from the feed (as seen on Windows): the bar must still know it while waiting.
    final epAnoLen = Item.fromJson({...epA.toJson(), 'duration_ms': null});
    await player.play([epAnoLen]);
    await waitUntil(tester, () => player.audio.playing && player.position > 3000, what: 'A playing');
    await net('hang');
    await player.seekTo(1200000);
    await waitUntil(tester, () => player.waiting, seconds: 60, what: 'A waiting (${state()})');
    // ignore: avoid_print
    print('A waiting: ${state()}');
    expect(player.playing, isTrue, reason: 'waiting shows as playing');
    expect(player.position ~/ 1000, inInclusiveRange(1195, 1205), reason: state());
    // The bar keeps the held position: the length stays known while no source is loaded.
    expect(player.duration, greaterThan(1800000), reason: 'length while waiting: ${player.duration}');
    await net('restore');
    await waitUntil(tester, () => player.audio.playing && !player.waiting && player.position > 1202000, seconds: 60, what: 'A continues (${state()})');
    // ignore: avoid_print
    print('A continued: ${state()}');
    expect(player.position ~/ 1000, inInclusiveRange(1200, 1260), reason: state());

    // ---------------------------------------------------------- B: copy finished while streaming
    await player.play([epB]);
    await waitUntil(tester, () => player.audio.playing && player.position > 2000, what: 'B playing');
    expect(player.partFromCopy, isFalse);
    await downloads.add([epB]);
    await waitUntil(tester, () => downloads.isOffline(epB.key), seconds: 300, what: 'B saved');
    await waitUntil(tester, () => player.partFromCopy && player.audio.playing, seconds: 15, what: 'B taken over (${state()})');
    // ignore: avoid_print
    print('B taken over: ${state()}');
    // The cover was saved with it (it shows offline).
    expect(downloads.coverFile('/api/v1/image/${Uri.encodeComponent(epB.key)}'), isNotNull, reason: 'cover saved');
    await net('refuse');
    final b1 = player.position;
    await pumpFor(tester, 10);
    expect(player.audio.playing && player.position >= b1 + 7000, isTrue, reason: 'B keeps playing from the copy: ${state()}');
    await net('restore');

    // ---------------------------------------------------------- C: book of several files, partly saved
    Item? book;
    for (final l in (await api.call('GET', '/books/libraries') as List).cast<Map>().where((l) => l['lib'] != null)) {
      final res = await api.call('GET', '/sources/${l['source']}/books', query: {'parent': '${l['lib']}'}) as Map;
      for (final b in (res['books'] as List? ?? const []).take(60)) {
        final it = Item.fromJson((await api.call('GET', '/items/${Uri.encodeComponent((b as Map)['key'] as String)}') as Map).cast<String, dynamic>());
        if (it.multiPart && it.parts.length > 1 && it.parts.first.durationMs < 1800000) {
          book = it;
          break;
        }
      }
      if (book != null) break;
    }
    if (book == null) {
      // ignore: avoid_print
      print('C: no book of several files on this server – skipped');
    } else {
      // ignore: avoid_print
      print('C: ${book.title} (${book.parts.length} files)');
      await player.play([book]);
      await waitUntil(tester, () => player.audio.playing, what: 'C playing');
      final first = downloads.file(book.key, book.parts.first.index);
      await downloads.add([book]);
      await waitUntil(tester, () => first.existsSync(), seconds: 300, what: 'C first file saved');
      expect(downloads.isOffline(book.key), isFalse, reason: 'book not complete yet');
      if (player.position < book.parts.first.durationMs) {
        await waitUntil(tester, () => player.partFromCopy && player.audio.playing, seconds: 15, what: 'C first file from the copy (${state()})');
      }
      // ignore: avoid_print
      print('C: ${state()}');
      await downloads.remove(book.key);
    }
    await player.stop();
    expect(tester.takeException(), isNull);
  });
}
