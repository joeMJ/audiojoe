// End of a title within an album (bug in 0.1.6, user 2026-11-04: "In einem Album wird am Ende
// des Tracks nicht weitergespielt und die Fehlermeldung im Boden angezeigt"; the check behind it
// was removed in 0.1.7). The next title must play and keep running. Since 0.2.4 also (user
// 2026-11-08): a title without any queue (restart, single title) plays within its album with ⏮ ⏭
// ("Fehler 1"), and a title played past the middle runs on and hands over to the next one
// ("Fehler 2": on 171 title 3 of "Anjunadeep: The Yearbook 2025" stopped after about 186 s).
// Run by
// tools/dev/album-end-test-linux.sh with a silent output:
//
//   flutter test integration_test/album_end_test.dart -d linux --dart-define=SERVER=… --dart-define=USER=…
//     --dart-define=PASS=… --dart-define=TOTP_SECRET=… --dart-define=SEARCH=<album name>

import 'package:audiojoe/api.dart';
import 'package:audiojoe/main.dart' as app;
import 'package:audiojoe/models.dart';
import 'package:audiojoe/player.dart';
import 'package:audiojoe/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'app_test.dart' show totp, waitFor, waitUntil;

const server = String.fromEnvironment('SERVER');
const user = String.fromEnvironment('USER');
const pass = String.fromEnvironment('PASS');
const secret = String.fromEnvironment('TOTP_SECRET');
const search = String.fromEnvironment('SEARCH', defaultValue: 'Anjunabeats');
/// FULL=true: only "Fehler 2" with title 3 played from its start to its end without any seek (as
/// on 171, where it stopped after 186 s), e.g. through the reverse proxy (SERVER=https://…).
const full = bool.fromEnvironment('FULL');

// ignore: avoid_print
void log(String s) => print('${DateTime.now().toIso8601String().substring(11, 19)} $s');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('album: the end of a title plays the next one, no message', (tester) async {
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

    // An album of the first music source and its first two titles.
    final sources = (await api.call('GET', '/sources') as List).cast<Map>().where((s) => s['kind'] == 'jellyfin');
    final src = sources.first['id'];
    final found = await api.call('GET', '/sources/$src/browse', query: {'search': search, 'limit': '50'}) as Map;
    final album = [for (final j in found['items'] as List) Item.fromJson((j as Map).cast<String, dynamic>())].firstWhere((i) => i.kind == 'album');
    final res = await api.call('GET', '/sources/$src/browse', query: {'parent': album.key.split(':')[2], 'limit': '500'}) as Map;
    final tracks = [for (final j in res['items'] as List) Item.fromJson((j as Map).cast<String, dynamic>())].where((i) => i.kind == 'track').toList();
    log('album ${album.title}: ${tracks.length} titles, first ${tracks[0].title}, next ${tracks[1].title}');

    if (full) {
      await player.play(tracks, 2, (list: 'music', key: album.key));
      await waitUntil(tester, () => player.audio.playing, seconds: 20, what: 'title 3 playing');
      final len = tracks[2].durationMs ?? 330000;
      log('title 3 ${tracks[2].title}: ${len ~/ 1000} s, played from the start without seeking');
      final end = DateTime.now().add(Duration(milliseconds: len + 40000));
      var last = -1;
      while (player.item?.key == tracks[2].key && DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(seconds: 10));
        final p = player.position;
        log('title 3 at ${p ~/ 1000} s, playing ${player.audio.playing}, state ${player.audio.processingState}, buffered ${player.audio.bufferedPosition.inSeconds} s');
        if (p == last && player.item?.key == tracks[2].key) log('  ✖ position stands');
        last = p;
      }
      log('now ${player.item?.title} at ${player.position}, playing ${player.audio.playing}');
      expect(player.item?.key, tracks[3].key, reason: 'the end of title 3 plays title 4');
      await tester.pump(const Duration(seconds: 4));
      expect(player.audio.playing, isTrue);
      await player.audio.pause();
      return;
    }
    await player.play(tracks, 0, (list: 'music', key: album.key));
    await waitUntil(tester, () => player.audio.playing && (player.audio.duration ?? Duration.zero) > Duration.zero, seconds: 20, what: 'playing');
    final d = player.audio.duration!;
    await player.seekTo(d.inMilliseconds - 4000);
    log('seek to ${d.inSeconds - 4} s of ${d.inSeconds} s');
    await waitUntil(tester, () => player.item?.key == tracks[1].key, seconds: 25, what: 'next title');
    await tester.pump(const Duration(seconds: 4));
    log('now ${player.item?.title} at ${player.position}, playing ${player.audio.playing}');
    expect(find.byType(SnackBar), findsNothing, reason: 'no message at the end of a title');
    expect(player.audio.playing, isTrue);
    expect(player.position, greaterThan(1000), reason: 'the next title runs');
    await player.audio.pause();

    // Fehler 1: no queue anywhere (the server deletes it for a queue of one title, the device forgets
    // it): a single title and the restart (cueLast) continue within the album.
    Future<void> forgetQueues(Item t) async {
      await api.call('PUT', '/queue', body: {'items': [t.toJson()], 'index': 0, 'entry': null});
      Stores.device.put('queue', {'items': [], 'index': -1, 'entry': null});
    }
    await player.stop();
    await forgetQueues(tracks[1]);
    await player.play([tracks[1]]);
    log('single title: queue ${player.queue.length}, index ${player.index}, entry ${player.entry}');
    expect(player.queue.length, tracks.length, reason: 'a single title plays within its album');
    expect(player.index, 1);
    expect(player.entry?.list, 'music');
    await waitUntil(tester, () => player.audio.playing, seconds: 20, what: 'playing');
    await player.audio.pause();
    await tester.pump(const Duration(seconds: 2));
    await player.stop();
    await forgetQueues(tracks[1]);
    await player.cueLast();
    log('restart: ${player.item?.title}, queue ${player.queue.length}, index ${player.index}');
    expect(player.item?.key, tracks[1].key);
    expect(player.queue.length, tracks.length, reason: 'the restart shows the album, with ⏮ ⏭');
    expect(player.index, 1);

    // Fehler 2: title 3 from 175 s on keeps running past 186 s, then its end plays title 4.
    if (tracks.length > 3) {
      await player.stop();
      await player.play(tracks, 2, (list: 'music', key: album.key));
      await waitUntil(tester, () => player.audio.playing && (player.audio.duration ?? Duration.zero) > Duration.zero, seconds: 20, what: 'title 3 playing');
      await player.seekTo(175000);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 5));
        log('title 3 at ${player.position} ms, playing ${player.audio.playing}, state ${player.audio.processingState}');
      }
      expect(player.item?.key, tracks[2].key);
      expect(player.position, greaterThan(195000), reason: 'title 3 runs on past 186 s');
      expect(player.audio.playing, isTrue);
      final d3 = player.audio.duration!;
      await player.seekTo(d3.inMilliseconds - 4000);
      await waitUntil(tester, () => player.item?.key == tracks[3].key, seconds: 25, what: 'title 4');
      await tester.pump(const Duration(seconds: 4));
      log('now ${player.item?.title} at ${player.position}, playing ${player.audio.playing}');
      expect(player.audio.playing, isTrue);
      expect(player.position, greaterThan(1000), reason: 'title 4 runs');
      await player.audio.pause();
    }
  });
}
