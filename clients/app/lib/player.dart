// Playback: from the offline copy when available, else streamed from the server.
// Books may consist of several files; positions are always positions in the whole item.
// Saves positions locally and to the server; follows other devices while paused.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;

import 'api.dart';
import 'downloads.dart';
import 'models.dart';
import 'store.dart';
import 'sync.dart';

/// The continue-list entry being played (an album for music): its successor plays next.
typedef Entry = ({String list, String key});

class Player extends ChangeNotifier {
  Player._() {
    audio.playerStateStream.listen(_onState);
    audio.positionStream.listen((_) {
      _checkSleep();
      notifyListeners();
    });
    audio.currentIndexStream.listen((_) => notifyListeners());
    sync.remote.listen(_onRemote);
  }
  static final instance = Player._();

  // Headers (session token) go straight to the platform player: just_audio's default local
  // proxy needs cleartext HTTP to 127.0.0.1, which Android blocks.
  final audio = AudioPlayer(useProxyForRequestHeaders: false);
  Item? item;
  List<Item> queue = [];
  int index = 0;
  bool fromCache = false;
  ({String device, String at})? takenOver;
  double rate = 1;
  Timer? _saveTimer;
  Entry? entry;
  /// Set by the UI: what plays after [entry] (asked before the item is saved as finished).
  Future<Future<void> Function()?> Function(Entry e)? nextAfter;

  static Entry? entryOf(Item it) => it.kind == 'episode'
      ? (list: 'podcasts', key: it.key)
      : it.kind == 'book'
          ? (list: 'books', key: it.key)
          : null;

  // Sleep timer: pause at a time, or at the end of the current chapter or item.
  DateTime? sleepAt;
  String? sleepAtEnd; // 'chapter' | 'item'
  String _sleepChapter = '';

  List<Part> get _parts => item?.multiPart == true ? item!.parts : const [];
  int get _part => _parts.isEmpty ? 0 : (audio.currentIndex ?? 0);

  // Ready after a start, paused, nothing loaded until play is pressed (a live stream would keep loading).
  bool _cued = false;
  int _cuedMs = 0;

  int get position => _cued ? _cuedMs : (_parts.isEmpty ? 0 : _parts[_part].startMs) + audio.position.inMilliseconds;
  int get duration => _parts.isNotEmpty ? (item?.durationMs ?? 0) : (audio.duration?.inMilliseconds ?? item?.durationMs ?? 0);
  bool get playing => audio.playing;
  bool get live => item?.kind == 'radio';

  List<Chapter> get chapters => item?.chapters ?? const [];

  /// Index of the chapter at the position, -1 without chapters.
  int get chapterIndex {
    final ms = position, l = chapters;
    for (var i = l.length - 1; i >= 0; i--) {
      if (ms >= l[i].startMs) return i;
    }
    return l.isEmpty ? -1 : 0;
  }

  String get chapter {
    final i = chapterIndex;
    return i < 0 ? '' : chapters[i].title;
  }

  /// "Chapter 3/11 · Name"; empty without chapters.
  String get chapterLine => chapterIndex < 0 ? '' : '${chapterIndex + 1}/${chapters.length} · $chapter';

  /// Next chapter; after the last one the next item, if any.
  Future<void> nextChapter() async {
    final i = chapterIndex;
    if (i >= 0 && i + 1 < chapters.length) return seekTo(chapters[i + 1].startMs);
    if (index + 1 < queue.length) return skip(1);
  }

  /// Start of the chapter; within its first 3 seconds the previous chapter.
  Future<void> previousChapter() async {
    final i = chapterIndex;
    if (i < 0) return index > 0 ? skip(-1) : seekTo(0);
    final c = chapters[i];
    return seekTo(position - c.startMs < 3000 && i > 0 ? chapters[i - 1].startMs : c.startMs);
  }

  /// Metadata for an item: from the server, else from the local copy (offline).
  Future<Item?> meta(String key) async {
    if (api.online.value) {
      try {
        final j = (await api.call('GET', '/items/${Uri.encodeComponent(key)}') as Map).cast<String, dynamic>();
        Stores.items.put(key, Item.fromJson(j).toJson());
        return Item.fromJson(j);
      } catch (_) {}
    }
    final j = Stores.items.get(key);
    return j == null ? null : Item.fromJson(j);
  }

  Future<void> play(List<Item> items, [int i = 0, Entry? from]) async {
    await _persist();
    // Episodes and books are list entries themselves; music only when played as an album entry.
    entry = from ?? entryOf(items[i]);
    final full = await meta(items[i].key);
    queue = [...items];
    if (full != null) queue[i] = full;
    index = i;
    await _load(queue[i]);
    // just_audio's play() completes only when playback stops: do not wait for it.
    unawaited(audio.play());
  }

  AudioSource _source(Item it, int? part) {
    final tag = MediaItem(
      id: '${it.key}${part == null ? '' : '#$part'}',
      title: it.title,
      artist: it.subtitle,
      album: 'audiojoe',
      artUri: it.image == null ? null : api.imageUri(it.image!),
      artHeaders: api.authHeaders,
    );
    if (fromCache) return AudioSource.file(downloads.file(it.key, part).path, tag: tag);
    return AudioSource.uri(api.streamUri(it.key, part: part), headers: api.authHeaders, tag: tag);
  }

  Future<void> _load(Item it) async {
    item = it;
    _cued = false;
    fromCache = downloads.isOffline(it.key);
    final start = it.kind == 'radio' ? (ms: 0, from: null) : _startPosition(it);
    takenOver = start.from == null ? null : (device: start.from!.device, at: start.from!.updatedAt);
    final parts = it.multiPart ? it.parts : const <Part>[];
    final (part, local) = _locate(start.ms, parts);
    await audio.setAudioSources(
      parts.isEmpty ? [_source(it, null)] : [for (final p in parts) _source(it, p.index)],
      initialIndex: part,
      initialPosition: Duration(milliseconds: local),
    );
    await audio.setSpeed(rate);
    // Radio has no position; one entry still marks it as the last thing played on any device.
    if (it.kind == 'radio') {
      sync.savePosition(Playback(key: it.key, positionMs: 0, finished: false, title: it.title, subtitle: it.subtitle,
          device: api.device, updatedAt: DateTime.now().toUtc().toIso8601String()));
    }
    notifyListeners();
  }

  /// After a start: the last unfinished item of any device, paused at its position.
  Future<void> cueLast() async {
    if (item != null) return;
    var list = <Playback>[];
    if (api.online.value) {
      try {
        list = [for (final j in await api.call('GET', '/playback', query: {'limit': '10'}) as List) Playback.fromJson((j as Map).cast<String, dynamic>())];
      } catch (_) {}
    }
    if (list.isEmpty) {
      list = [for (final j in Stores.positions.data.values) Playback.fromJson(j)]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    }
    Item? it;
    for (final p in list.where((p) => !p.finished)) {
      if (api.online.value) {
        // Only what the server can still play (a removed source is skipped).
        try {
          it = Item.fromJson((await api.call('GET', '/items/${Uri.encodeComponent(p.key)}') as Map).cast<String, dynamic>());
          Stores.items.put(p.key, it.toJson());
        } catch (_) {
          continue;
        }
      } else {
        final j = Stores.items.get(p.key);
        if (j != null) it = Item.fromJson(j);
      }
      if (it != null) break;
    }
    if (it == null || item != null) return;
    queue = [it];
    index = 0;
    item = it;
    entry = entryOf(it);
    fromCache = downloads.isOffline(it.key);
    final start = it.kind == 'radio' ? (ms: 0, from: null) : _startPosition(it);
    takenOver = start.from == null ? null : (device: start.from!.device, at: start.from!.updatedAt);
    _cued = true;
    _cuedMs = start.ms;
    notifyListeners();
  }

  (int, int) _locate(int ms, List<Part> parts) {
    if (parts.isEmpty) return (0, ms);
    for (final p in parts) {
      if (ms >= p.startMs && ms < p.startMs + p.durationMs) return (p.index, ms - p.startMs);
    }
    return (parts.length - 1, 0);
  }

  ({int ms, Playback? from}) _startPosition(Item it) {
    final cands = [sync.localPosition(it.key), it.playback].whereType<Playback>().toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (cands.isEmpty || cands.first.finished) return (ms: 0, from: null);
    final best = cands.first;
    return (ms: best.positionMs, from: best.device.isNotEmpty && best.device != api.device ? best : null);
  }

  Future<void> seekTo(int ms) async {
    if (_cued) {
      _cuedMs = ms.clamp(0, duration);
      return notifyListeners();
    }
    final (part, local) = _locate(ms.clamp(0, duration), _parts);
    await audio.seek(Duration(milliseconds: local), index: _parts.isEmpty ? null : part);
    await _persist();
  }

  Future<void> seekBy(int ms) => seekTo(position + ms);

  void toggle() {
    if (_cued && item != null) {
      final it = item!;
      // The cued position is the start: save it first, so loading begins there.
      if (it.kind != 'radio' && _cuedMs > 0) {
        sync.savePosition(Playback(key: it.key, positionMs: _cuedMs, durationMs: it.durationMs, finished: false, title: it.title,
            subtitle: it.subtitle, device: api.device, updatedAt: DateTime.now().toUtc().toIso8601String()));
      }
      unawaited(_load(it).then((_) => audio.play()));
      return;
    }
    audio.playing ? audio.pause() : audio.play();
  }

  Future<void> setRate(double r) async {
    rate = r;
    await audio.setSpeed(rate);
    notifyListeners();
  }

  bool get sleeping => sleepAt != null || sleepAtEnd != null;

  void setSleep({Duration? after, String? atEnd}) {
    sleepAt = after == null ? null : DateTime.now().add(after);
    sleepAtEnd = atEnd;
    _sleepChapter = chapter;
    notifyListeners();
  }

  void _checkSleep() {
    if (!audio.playing) return;
    final timeUp = sleepAt != null && DateTime.now().isAfter(sleepAt!);
    final chapterOver = sleepAtEnd == 'chapter' && chapter != _sleepChapter;
    if (timeUp || chapterOver) {
      setSleep();
      audio.pause();
    }
  }

  Future<void> skip(int d) async {
    final i = index + d;
    if (i < 0 || i >= queue.length) return;
    await _persist();
    index = i;
    final full = await meta(queue[i].key);
    if (full != null) queue[i] = full;
    await _load(queue[i]);
    // just_audio's play() completes only when playback stops: do not wait for it.
    unawaited(audio.play());
  }

  Future<void> _persist({bool finished = false}) async {
    final it = item;
    // Live radio has no position to continue from.
    // A cued item has not been played here: nothing new to save.
    if (it == null || _cued || it.kind == 'radio' || (!finished && position < 1000)) return;
    sync.savePosition(Playback(
      key: it.key,
      positionMs: position,
      durationMs: duration > 0 ? duration : null,
      finished: finished,
      title: it.title,
      subtitle: it.subtitle,
      device: api.device,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    ));
  }

  bool _wasPlaying = false;
  void _onState(PlayerState s) {
    if (s.playing != _wasPlaying) {
      _wasPlaying = s.playing;
      _saveTimer?.cancel();
      if (s.playing) {
        _saveTimer = Timer.periodic(const Duration(seconds: 10), (_) => _persist());
      } else {
        unawaited(_persist());
      }
    }
    if (s.processingState == ProcessingState.completed) {
      final stopHere = sleepAtEnd != null;
      if (stopHere) setSleep();
      unawaited(_ended(stopHere));
    }
    notifyListeners();
  }

  Future<void> _ended(bool stopHere) async {
    final more = index + 1 < queue.length;
    Future<void> Function()? after;
    if (!more && !stopHere && entry != null && nextAfter != null) {
      try {
        after = await nextAfter!(entry!);
      } catch (_) {}
    }
    await _persist(finished: true);
    if (stopHere) return;
    if (more) {
      await skip(1);
    } else if (after != null) {
      await after();
    }
  }

  /// Another device moved on: follow it while this device is not playing the item.
  void _onRemote(Playback p) {
    if (item == null || p.key != item!.key || audio.playing || p.device == api.device) return;
    takenOver = (device: p.device, at: p.updatedAt);
    if (_cued) {
      _cuedMs = p.positionMs;
      return notifyListeners();
    }
    final (part, local) = _locate(p.positionMs, _parts);
    unawaited(audio.seek(Duration(milliseconds: local), index: _parts.isEmpty ? null : part));
    notifyListeners();
  }

  Future<void> stop() async {
    await _persist();
    await audio.stop();
    item = null;
    _cued = false;
    notifyListeners();
  }
}

final player = Player.instance;
