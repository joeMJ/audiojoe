// Playback: from the offline copy when available, else streamed from the server.
// Books may consist of several files; positions are always positions in the whole item.
// Saves positions locally and to the server; follows other devices while paused.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'api.dart';
import 'downloads.dart';
import 'models.dart';
import 'store.dart';
import 'sync.dart';

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

  // Sleep timer: pause at a time, or at the end of the current chapter or item.
  DateTime? sleepAt;
  String? sleepAtEnd; // 'chapter' | 'item'
  String _sleepChapter = '';

  List<Part> get _parts => item?.multiPart == true ? item!.parts : const [];
  int get _part => _parts.isEmpty ? 0 : (audio.currentIndex ?? 0);

  int get position => (_parts.isEmpty ? 0 : _parts[_part].startMs) + audio.position.inMilliseconds;
  int get duration => _parts.isNotEmpty ? (item?.durationMs ?? 0) : (audio.duration?.inMilliseconds ?? item?.durationMs ?? 0);
  bool get playing => audio.playing;
  bool get live => item?.kind == 'radio';

  String get chapter {
    final ms = position;
    for (final c in item?.chapters ?? const <Chapter>[]) {
      if (ms >= c.startMs && ms < c.endMs) return c.title;
    }
    return '';
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

  Future<void> play(List<Item> items, [int i = 0]) async {
    await _persist();
    final full = await meta(items[i].key);
    queue = [...items];
    if (full != null) queue[i] = full;
    index = i;
    await _load(queue[i]);
    await audio.play();
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
    final (part, local) = _locate(ms.clamp(0, duration), _parts);
    await audio.seek(Duration(milliseconds: local), index: _parts.isEmpty ? null : part);
    await _persist();
  }

  Future<void> seekBy(int ms) => seekTo(position + ms);

  void toggle() => audio.playing ? audio.pause() : audio.play();

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
    await audio.play();
  }

  Future<void> _persist({bool finished = false}) async {
    final it = item;
    // Live radio has no position to continue from.
    if (it == null || it.kind == 'radio' || (!finished && position < 1000)) return;
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
      unawaited(_persist(finished: true).then((_) => !stopHere && index + 1 < queue.length ? skip(1) : null));
    }
    notifyListeners();
  }

  /// Another device moved on: follow it while this device is not playing the item.
  void _onRemote(Playback p) {
    if (item == null || p.key != item!.key || audio.playing || p.device == api.device) return;
    takenOver = (device: p.device, at: p.updatedAt);
    final (part, local) = _locate(p.positionMs, _parts);
    unawaited(audio.seek(Duration(milliseconds: local), index: _parts.isEmpty ? null : part));
    notifyListeners();
  }

  Future<void> stop() async {
    await _persist();
    await audio.stop();
    item = null;
    notifyListeners();
  }
}

final player = Player.instance;
