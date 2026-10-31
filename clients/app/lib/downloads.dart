// Offline titles: download queue into the app's data directory. Interrupted downloads
// resume with Range requests; files that disappeared are fetched again.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'models.dart';
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

  Future<void> add(List<Item> items) async {
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
  }

  Future<void> remove(String key) async {
    final it = Stores.items.get(key);
    final parts = it == null ? const <Part>[] : Item.fromJson(it).parts;
    for (final f in [file(key), for (final p in parts) file(key, p.index)]) {
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
    await _dir.create(recursive: true);
    for (final p in parts ?? const <Part?>[null]) {
      final share = p == null ? 1.0 : p.durationMs / total;
      try {
        final n = await _download(api.streamUri(e.key, part: p?.index), file(e.key, p?.index), (b, t) {
          e
            ..progress = done + (t > 0 ? b / t * share : 0)
            ..bytes = bytes + b;
          notifyListeners();
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
