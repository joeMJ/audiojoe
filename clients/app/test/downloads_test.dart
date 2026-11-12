// 0.2.0 storage (user 2026-11-07, test duty in the development plan: sub-folders, moving on the
// same and to another drive, stopping in the middle, space limit, resuming): downloads in
// podcasts/audiobooks/music, at most two at a time, ".part" until complete, the 0.1.x folder taken
// over, "Move to …" as tvjoe (umzug.rs), "Delete after listening".

import 'dart:async';
import 'dart:io';

import 'package:audiojoe/api.dart';
import 'package:audiojoe/cache.dart';
import 'package:audiojoe/downloads.dart';
import 'package:audiojoe/models.dart';
import 'package:audiojoe/storage.dart';
import 'package:audiojoe/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Server stand-in: `/stream/<key>` answers with `size` bytes once the test releases the key.
class FakeServer extends http.BaseClient {
  final gates = <String, Completer<void>>{};
  final open = <String>{};
  var most = 0;
  var size = 1000;
  /// Keys whose body breaks off after half (the download must not get its final name).
  final short = <String>{};

  /// After a test: every download, also one asked for later, goes through at once.
  bool released = false;

  Completer<void> gate(String key) => gates.putIfAbsent(key, () => released ? (Completer<void>()..complete()) : Completer<void>());

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = Uri.decodeComponent(request.url.path);
    if (!path.contains('/stream/')) {
      return http.StreamedResponse(Stream.value('{"error":"no"}'.codeUnits), 404, headers: {'content-type': 'application/json'});
    }
    final key = path.split('/stream/').last;
    final ctrl = StreamController<List<int>>();
    open.add(key);
    if (open.length > most) most = open.length;
    unawaited(() async {
      await gate(key).future;
      ctrl.add(List.filled(short.contains(key) ? size ~/ 2 : size, 7));
      open.remove(key);
      await ctrl.close();
    }());
    return http.StreamedResponse(ctrl.stream, 200, contentLength: size);
  }
}

Item track(int n, {String? album}) => Item(key: 'jellyfin:1:t$n', kind: 'track', title: 'T$n', album: album, durationMs: 1000);
Item episode(int n) => Item(key: 'episode:$n', kind: 'episode', title: 'E$n', durationMs: 1000);
const book = Item(key: 'abs:1:b', kind: 'book', title: 'Book', parts: [Part(0, 0, 1000)]);

Future<void> settle([bool Function()? until]) async {
  for (var i = 0; i < 200; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (until?.call() ?? false) return;
  }
}

void main() {
  late Directory tmp;
  late FakeServer server;
  final sep = Platform.pathSeparator;

  setUpAll(() async {
    Stores.dir = Directory.systemTemp.createTempSync('audiojoe-dl');
    for (final s in [Stores.device, Stores.offline, Stores.items, Stores.positions]) {
      await s.open(Stores.dir);
    }
    Storage.probe = (_) async => 100 * gb;
  });

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('audiojoe-root');
    for (final s in [Stores.device, Stores.offline, Stores.items, Stores.positions]) {
      s.data.clear();
    }
    storage.dir = Directory('${tmp.path}${sep}audiojoe');
    server = FakeServer();
    api.client = server;
    api.base = 'http://test';
    api.online.value = true;
  });

  tearDown(() async {
    server.released = true;
    for (final g in server.gates.values) {
      if (!g.isCompleted) g.complete();
    }
    await settle(() => downloads.running == 0);
    expect(downloads.running, 0, reason: 'a download of this test still runs');
  });

  test('desktop default: "audiojoe" in the home folder; Android: the app storage', () {
    final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    expect(Storage.defaultDir(), '$home${sep}audiojoe');
    Stores.device.data.clear();
    expect(storage.dir.path, Storage.desktop ? '$home${sep}audiojoe' : '${Stores.dir.path}/offline');
  });

  test('sub-folders per kind; ".part" until complete, then the final name', () async {
    await downloads.add([episode(1), track(1)]);
    await settle(() => server.open.length == 2);
    final root = storage.dir.path;
    expect(downloads.entry('episode:1')!.dir, '$root${sep}podcasts');
    expect(downloads.entry('jellyfin:1:t1')!.dir, '$root${sep}music');
    final f = downloads.file('episode:1');
    expect(f.path, '$root${sep}podcasts${sep}episode_1');
    await settle(() => File('${f.path}.part').existsSync());
    expect(f.existsSync(), isFalse);
    server.gate('episode:1').complete();
    server.gate('jellyfin:1:t1').complete();
    await settle(() => downloads.isOffline('episode:1') && downloads.isOffline('jellyfin:1:t1'));
    expect(f.lengthSync(), 1000);
    expect(File('${f.path}.part').existsSync(), isFalse);
  });

  test('an audiobook goes to audiobooks', () async {
    await downloads.add([book]);
    expect(downloads.entry(book.key)!.dir, '${storage.dir.path}${sep}audiobooks');
  });

  test('at most two downloads at a time; the third starts when one is done', () async {
    await downloads.add([track(1), track(2), track(3)]);
    await settle(() => server.open.length == 2);
    await settle();
    expect(server.open, {'jellyfin:1:t1', 'jellyfin:1:t2'}); // oldest first
    expect(downloads.running, 2);
    expect(downloads.entry('jellyfin:1:t3')!.status, 'queued');
    server.gate('jellyfin:1:t1').complete();
    await settle(() => server.open.contains('jellyfin:1:t3'));
    expect(server.open, {'jellyfin:1:t2', 'jellyfin:1:t3'});
    expect(server.most, 2);
  });

  test('0.3.3: downloads go in the order asked for (cache pill: title playing first)', () async {
    // Playing 3 of 5: the pill asks for 3, 4, 5, 1, 2 (cacheOrder); the downloads start in that order.
    final album = [for (var n = 1; n <= 5; n++) track(n, album: 'jellyfin:1:a')];
    final asked = cacheOrder(album, album[2]);
    expect(asked.map((x) => x.title), ['T3', 'T4', 'T5', 'T1', 'T2']);
    await downloads.add(asked);
    final started = <String>[];
    void note() => [for (final k in server.open) if (!started.contains(k)) k].forEach(started.add);
    await settle(() => server.open.length == 2);
    note();
    for (final k in ['jellyfin:1:t3', 'jellyfin:1:t4', 'jellyfin:1:t5', 'jellyfin:1:t1']) {
      server.gate(k).complete();
      await settle(() => !server.open.contains(k) && (server.open.length == 2 || started.length + server.open.length >= 5));
      note();
    }
    expect(started, ['jellyfin:1:t3', 'jellyfin:1:t4', 'jellyfin:1:t5', 'jellyfin:1:t1', 'jellyfin:1:t2']);
  });

  test('cacheOrder: playing 6 of 42 → 6 … 42, 1 … 5; first title or unknown title: unchanged', () {
    final album = [for (var n = 1; n <= 42; n++) track(n)];
    expect(cacheOrder(album, album[5]).map((x) => x.title).toList(),
        [for (var n = 6; n <= 42; n++) 'T$n', for (var n = 1; n <= 5; n++) 'T$n']);
    expect(cacheOrder(album, album[0]), album);
    expect(cacheOrder(album, track(99)), album);
    expect(cacheOrder(album, null), album);
  });

  test('a body that breaks off never gets the final name; the retry completes it', () async {
    server.short.add('episode:1');
    server.gate('episode:1').complete();
    await downloads.add([episode(1)]);
    final f = downloads.file('episode:1');
    await settle(() => File('${f.path}.part').existsSync());
    expect(f.existsSync(), isFalse);
    expect(downloads.entry('episode:1')!.status, 'loading');
    // The next try (after 2 s) gets the whole file.
    server.short.clear();
    for (var i = 0; i < 4 && !downloads.isOffline('episode:1'); i++) {
      await settle(() => downloads.isOffline('episode:1'));
    }
    expect(f.lengthSync(), 1000);
    expect(File('${f.path}.part').existsSync(), isFalse);
  });

  test('deleted while loading: the download stops and leaves no file', () async {
    await downloads.add([episode(1)]);
    final f = downloads.file('episode:1');
    await settle(() => File('${f.path}.part').existsSync() || server.open.isNotEmpty);
    await downloads.remove('episode:1');
    server.gate('episode:1').complete();
    await settle(() => downloads.running == 0);
    expect(downloads.entry('episode:1'), isNull);
    expect(f.existsSync(), isFalse);
    expect(File('${f.path}.part').existsSync(), isFalse);
  });

  test('below the limit nothing starts; waiting ones load once there is room', () async {
    Storage.probe = (_) async => 1 * gb;
    expect(await downloads.add([episode(1)]), isFalse);
    Storage.probe = (_) async => 100 * gb;
    await downloads.add([episode(1), episode(2)]);
    Storage.probe = (_) async => 1 * gb;
    server.gate('episode:1').complete();
    await settle(() => downloads.isOffline('episode:1'));
    await settle();
    // episode 2 had started together with 1 (two at a time).
    expect(server.open.length, lessThanOrEqualTo(1));
    Storage.probe = (_) async => 100 * gb;
  });

  test('an album is one line; partly loaded; deleted whole', () async {
    const album = Item(key: 'jellyfin:1:a', kind: 'album', title: 'Kind of Blue', subtitle: 'Miles Davis');
    final tracks = [track(1, album: 'jellyfin:1:a'), track(2, album: 'jellyfin:1:a')];
    await downloads.add(tracks, album: album);
    // Only two of four titles: the album page had all four, the cache pill a single one.
    for (final e in downloads.entries) {
      Stores.offline.put(e.key, (e.toJson()..['album_count'] = 4));
    }
    server.gate('jellyfin:1:t1').complete();
    server.gate('jellyfin:1:t2').complete();
    await settle(() => downloads.entries.every((e) => e.status == 'done'));
    final g = downloads.groups.single;
    expect((g.id, g.title, g.subtitle, g.total, g.section), ('jellyfin:1:a', 'Kind of Blue', 'Miles Davis', 4, 'partial'));
    await downloads.add([episode(1)]);
    expect(downloads.groups.length, 2);
    await downloads.removeGroup(downloads.groups.firstWhere((g) => g.id == 'jellyfin:1:a'));
    expect(downloads.entries.map((e) => e.key), ['episode:1']);
    expect(Directory('${storage.dir.path}${sep}music').listSync(), isEmpty);
  });

  test('sections: loading, waiting, done', () async {
    await downloads.add([episode(1), episode(2), episode(3)]);
    await settle(() => server.open.length == 2);
    await settle();
    final s = {for (final g in downloads.groups) g.id: g.section};
    expect(s, {'episode:1': 'loading', 'episode:2': 'loading', 'episode:3': 'waiting'});
  });

  test('0.1.x downloads move into the sub-folders, the entry follows', () async {
    final old = Directory('${Stores.dir.path}/offline')..createSync(recursive: true);
    File('${old.path}/episode_9').writeAsBytesSync(List.filled(10, 1));
    Stores.items.put('episode:9', episode(9).toJson());
    Stores.offline.put('episode:9', {
      'key': 'episode:9', 'title': 'E9', 'subtitle': '', 'added': '2026-01-01', 'status': 'done',
      'progress': 1, 'bytes': 10, 'error': null, 'quality': null,
    });
    expect(downloads.entry('episode:9')!.kind, 'episode');
    expect(await downloads.takeOver(), 1);
    final e = downloads.entry('episode:9')!;
    expect(e.dir, '${storage.dir.path}${sep}podcasts');
    expect(downloads.file('episode:9').lengthSync(), 10);
    expect(File('${old.path}/episode_9').existsSync(), isFalse);
  });

  test('✕ on a loading album keeps the finished titles: partly loaded (user 2026-11-07 "1 ja")', () async {
    const album = Item(key: 'jellyfin:1:a', kind: 'album', title: 'Kind of Blue', subtitle: 'Miles Davis');
    await downloads.add([for (final n in [1, 2, 3]) track(n, album: 'jellyfin:1:a')], album: album);
    server.gate('jellyfin:1:t1').complete();
    await settle(() => downloads.isOffline('jellyfin:1:t1'));
    await settle(() => downloads.running == 2);
    final g = downloads.groups.single;
    expect(g.section, 'loading');
    await downloads.cancelGroup(g);
    await settle(() => downloads.running == 0);
    expect(downloads.entries.map((e) => e.key), ['jellyfin:1:t1']);
    final after = downloads.groups.single;
    expect((after.total, after.section), (3, 'partial'));
    final music = Directory('${storage.dir.path}${sep}music');
    expect(music.listSync().map((f) => f.uri.pathSegments.last), ['jellyfin_1_t1']);
  });

  test('"Free" follows a deletion at once (Windows VM 2026-11-07)', () async {
    server.gate('episode:1').complete();
    await downloads.add([episode(1)]);
    await settle(() => downloads.isOffline('episode:1'));
    Storage.probe = (_) async => 101 * gb;
    await downloads.remove('episode:1');
    await settle(() => storage.free == 101 * gb);
    expect(storage.free, 101 * gb);
    Storage.probe = (_) async => 100 * gb;
  });

  test('0.1.x titles of one album become one line (user 2026-11-07 "1 ja")', () async {
    final old = Directory('${Stores.dir.path}/offline')..createSync(recursive: true);
    for (final n in [1, 2]) {
      final t = track(n, album: 'jellyfin:1:a');
      File('${old.path}/jellyfin_1_t$n').writeAsBytesSync(List.filled(10, 1));
      Stores.items.put(t.key, t.toJson());
      Stores.offline.put(t.key, {
        'key': t.key, 'title': t.title, 'subtitle': 'Miles Davis · Kind of Blue', 'added': '2026-01-0$n', 'status': 'done',
        'progress': 1, 'bytes': 10, 'error': null, 'quality': null,
      });
    }
    // A single title without album stays on its own line.
    File('${old.path}/jellyfin_1_t3').writeAsBytesSync(List.filled(10, 1));
    Stores.items.put(track(3).key, track(3).toJson());
    Stores.offline.put(track(3).key, {
      'key': track(3).key, 'title': 'T3', 'subtitle': '', 'added': '2026-01-03', 'status': 'done',
      'progress': 1, 'bytes': 10, 'error': null, 'quality': null,
    });
    api.online.value = false;
    await downloads.check();
    expect(downloads.groups.length, 2);
    final g = downloads.groups.firstWhere((g) => g.id == 'jellyfin:1:a');
    expect((g.entries.length, g.isAlbum, g.section), (2, true, 'done'));
    // Offline, no album artist yet: the artist from the titles' "artist · album" ("6 ja").
    expect(g.subtitle, 'Miles Davis');
    expect(downloads.file('jellyfin:1:t1').lengthSync(), 10);
    // Album title known from an entry saved later: filled at the next start.
    Stores.offline.put('jellyfin:1:t9', {
      ...Stores.offline.get('jellyfin:1:t1')!, 'key': 'jellyfin:1:t9', 'album_title': 'Kind of Blue', 'album_subtitle': 'Miles Davis',
    });
    expect(await downloads.fillAlbums(), 2);
    expect(downloads.groups.firstWhere((g) => g.id == 'jellyfin:1:a').title, 'Kind of Blue');
    expect(await downloads.fillAlbums(), 0);
  });

  test('"Change …" redirects only new downloads; saved ones keep their folder', () async {
    server.gate('episode:1').complete();
    await downloads.add([episode(1)]);
    await settle(() => downloads.isOffline('episode:1'));
    final before = downloads.file('episode:1').path;
    storage.dir = Directory('${tmp.path}${sep}other');
    await downloads.add([episode(2)]);
    expect(downloads.file('episode:1').path, before);
    expect(downloads.entry('episode:2')!.dir, '${tmp.path}${sep}other${sep}podcasts');
  });

  test('target checks: same folder, inside, writable, made when missing', () async {
    final root = Directory('${tmp.path}${sep}a')..createSync();
    expect(await Downloads.checkTarget(root, root), 'same');
    expect(await Downloads.checkTarget(root, Directory('${root.path}${sep}in')), 'inside');
    final deep = Directory('${tmp.path}${sep}b${sep}c');
    expect(await Downloads.checkTarget(root, deep), isNull);
    expect(deep.existsSync(), isTrue);
  });

  Future<void> saved(int n) async {
    final list = [for (var i = 1; i <= n; i++) episode(i)];
    for (final e in list) {
      server.gate(e.key).complete();
    }
    await downloads.add(list);
    await settle(() => downloads.entries.length == n && downloads.entries.every((e) => e.status == 'done'));
  }

  Future<void> moveCase(Directory target) async {
    await saved(3);
    final old = storage.dir.path;
    var reported = 0;
    final r = await downloads.moveTo(target, progress: (n) => reported = n);
    expect(r.complete, isTrue);
    expect(r.moved, 3);
    expect(reported, 3000);
    expect(storage.dir.path, target.absolute.path);
    for (final e in downloads.entries) {
      expect(e.dir, '${target.absolute.path}${sep}podcasts');
      expect(downloads.file(e.key).lengthSync(), 1000);
    }
    expect(Directory(old).existsSync(), isFalse); // empty old folders go
  }

  test('"Move to …" on the same drive (renamed)', () async {
    await moveCase(Directory('${tmp.path}${sep}moved'));
  });

  test('"Move to …" to another drive (copied, size checked, original deleted)', () async {
    final shm = Directory('/dev/shm');
    if (!shm.existsSync() || await Downloads.sameVolume(tmp, shm)) {
      markTestSkipped('no second drive here');
      return;
    }
    final target = Directory('${shm.path}/audiojoe-move-$pid');
    expect(await Downloads.sameVolume(storage.dir..createSync(recursive: true), shm), isFalse);
    try {
      await moveCase(target);
    } finally {
      if (target.existsSync()) target.deleteSync(recursive: true);
    }
  });

  test('"Move to …" stopped in the middle: list and files match, the folder stays', () async {
    await saved(3);
    final old = storage.dir.path;
    var calls = 0;
    final r = await downloads.moveTo(Directory('${tmp.path}${sep}half'), cancelled: () => ++calls > 1);
    expect((r.cancelled, r.moved), (true, 1));
    expect(storage.dir.path, old);
    for (final e in downloads.entries) {
      expect(downloads.file(e.key).existsSync(), isTrue, reason: e.key);
    }
    expect(downloads.entries.where((e) => e.dir!.startsWith('${tmp.path}${sep}half')).length, 1);
  });

  test('a failed copy leaves the original and no copy', () async {
    final src = File('${tmp.path}${sep}f')..writeAsBytesSync([1, 2, 3]);
    // The target's folder is a file: neither rename nor copy can work.
    File('${tmp.path}${sep}blocked').writeAsStringSync('');
    await expectLater(Downloads.moveFile(src, File('${tmp.path}${sep}blocked${sep}f')), throwsA(isA<FileSystemException>()));
    expect(src.existsSync(), isTrue);
  });

  test('"Delete after listening": podcasts on, audiobooks off by default; not while playing', () async {
    expect((storage.deleteAfter('episode'), storage.deleteAfter('book'), storage.deleteAfter('track')), (true, false, false));
    await saved(2);
    Stores.items.put(book.key, book.toJson());
    Stores.offline.put(book.key, OfflineEntry(book.key, 'Book', '', '2026-01-01', status: 'done', kind: 'book', dir: tmp.path).toJson());
    for (final k in ['episode:1', 'episode:2', book.key]) {
      Stores.positions.put(k, {'key': k, 'position_ms': 1000, 'finished': true, 'updated_at': '2026-01-01'});
    }
    expect(await downloads.sweepPlayed(playing: 'episode:2'), 1);
    expect(downloads.entries.map((e) => e.key).toSet(), {'episode:2', book.key});
    storage.setDeleteAfter('book', true);
    expect(await downloads.sweepPlayed(), 2);
    expect(downloads.entries, isEmpty);
    expect(storage.keepFreeGb, 5); // the other settings stay
  });
}
