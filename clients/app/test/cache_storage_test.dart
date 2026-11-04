// 0.1.7 (user 2026-11-04): what the cache pill saves (album whole, also for a single title of it;
// book whole; podcast only the episode; radio nothing), the saved share, and "Keep at least …
// free" (5 GB default and smallest value, decimal; below it no download starts, none queued).

import 'dart:io';

import 'package:audiojoe/api.dart';
import 'package:audiojoe/cache.dart';
import 'package:audiojoe/downloads.dart';
import 'package:audiojoe/models.dart';
import 'package:audiojoe/storage.dart';
import 'package:audiojoe/store.dart';
import 'package:flutter_test/flutter_test.dart';

Item track(int n, {String? album, int? ms}) =>
    Item(key: 'jellyfin:1:t$n', kind: 'track', title: 'T$n', album: album, durationMs: ms ?? 100000);

void main() {
  setUpAll(() async {
    Stores.dir = Directory.systemTemp.createTempSync('audiojoe-test');
    for (final s in [Stores.device, Stores.offline, Stores.items]) {
      await s.open(Stores.dir);
    }
  });

  group('cache scope', () {
    const book = Item(key: 'abs:1:b', kind: 'book', title: 'Book');
    const ep = Item(key: 'episode:1', kind: 'episode', title: 'Episode');
    const radio = Item(key: 'radio:1', kind: 'radio', title: 'Radio');
    Future<List<Item>> none(String _) async => throw StateError('not asked');

    test('a book whole, a podcast only the episode, radio and nothing playing: nothing', () async {
      expect(await cacheScope(book, [book], tracksOf: none), [book]);
      expect(await cacheScope(ep, [ep], tracksOf: none), [ep]);
      expect(await cacheScope(radio, [radio], tracksOf: none), isEmpty);
      expect(await cacheScope(null, const [], tracksOf: none), isEmpty);
    });

    test('music played as an album: the queue', () async {
      final q = [track(1), track(2), track(3)];
      expect(await cacheScope(q[1], q, tracksOf: none), q);
    });

    test('a single title of an album: the whole album from the server', () async {
      final album = [track(1, album: 'jellyfin:1:a'), track(2, album: 'jellyfin:1:a')];
      final asked = <String>[];
      final got = await cacheScope(album[1], [album[1]], tracksOf: (a) async {
        asked.add(a);
        return album;
      });
      expect(asked, ['jellyfin:1:a']);
      expect(got.map((i) => i.key), album.map((i) => i.key));
    });

    test('a single title without album, or the album cannot be read: the title', () async {
      final t = track(1);
      expect(await cacheScope(t, [t], tracksOf: none), [t]);
      final u = track(2, album: 'jellyfin:1:a');
      expect(await cacheScope(u, [u], tracksOf: (_) async => throw Exception('offline')), [u]);
    });

    test('saved share by playing time, 100 only when all is there', () {
      final items = [track(1, ms: 100000), track(2, ms: 300000)];
      OfflineEntry e(String key, String status, [double p = 0]) => OfflineEntry(key, '', '', '', status: status, progress: p);
      expect(savedPercent(items, (_) => null), 0);
      expect(savedPercent(items, (k) => k.endsWith('t1') ? e(k, 'done') : null), 25);
      expect(savedPercent(items, (k) => k.endsWith('t1') ? e(k, 'done') : e(k, 'loading', 0.5)), 62);
      expect(savedPercent(items, (k) => k.endsWith('t1') ? e(k, 'done') : e(k, 'loading', 0.9999)), 99);
      expect(savedPercent(items, (k) => e(k, 'done')), 100);
    });
  });

  group('keep at least free', () {
    setUp(() {
      api.online.value = false; // nothing is fetched here
      Stores.device.data.clear();
      Stores.offline.data.clear();
    });

    test('5 GB default and smallest value; decimal GB', () async {
      expect(storage.keepFreeGb, 5);
      storage.keepFreeGb = 2;
      expect(storage.keepFreeGb, 5);
      storage.keepFreeGb = 8;
      expect(storage.keepFreeGb, 8);
      expect(gb, 1000000000);
    });

    test('below the limit: low, no download queued, the app is told', () async {
      Storage.probe = (_) async => 4999999999;
      var told = 0;
      final sub = downloads.refused.stream.listen((_) => told++);
      expect(await downloads.add([track(1)]), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(storage.low, isTrue);
      expect(told, 1);
      expect(downloads.entries, isEmpty);
      await sub.cancel();
    });

    test('at or above the limit: not low, queued', () async {
      Storage.probe = (_) async => 5 * gb;
      expect(await downloads.add([track(1)]), isTrue);
      expect(storage.low, isFalse);
      expect(downloads.entries.map((e) => e.key), ['jellyfin:1:t1']);
    });

    test('unknown free space blocks nothing', () async {
      Storage.probe = (_) async => null;
      await storage.refresh();
      expect(storage.low, isFalse);
    });
  });
}
