// Offline titles: download queue into the app's data directory. Interrupted downloads
// resume with Range requests; files that disappeared are fetched again. Below "Keep at least …
// free" (storage.dart) no download starts and nothing new is queued.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'models.dart';
import 'storage.dart';
import 'store.dart';

class OfflineEntry {
  final String key, title, subtitle, added;
  String status; // queued | loading | done | error | missing
  double progress;
  int bytes;
  String? error;
  final Quality? quality;

  OfflineEntry(this.key, this.title, this.subtitle, this.added,
      {this.status = 'queued', this.progress = 0, this.bytes = 0, this.error, this.quality});

  static OfflineEntry fromJson(Map<String, dynamic> j) => OfflineEntry(
      j['key'] as String, j['title'] as String, j['subtitle'] as String, j['added'] as String,
      status: j['status'] as String,
      progress: (j['progress'] as num).toDouble(),
      bytes: j['bytes'] as int,
      error: j['error'] as String?,
      quality: Quality.fromJson(j['quality']));

  Map<String, dynamic> toJson() => {
        'key': key, 'title': title, 'subtitle': subtitle, 'added': added, 'status': status,
        'progress': progress, 'bytes': bytes, 'error': error, 'quality': quality?.toJson(),
      };
}

class Downloads extends ChangeNotifier {
  Downloads._();
  static final instance = Downloads._();

  Directory get _dir => Directory('${Stores.dir.path}/offline');

  /// File of an item (or of one part of a multi-file book).
  File file(String key, [int? part]) {
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File('${_dir.path}/$safe${part == null ? '' : '_$part'}');
  }

  /// Saved cover for an image path of the server (`Item.image`, `coverOf`), so it shows offline.
  File cover(String image) => File('${_dir.path}/img_${image.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}');

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

  /// Said when a download was asked for below the limit (the app shows "Waiting for space").
  final refused = StreamController<void>.broadcast();

  /// Queues the items; false (nothing queued) when the free space is below the limit.
  Future<bool> add(List<Item> items) async {
    await storage.refresh();
    if (storage.low) {
      refused.add(null);
      return false;
    }
    for (var it in items.where((i) => const ['track', 'episode', 'book'].contains(i.kind))) {
      if (entry(it.key) != null) continue;
      if (it.kind == 'book' && it.parts.isEmpty) {
        try {
          it = Item.fromJson((await api.call('GET', '/items/${Uri.encodeComponent(it.key)}') as Map).cast<String, dynamic>());
        } catch (_) {
          continue;
        }
      }
      Stores.items.put(it.key, it.toJson());
      _save(OfflineEntry(it.key, it.title, it.subtitle, DateTime.now().toUtc().toIso8601String(), quality: it.quality));
    }
    unawaited(_process());
    return true;
  }

  Future<void> remove(String key) async {
    final it = Stores.items.get(key);
    final parts = it == null ? const <Part>[] : Item.fromJson(it).parts;
    final image = it == null ? null : Item.fromJson(it).image;
    final own = '/api/v1/image/${Uri.encodeComponent(key)}';
    // A podcast's cover can belong to several saved episodes: it goes with the last of them.
    final shared = image != null &&
        entries.any((e) => e.key != key && Stores.items.get(e.key) != null && Item.fromJson(Stores.items.get(e.key)!).image == image);
    for (final f in [file(key), for (final p in parts) file(key, p.index), cover(own), if (image != null && !shared) cover(image)]) {
      if (await f.exists()) await f.delete();
    }
    Stores.offline.remove(key);
    notifyListeners();
  }

  bool _running = false;
  Future<void> _process() async {
    if (_running) return;
    _running = true;
    try {
      while (api.online.value) {
        final next = entries.where((e) => e.status == 'queued' || e.status == 'missing').firstOrNull;
        if (next == null) break;
        // Below the limit the rest waits (it starts again with the next download asked for).
        await storage.refresh();
        if (storage.low) break;
        await _fetch(next);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _fetch(OfflineEntry e) async {
    e
      ..status = 'loading'
      ..progress = 0;
    _save(e);
    final it = Stores.items.get(e.key) == null ? null : Item.fromJson(Stores.items.get(e.key)!);
    final parts = it != null && it.multiPart ? it.parts : null;
    final total = parts?.fold<int>(0, (s, p) => s + p.durationMs) ?? 1;
    var done = 0.0, bytes = 0;
    var shown = DateTime.now();
    await _dir.create(recursive: true);
    if (it != null) await _saveCover(it);
    for (final p in parts ?? const <Part?>[null]) {
      final share = p == null ? 1.0 : p.durationMs / total;
      // Parts finished before (restart, retry) are kept.
      final have = file(e.key, p?.index);
      if (p != null && await have.exists()) {
        bytes += await have.length();
        done += share;
        continue;
      }
      try {
        final n = await _download(api.streamUri(e.key, part: p?.index), file(e.key, p?.index), (b, t) {
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

  /// Downloads into `target`, resuming a partial file; returns the size.
  Future<int> _download(Uri uri, File target, void Function(int, int) progress) async {
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
        // Stalled connections are aborted after 30 s without data and resumed.
        await for (final chunk in res.stream.timeout(const Duration(seconds: 30))) {
          sink.add(chunk);
          got += chunk.length;
          progress(got, total);
        }
        await sink.close();
        if (total > 0 && got < total) throw ApiError(0, 'short body $got/$total');
        break;
      } catch (e) {
        if (attempt >= 8) rethrow;
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }
    await part.rename(target.path);
    return target.length();
  }

  /// After start: files that disappeared are marked and fetched again.
  Future<void> check() async {
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
    api.online.addListener(() => api.online.value ? unawaited(_process()) : null);
    unawaited(_process());
    unawaited(_missingCovers());
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

  void retry() {
    for (final e in entries.where((e) => e.status == 'error')) {
      e.status = 'queued';
      Stores.offline.put(e.key, e.toJson());
    }
    unawaited(_process());
  }
}

final downloads = Downloads.instance;
