// Downloads ("Ablage", 0.2.0, user 2026-11-07): a queue with at most two downloads at a time into
// the sub-folders podcasts, audiobooks and music of the storage folder (storage.dart). Every
// entry keeps the folder of its files, so "Change …" only redirects new downloads ("12 ja") and
// "Move to …" updates the entries file by file (as tvjoe, crates/tvjoe-gui/src/umzug.rs).
//
// A download is written to "<name>.part" in its folder and gets its final name only after it
// arrived completely ("8 nein, erst nach dem erfolgreichen download"); interrupted downloads
// resume with Range requests, files that disappeared are fetched again. Below "Keep at least …
// free" no download starts and nothing new is queued. "Delete after listening" removes finished
// podcast episodes and audiobooks that do not play (user "14 ja"). An album and an audiobook are
// one entry in the list (groups) and are deleted whole; a started album can load the rest.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'cache.dart';
import 'models.dart';
import 'storage.dart';
import 'store.dart';

/// Sub-folder of the storage folder per kind ("9 ja").
const subDirs = {'episode': 'podcasts', 'book': 'audiobooks', 'track': 'music'};

/// Downloads at the same time (as tvjoe, `ablage.rs` line 29: `PARALLEL = 2`).
const parallelDownloads = 2;

class OfflineEntry {
  final String key, title, subtitle, added;
  String status; // queued | loading | done | error | missing
  double progress;
  int bytes;
  String? error;
  final Quality? quality;
  /// track | episode | book
  final String kind;
  /// Folder of the entry's files; null for entries of 0.1.x not yet taken over.
  String? dir;
  /// Music: the album (key, title, artist, number of titles when known).
  final String? album, albumTitle, albumSubtitle;
  final int? albumCount;

  OfflineEntry(this.key, this.title, this.subtitle, this.added,
      {this.status = 'queued',
      this.progress = 0,
      this.bytes = 0,
      this.error,
      this.quality,
      this.kind = 'track',
      this.dir,
      this.album,
      this.albumTitle,
      this.albumSubtitle,
      this.albumCount});

  static OfflineEntry fromJson(Map<String, dynamic> j) => OfflineEntry(
      j['key'] as String, j['title'] as String, j['subtitle'] as String, j['added'] as String,
      status: j['status'] as String,
      progress: (j['progress'] as num).toDouble(),
      bytes: j['bytes'] as int,
      error: j['error'] as String?,
      quality: Quality.fromJson(j['quality']),
      kind: (j['kind'] ?? _kindOf(j['key'] as String)) as String,
      dir: j['dir'] as String?,
      album: j['album'] as String?,
      albumTitle: j['album_title'] as String?,
      albumSubtitle: j['album_subtitle'] as String?,
      albumCount: j['album_count'] as int?);

  Map<String, dynamic> toJson() => {
        'key': key, 'title': title, 'subtitle': subtitle, 'added': added, 'status': status,
        'progress': progress, 'bytes': bytes, 'error': error, 'quality': quality?.toJson(),
        'kind': kind, 'dir': dir, 'album': album, 'album_title': albumTitle,
        'album_subtitle': albumSubtitle, 'album_count': albumCount,
      };

  /// Entries of 0.1.x have no kind: it comes from the saved item.
  static String _kindOf(String key) {
    final it = Stores.items.get(key);
    if (it != null) return Item.fromJson(it).kind;
    return key.startsWith('episode:') ? 'episode' : 'track';
  }
}

/// One line of the "Downloads" view: an album, an audiobook, an episode or a single title.
class DownloadGroup {
  /// The album key, else the entry key.
  final String id;
  final String kind, title, subtitle;
  final List<OfflineEntry> entries;
  /// Music: number of titles of the album when known.
  final int? total;

  DownloadGroup(this.id, this.kind, this.title, this.subtitle, this.entries, this.total);

  bool get isAlbum => kind == 'track' && total != null || entries.length > 1;

  /// loading | waiting | partial | done – the sections of the view.
  String get section {
    if (entries.any((e) => e.status == 'loading')) return 'loading';
    if (entries.any((e) => e.status == 'queued' || e.status == 'missing')) return 'waiting';
    if (entries.any((e) => e.status == 'error')) return 'partial';
    if (total != null && entries.length < total!) return 'partial';
    return 'done';
  }

  int get bytes => entries.fold(0, (s, e) => s + e.bytes);

  /// Loaded share of what is queued here (by entries; a loading entry by its progress).
  double get progress =>
      entries.isEmpty ? 0 : entries.fold<double>(0, (s, e) => s + (e.status == 'done' ? 1 : e.status == 'loading' ? e.progress : 0)) / entries.length;

  int get doneCount => entries.where((e) => e.status == 'done').length;

  /// Newest addition first in each section.
  String get added => entries.map((e) => e.added).reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
}

/// Result of "Move to …".
class MoveResult {
  final int moved;
  final bool cancelled;
  final String? error;
  const MoveResult(this.moved, {this.cancelled = false, this.error});
  bool get complete => !cancelled && error == null;
}

class Downloads extends ChangeNotifier {
  Downloads._();
  static final instance = Downloads._();

  /// Folder of the saved covers and of 0.1.x downloads: in the app's data ("11 ja").
  Directory get _appDir => Directory('${Stores.dir.path}/offline');

  /// Folder of an entry's files: its own, else (0.1.x, not yet taken over) the old one.
  String _dirOf(String key) => Stores.offline.get(key)?['dir'] as String? ?? _appDir.path;

  static String _safe(String key) => key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// File of an item (or of one part of a multi-file book); names from the key ("10 ja").
  File file(String key, [int? part]) => _fileIn(_dirOf(key), key, part);

  static File _fileIn(String dir, String key, [int? part]) =>
      File('$dir${Platform.pathSeparator}${_safe(key)}${part == null ? '' : '_$part'}');

  /// Saved cover for an image path of the server (`Item.image`, `coverOf`), so it shows offline.
  File cover(String image) => File('${_appDir.path}/img_${_safe(image)}');

  /// The saved cover if there is one (checked synchronously: covers are built often, the files are small).
  File? coverFile(String? image) {
    if (image == null) return null;
    final f = cover(image);
    return f.existsSync() ? f : null;
  }

  /// Saves the item's cover under its own image path and under `/api/v1/image/<key>` (lists use
  /// that one); a missing cover (404) or an error is no reason to fail the download.
  Future<void> _saveCover(Item it) async {
    final own = '/api/v1/image/${Uri.encodeComponent(it.key)}';
    final paths = {it.image ?? own, own};
    try {
      final res = await api.client.get(api.imageUri(it.image ?? own), headers: api.authHeaders).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return;
      await _appDir.create(recursive: true);
      for (final p in paths) {
        await cover(p).writeAsBytes(res.bodyBytes, flush: true);
      }
    } catch (_) {}
  }

  List<OfflineEntry> get entries =>
      Stores.offline.data.values.map(OfflineEntry.fromJson).toList()..sort((a, b) => b.added.compareTo(a.added));

  OfflineEntry? entry(String key) {
    final j = Stores.offline.get(key);
    return j == null ? null : OfflineEntry.fromJson(j);
  }

  bool isOffline(String key) => entry(key)?.status == 'done';

  void _save(OfflineEntry e) {
    Stores.offline.put(e.key, e.toJson());
    notifyListeners();
  }

  /// The view's lines: titles of one album together, everything else on its own.
  List<DownloadGroup> get groups {
    final albums = <String, List<OfflineEntry>>{};
    final out = <DownloadGroup>[];
    for (final e in entries) {
      if (e.kind == 'track' && e.album != null) {
        albums.putIfAbsent(e.album!, () => []).add(e);
      } else {
        out.add(DownloadGroup(e.key, e.kind, e.title, e.subtitle, [e], null));
      }
    }
    albums.forEach((album, list) {
      list.sort((a, b) => a.added.compareTo(b.added));
      final info = list.firstWhere((e) => e.albumTitle != null, orElse: () => list.first);
      final count = list.map((e) => e.albumCount).whereType<int>().fold<int?>(null, (m, n) => m == null || n > m ? n : m);
      out.add(DownloadGroup(album, 'track', info.albumTitle ?? info.title, info.albumSubtitle ?? info.subtitle, list, count));
    });
    out.sort((a, b) => b.added.compareTo(a.added));
    return out;
  }

  /// Said when a download was asked for below the limit (the app shows "Waiting for space").
  final refused = StreamController<void>.broadcast();

  /// Queues the items; false (nothing queued) when the free space is below the limit. `album`:
  /// the album page's album when `items` are all its titles.
  Future<bool> add(List<Item> items, {Item? album}) async {
    await storage.refresh();
    if (storage.low) {
      refused.add(null);
      return false;
    }
    final root = storage.dir.path;
    final albums = <String, ({String? title, String? subtitle, int? count})>{};
    for (var it in items.where((i) => const ['track', 'episode', 'book'].contains(i.kind))) {
      if (entry(it.key) != null) continue;
      if (it.kind == 'book' && it.parts.isEmpty) {
        try {
          it = Item.fromJson((await api.call('GET', '/items/${Uri.encodeComponent(it.key)}') as Map).cast<String, dynamic>());
        } catch (_) {
          continue;
        }
      }
      final a = it.kind == 'track' && it.album != null
          ? albums[it.album!] ??= await _albumInfo(it.album!, album, items.where((x) => x.album == it.album).length)
          : null;
      Stores.items.put(it.key, it.toJson());
      _save(OfflineEntry(it.key, it.title, it.subtitle, DateTime.now().toUtc().toIso8601String(),
          quality: it.quality,
          kind: it.kind,
          dir: '$root${Platform.pathSeparator}${subDirs[it.kind]}',
          album: it.kind == 'track' ? it.album : null,
          albumTitle: a?.title,
          albumSubtitle: a?.subtitle,
          albumCount: a?.count));
    }
    unawaited(_pump());
    return true;
  }

  /// Title, artist and number of titles of an album: from the album page, from entries saved
  /// before, else from the server (nothing when it cannot be asked).
  Future<({String? title, String? subtitle, int? count})> _albumInfo(String key, Item? album, int given) async {
    if (album != null && album.key == key) return (title: album.title, subtitle: album.subtitle, count: given);
    final known = entries.where((e) => e.album == key && e.albumTitle != null).firstOrNull;
    if (known != null) return (title: known.albumTitle, subtitle: known.albumSubtitle, count: known.albumCount);
    String? title, subtitle;
    int? count;
    if (api.online.value) {
      try {
        final j = (await api.call('GET', '/items/${Uri.encodeComponent(key)}') as Map).cast<String, dynamic>();
        title = j['title'] as String?;
        subtitle = j['subtitle'] as String?;
      } catch (_) {}
      try {
        final all = await albumTracksOf(key);
        if (all.isNotEmpty) count = all.length;
      } catch (_) {}
    }
    return (title: title, subtitle: subtitle, count: count);
  }

  /// Keys removed while loading: their download stops and leaves no file.
  final _cancelled = <String>{};

  Future<void> remove(String key) async {
    final dir = _dirOf(key);
    final it = Stores.items.get(key);
    final parts = it == null ? const <Part>[] : Item.fromJson(it).parts;
    final image = it == null ? null : Item.fromJson(it).image;
    final own = '/api/v1/image/${Uri.encodeComponent(key)}';
    // A podcast's cover can belong to several saved episodes: it goes with the last of them.
    final shared = image != null &&
        entries.any((e) => e.key != key && Stores.items.get(e.key) != null && Item.fromJson(Stores.items.get(e.key)!).image == image);
    if (_active.contains(key)) _cancelled.add(key);
    Stores.offline.remove(key);
    notifyListeners();
    final files = [_fileIn(dir, key), for (final p in parts) _fileIn(dir, key, p.index)];
    for (final f in [...files, for (final f in files) File('${f.path}.part'), cover(own), if (image != null && !shared) cover(image)]) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {
        // In use (Windows) or gone meanwhile: what is left is not listed any more.
      }
    }
  }

  /// Deletes a line of the view: the whole album or audiobook.
  Future<void> removeGroup(DownloadGroup g) async {
    for (final e in g.entries) {
      await remove(e.key);
    }
  }

  /// "Load the rest": the missing titles of a started album, and what failed.
  Future<void> loadRest(DownloadGroup g) async {
    retry(g.entries.map((e) => e.key));
    if (g.kind != 'track' || g.total == null || g.entries.length >= g.total!) return;
    final all = await albumTracksOf(g.id);
    final first = g.entries.first;
    await add([for (final it in all) if (entry(it.key) == null) it],
        album: Item(key: g.id, kind: 'album', title: first.albumTitle ?? g.title, subtitle: first.albumSubtitle ?? g.subtitle));
  }

  final _active = <String>{};
  bool _pumping = false;

  /// Starts downloads until two run; oldest first.
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_active.length < parallelDownloads && api.online.value) {
        final next = entries.reversed
            .where((e) => (e.status == 'queued' || e.status == 'missing') && !_active.contains(e.key))
            .firstOrNull;
        if (next == null) break;
        // Below the limit the rest waits (it starts again with the next download asked for).
        await storage.refresh();
        if (storage.low) break;
        _active.add(next.key);
        unawaited(_fetch(next).whenComplete(() {
          _active.remove(next.key);
          _cancelled.remove(next.key);
          unawaited(_pump());
        }));
      }
    } finally {
      _pumping = false;
    }
  }

  /// Whether a download runs or waits (then the storage folder cannot be moved, "13 ja").
  bool get busy => _active.isNotEmpty || entries.any((e) => e.status == 'queued' || e.status == 'missing' || e.status == 'loading');

  /// Downloads running now.
  int get running => _active.length;

  Future<void> _fetch(OfflineEntry e) async {
    e
      ..status = 'loading'
      ..progress = 0
      ..dir ??= '${storage.dir.path}${Platform.pathSeparator}${subDirs[e.kind]}';
    _save(e);
    final it = Stores.items.get(e.key) == null ? null : Item.fromJson(Stores.items.get(e.key)!);
    final parts = it != null && it.multiPart ? it.parts : null;
    final total = parts?.fold<int>(0, (s, p) => s + p.durationMs) ?? 1;
    var done = 0.0, bytes = 0;
    var shown = DateTime.now();
    try {
      await Directory(e.dir!).create(recursive: true);
    } catch (err) {
      e
        ..status = 'error'
        ..error = '$err';
      return _save(e);
    }
    if (it != null) await _saveCover(it);
    for (final p in parts ?? const <Part?>[null]) {
      final share = p == null ? 1.0 : p.durationMs / total;
      // Parts finished before (restart, retry) are kept.
      final have = _fileIn(e.dir!, e.key, p?.index);
      if (p != null && await have.exists()) {
        bytes += await have.length();
        done += share;
        continue;
      }
      try {
        final n = await _download(api.streamUri(e.key, part: p?.index), have, () => _cancelled.contains(e.key), (b, t) {
          e
            ..progress = done + (t > 0 ? b / t * share : 0)
            ..bytes = bytes + b;
          // The list reads the store: write it there, at most twice a second.
          // (Not after a removal: that would bring the entry back.)
          if (DateTime.now().difference(shown).inMilliseconds >= 500 && Stores.offline.get(e.key) != null) {
            shown = DateTime.now();
            _save(e);
          }
        });
        bytes += n;
        done += share;
      } catch (err) {
        if (entry(e.key) == null) return; // removed meanwhile
        e
          ..status = 'error'
          ..error = '$err';
        return _save(e);
      }
    }
    if (entry(e.key) == null) return;
    e
      ..status = 'done'
      ..progress = 1
      ..bytes = bytes;
    _save(e);
  }

  /// Downloads into `target` through `target.part`, resuming a partial file; the final name
  /// only after the whole file arrived. Returns the size.
  Future<int> _download(Uri uri, File target, bool Function() cancelled, void Function(int, int) progress) async {
    final part = File('${target.path}.part');
    for (var attempt = 1;; attempt++) {
      final have = await part.exists() ? await part.length() : 0;
      try {
        final req = http.Request('GET', uri)..headers.addAll(api.authHeaders);
        if (have > 0) req.headers['range'] = 'bytes=$have-';
        final res = await api.client.send(req).timeout(const Duration(seconds: 30));
        if (res.statusCode == 416) break; // already complete
        if (res.statusCode != 200 && res.statusCode != 206) throw ApiError(res.statusCode, 'HTTP ${res.statusCode}');
        final append = res.statusCode == 206;
        final total = append
            ? int.tryParse(RegExp(r'/(\d+)$').firstMatch(res.headers['content-range'] ?? '')?.group(1) ?? '') ?? 0
            : res.contentLength ?? 0;
        final sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
        var got = append ? have : 0;
        try {
          // Stalled connections are aborted after 30 s without data and resumed.
          await for (final chunk in res.stream.timeout(const Duration(seconds: 30))) {
            if (cancelled()) throw const _Cancelled();
            sink.add(chunk);
            got += chunk.length;
            progress(got, total);
          }
        } finally {
          await sink.close();
        }
        if (total > 0 && got < total) throw ApiError(0, 'short body $got/$total');
        break;
      } on _Cancelled {
        try {
          await part.delete();
        } catch (_) {}
        rethrow;
      } catch (e) {
        if (attempt >= 8 || cancelled()) rethrow;
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }
    await part.rename(target.path);
    return target.length();
  }

  /// After start: downloads of 0.1.x move into the sub-folders ("5 ja"), files that disappeared
  /// are marked and fetched again, finished episodes and books are deleted where switched on.
  Future<void> check() async {
    await takeOver();
    for (final e in entries) {
      if (e.status == 'loading') e.status = 'queued';
      if (e.status == 'done') {
        final it = Stores.items.get(e.key);
        final parts = it == null ? const <Part>[] : Item.fromJson(it).parts;
        final files = parts.length > 1 ? [for (final p in parts) file(e.key, p.index)] : [file(e.key)];
        for (final f in files) {
          if (!await f.exists()) e.status = 'missing';
        }
      }
      Stores.offline.put(e.key, e.toJson());
    }
    notifyListeners();
    api.online.addListener(() => api.online.value ? unawaited(_pump()) : null);
    unawaited(_pump());
    unawaited(_missingCovers());
  }

  /// Moves the downloads of 0.1.x (one folder "offline" in the app's data) into the sub-folders
  /// of the storage folder, entry by entry; an entry's folder changes only once its files moved.
  /// What fails stays where it is and is tried again at the next start.
  Future<int> takeOver() async {
    var moved = 0;
    final root = storage.dir.path;
    for (final e in entries.where((e) => e.dir == null)) {
      final to = '$root${Platform.pathSeparator}${subDirs[e.kind]}';
      try {
        for (final (src, dst) in _filesOf(e, _appDir.path, to)) {
          await moveFile(src, dst);
        }
      } catch (_) {
        continue;
      }
      final now = entry(e.key);
      if (now == null) continue;
      now.dir = to;
      _save(now);
      moved++;
    }
    return moved;
  }

  /// An entry's files (whole file, parts, partial downloads) that exist, as (from, to) pairs.
  List<(File, File)> _filesOf(OfflineEntry e, String from, String to) {
    final it = Stores.items.get(e.key);
    final parts = it == null ? const <Part>[] : Item.fromJson(it).parts;
    final names = [null, for (final p in parts) p.index];
    return [
      for (final n in names) ...[
        (_fileIn(from, e.key, n), _fileIn(to, e.key, n)),
        (File('${_fileIn(from, e.key, n).path}.part'), File('${_fileIn(to, e.key, n).path}.part')),
      ]
    ].where((p) => p.$1.existsSync()).toList();
  }

  /// One file: renamed (same drive), else copied, its size checked and only then the original
  /// deleted; a failed copy leaves the original and no copy (as tvjoe, `umzug.rs` `move_file`).
  static Future<void> moveFile(File src, File dst, [void Function(int bytes)? progress]) async {
    await dst.parent.create(recursive: true);
    final len = await src.length();
    try {
      await src.rename(dst.path);
      progress?.call(len);
      return;
    } on FileSystemException {
      // Another drive: copy.
    }
    try {
      final out = dst.openWrite();
      try {
        await for (final chunk in src.openRead()) {
          out.add(chunk);
          progress?.call(chunk.length);
        }
        await out.flush();
      } finally {
        await out.close();
      }
      if (await dst.length() != len) throw FileSystemException('size differs after copying', dst.path);
    } catch (_) {
      try {
        await dst.delete();
      } catch (_) {}
      rethrow;
    }
    await src.delete();
  }

  /// Why `target` cannot take the storage folder, or null: not the same folder, not inside it,
  /// writable (a missing folder is made).
  static Future<String?> checkTarget(Directory old, Directory target) async {
    String canon(Directory d) {
      try {
        return d.resolveSymbolicLinksSync();
      } catch (_) {
        return d.absolute.path;
      }
    }
    final sep = Platform.pathSeparator;
    try {
      await target.create(recursive: true);
    } catch (e) {
      return 'cannot create';
    }
    final o = canon(old), n = canon(target);
    if (o == n) return 'same';
    if (n.startsWith('$o$sep')) return 'inside';
    final probe = File('$n$sep.audiojoe-probe');
    try {
      await probe.writeAsBytes(const []);
      await probe.delete();
    } catch (_) {
      return 'not writable';
    }
    return null;
  }

  /// Whether `a` and `b` are on the same drive: a file made in `a` can be renamed into `b`
  /// (tvjoe compares device numbers, which Dart does not show). Without files at `a` it does
  /// not matter, so true.
  static Future<bool> sameVolume(Directory a, Directory b) async {
    if (!await a.exists()) return true;
    final sep = Platform.pathSeparator;
    final probe = File('${a.path}$sep.audiojoe-probe');
    final there = '${b.path}$sep.audiojoe-probe';
    try {
      await probe.writeAsBytes(const []);
      await probe.rename(there);
      await File(there).delete();
      return true;
    } catch (_) {
      try {
        await probe.delete();
      } catch (_) {}
      return false;
    }
  }

  /// Bytes of the files under the storage folder that "Move to …" takes along.
  int get bytesToMove {
    final root = storage.dir.path;
    var n = 0;
    for (final e in entries.where((e) => e.dir != null && _under(e.dir!, root))) {
      for (final (src, _) in _filesOf(e, e.dir!, e.dir!)) {
        n += src.lengthSync();
      }
    }
    return n;
  }

  static bool _under(String dir, String root) => dir == root || dir.startsWith('$root${Platform.pathSeparator}');

  /// "Move to …": every entry under the storage folder goes to the same place under `target`;
  /// after each entry its new folder is saved, so a stop or an error leaves files and list
  /// matching. Only when all moved does `target` become the storage folder; empty old folders go.
  Future<MoveResult> moveTo(Directory target, {void Function(int done)? progress, bool Function()? cancelled}) async {
    final root = storage.dir.path;
    final to = target.absolute.path;
    var moved = 0, done = 0;
    for (final e in entries.where((e) => e.dir != null && _under(e.dir!, root))) {
      if (cancelled?.call() ?? false) return MoveResult(moved, cancelled: true);
      final dir = '$to${e.dir!.substring(root.length)}';
      try {
        for (final (src, dst) in _filesOf(e, e.dir!, dir)) {
          await moveFile(src, dst, (n) => progress?.call(done += n));
        }
      } catch (err) {
        return MoveResult(moved, error: '$err');
      }
      final now = entry(e.key);
      if (now != null) {
        now.dir = dir;
        _save(now);
      }
      moved++;
    }
    for (final sub in subDirs.values) {
      try {
        await Directory('$root${Platform.pathSeparator}$sub').delete();
      } catch (_) {}
    }
    try {
      await Directory(root).delete();
    } catch (_) {}
    storage.dir = Directory(to);
    unawaited(storage.refresh());
    return MoveResult(moved);
  }

  /// "Delete after listening": finished episodes and audiobooks that do not play (`playing`).
  Future<int> sweepPlayed({String? playing}) async {
    var n = 0;
    for (final e in entries.where((e) => e.status == 'done' && storage.deleteAfter(e.kind) && e.key != playing)) {
      if (Stores.positions.get(e.key)?['finished'] == true) {
        await remove(e.key);
        n++;
      }
    }
    return n;
  }

  /// Titles saved before covers were saved (up to 0.1.8) get theirs once the server answers.
  Future<void> _missingCovers() async {
    if (!api.online.value) return;
    for (final e in entries.where((e) => e.status == 'done')) {
      final j = Stores.items.get(e.key);
      if (j == null || coverFile('/api/v1/image/${Uri.encodeComponent(e.key)}') != null) continue;
      await _saveCover(Item.fromJson(j));
    }
    notifyListeners();
  }

  /// Fetches failed entries again (all, or those of `keys`).
  void retry([Iterable<String>? keys]) {
    final only = keys?.toSet();
    for (final e in entries.where((e) => e.status == 'error' && (only == null || only.contains(e.key)))) {
      e.status = 'queued';
      Stores.offline.put(e.key, e.toJson());
    }
    notifyListeners();
    unawaited(_pump());
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

final downloads = Downloads.instance;
