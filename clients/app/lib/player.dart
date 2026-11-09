// Playback: from the offline copy when available, else streamed from the server.
// Books may consist of several files; positions are always positions in the whole item.
// Saves positions locally and to the server; follows other devices while paused.
// Connection loss (user 2026-11-07): a copy finished while playing is taken over at once; when
// the stream breaks, the player continues from the copy at the same position, or without one
// waits there and continues by itself as soon as the server answers again.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;

import 'api.dart';
import 'cache.dart' show albumTracksOf;
import 'downloads.dart';
import 'models.dart';
import 'prefs.dart';
import 'remote.dart';
import 'store.dart';
import 'sync.dart';

/// The continue-list entry being played (an album for music): its successor plays next.
typedef Entry = ({String list, String key});

class Player extends ChangeNotifier {
  Player._() {
    audio.playerStateStream.listen(_onState);
    audio.positionStream.listen((_) {
      _keepDuration();
      _checkSleep();
      _track();
      notifyListeners();
    });
    audio.currentIndexStream.listen(_onIndex);
    audio.errorStream.listen(_onError);
    downloads.addListener(_onDownloads);
    sync.reconnected.listen((_) => _retryNow());
    sync.remote.listen(_onRemote);
    sync.commands.listen((c) => unawaited(_onCommand(c)));
  }
  static final instance = Player._();

  // Headers (session token) go straight to the platform player: just_audio's default local
  // proxy needs cleartext HTTP to 127.0.0.1, which Android blocks.
  final audio = AudioPlayer(useProxyForRequestHeaders: false);
  Item? item;
  List<Item> queue = [];
  int index = 0;
  bool fromCache = false;
  /// "Played on …" / "Playing on …": the position here comes from another device and this device
  /// does not play (cued after the start, or following that device's reports). Stays until played here.
  ({String device, String at})? get followed => audio.playing ? null : _followed;
  ({String device, String at})? _followed;
  set followed(({String device, String at})? v) => _followed = v;

  /// Play here after following another device: "Taken over from …" for a few seconds (user 2026-11-07:
  /// only when playing here actually continues that device's position).
  void _takeOver(({String device, String at})? from) {
    _followed = null;
    takenOver = from;
  }

  /// "Taken over from …": shown for a few seconds after playing here continued another device's position.
  ({String device, String at})? get takenOver => _takenOver;
  ({String device, String at})? _takenOver;
  Timer? _takenOverTimer;
  set takenOver(({String device, String at})? v) {
    _takenOver = v;
    _takenOverTimer?.cancel();
    if (v != null) {
      _takenOverTimer = Timer(const Duration(seconds: 8), () {
        _takenOver = null;
        notifyListeners();
      });
    }
  }
  double rate = 1;
  /// Music has no speed button (the heart is there, user 2026-11-09): it always plays at 1.0×; the
  /// speed set for podcasts and books stays for them.
  double get _speed => item?.kind == 'track' ? 1 : rate;
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

  // Podcasts and books continue 10 s earlier after another device or after a pause of 5 minutes
  // (each switchable for the account: Settings → Playback).
  static const _rewindMs = 10000;
  static const _longPause = Duration(minutes: 5);
  DateTime? _pausedAt;
  static bool _rewinds(Item it) =>
      it.kind == 'episode' ? playbackPrefs.rewindPodcasts : it.kind == 'book' && playbackPrefs.rewindBooks;
  static int _back(Item it, int ms) => _rewinds(it) ? (ms - _rewindMs).clamp(0, ms) : ms;
  static bool _longAgo(String at) {
    final t = DateTime.tryParse(at);
    return t != null && DateTime.now().toUtc().difference(t) >= _longPause;
  }

  /// While another device is controlled: its position and state (its title is shown here).
  int get position => remote.active ? remote.position : _localPosition;
  int get _localPosition => _cued ? _cuedMs : (_parts.isEmpty ? 0 : _parts[_part].startMs) + audio.position.inMilliseconds;
  int get duration => remote.active
      ? (remote.durationMs ?? item?.durationMs ?? 0)
      : _parts.isNotEmpty ? (item?.durationMs ?? 0) : (audio.duration?.inMilliseconds ?? _knownDuration ?? item?.durationMs ?? 0);

  /// The length the player last reported for the item: while it waits for the server (no source
  /// loaded) the bar stays at the held position instead of falling back to an unknown length.
  String? _durationKey;
  int _durationMs = 0;
  int? get _knownDuration => item != null && item!.key == _durationKey && _durationMs > 0 ? _durationMs : null;
  void _keepDuration() {
    final d = audio.duration?.inMilliseconds, it = item;
    if (d != null && d > 0 && it != null && !_switching) {
      _durationKey = it.key;
      _durationMs = d;
    }
  }

  bool get playing => remote.active ? remote.playing : audio.playing || waiting;
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
    if (i >= 0 && i + 1 < chapters.length) return _jump(chapters[i + 1].startMs);
    if (index + 1 < queue.length) return skip(1);
  }

  /// Start of the chapter; within its first 3 seconds the previous chapter.
  Future<void> previousChapter() async {
    final i = chapterIndex;
    if (i < 0) return index > 0 ? skip(-1) : _jump(0);
    final c = chapters[i];
    return _jump(position - c.startMs < 3000 && i > 0 ? chapters[i - 1].startMs : c.startMs);
  }

  /// A chapter jump (⏮ ⏭): here, or on the controlled device.
  Future<void> _jump(int ms) => seekTo(ms);

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

  /// The queue (e.g. an album) on this device, so a restart continues it instead of one title.
  /// The server keeps it too, so another device taking over the title continues the queue.
  Map<String, dynamic> get queueJson => {
        'items': [for (final q in queue) q.toJson()],
        'index': index,
        'entry': entry == null ? null : {'list': entry!.list, 'key': entry!.key},
      };

  void _saveQueue() {
    final q = queueJson;
    Stores.device.put('queue', q);
    if (api.online.value) unawaited(api.call('PUT', '/queue', body: q).catchError((_) => null));
  }

  /// The queue another device left with `key` as its current title.
  Future<Map?> _serverQueue(String key) async {
    if (!api.online.value) return null;
    try {
      return await api.call('GET', '/queue/${Uri.encodeComponent(key)}') as Map;
    } catch (_) {
      return null;
    }
  }

  /// The tracks of an album (tests replace it).
  static Future<List<Item>> Function(String album) albumTracks = albumTracksOf;

  /// A title without any queue (none here, none on the server): its album, at this title, so a
  /// restart or a single title continues the album with ⏮ ⏭ (user 2026-11-08, "88 ja").
  Future<({List<Item> items, int i, Entry entry})?> _albumOf(Item it) async {
    final album = it.album;
    if (it.kind != 'track' || album == null || !api.online.value) return null;
    try {
      final all = await albumTracks(album);
      final i = all.indexWhere((x) => x.key == it.key);
      if (all.length < 2 || i < 0) return null;
      return (items: [...all]..[i] = it, i: i, entry: (list: 'music', key: album));
    } catch (_) {
      return null;
    }
  }

  void _setAlbum(({List<Item> items, int i, Entry entry}) a) {
    queue = a.items;
    index = a.i;
    entry = a.entry;
  }

  bool _restoreQueue(Item it, [Map? from]) {
    final q = from ?? Stores.device.get('queue');
    try {
      final items = [for (final j in q?['items'] as List? ?? const []) Item.fromJson((j as Map).cast<String, dynamic>())];
      final i = q?['index'] as int? ?? -1;
      if (i < 0 || i >= items.length || items[i].key != it.key) return false;
      final e = q!['entry'] as Map?;
      queue = items..[i] = it;
      index = i;
      entry = e == null ? null : (list: e['list'] as String, key: e['key'] as String);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> play(List<Item> items, [int i = 0, Entry? from]) async {
    await _persist();
    // Episodes and books are list entries themselves; music only when played as an album entry.
    entry = from ?? entryOf(items[i]);
    final full = await meta(items[i].key);
    // A title from the likes plays on its own; at its end the next like follows (nextAfter), not its album.
    final liked = from?.list == 'likes';
    // A single title another device played within an album: continue that album here.
    final other = !liked && items.length == 1 && items[i].kind == 'track' ? await _serverQueue(items[i].key) : null;
    queue = [...items];
    if (full != null) queue[i] = full;
    index = i;
    final album = !liked && other == null && items.length == 1 ? await _albumOf(queue[i]) : null;
    if (other != null) {
      _restoreQueue(queue[i], other);
    } else if (album != null) {
      final e = entry;
      _setAlbum(album);
      if (from != null) entry = e;
    }
    _saveQueue();
    _takeOver(await _load(queue[i]));
    // just_audio's play() completes only when playback stops: do not wait for it.
    unawaited(audio.play());
  }

  /// Whether the copy of an item (or of one part of a book) is complete on this device: a
  /// download is renamed to its final name only when it is complete.
  bool _hasLocal(Item it, int? part) {
    if (_badCopy.contains(downloads.file(it.key, part).path)) return false;
    try {
      return downloads.file(it.key, part).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// Per loaded part: played from the copy on this device.
  List<bool> _local = const [];
  /// Copies that failed to play: not tried again (else a broken file would loop).
  final _badCopy = <String>{};

  AudioSource _source(Item it, int? part) {
    final tag = MediaItem(
      id: '${it.key}${part == null ? '' : '#$part'}',
      title: it.title,
      artist: it.subtitle,
      album: 'audiojoe',
      artUri: it.image == null ? null : (downloads.coverFile(it.image)?.uri ?? api.imageUri(it.image!)),
      artHeaders: api.authHeaders,
    );
    if (it.kind != 'radio' && _hasLocal(it, part)) return AudioSource.file(downloads.file(it.key, part).path, tag: tag);
    return AudioSource.uri(api.streamUri(it.key, part: part), headers: api.authHeaders, tag: tag);
  }

  /// Loads [it]; returns the other device whose position it starts at (null: own or none).
  Future<({String device, String at})?> _load(Item it, {bool fromStart = false, int? at}) async {
    item = it;
    _cued = false;
    _stopWaiting();
    final start = at != null ? (ms: at, from: null) : it.kind == 'radio' || fromStart ? (ms: 0, from: null) : _startPosition(it);
    final from = start.from == null ? null : (device: start.from!.device, at: start.from!.updatedAt);
    _followed = from;
    takenOver = null;
    await _setSources(it, start.ms);
    await audio.setSpeed(it.kind == 'track' ? 1 : rate);
    // Radio has no position; one entry still marks it as the last thing played on any device.
    if (it.kind == 'radio') {
      sync.savePosition(Playback(key: it.key, positionMs: 0, finished: false, title: it.title, subtitle: it.subtitle,
          device: api.device, updatedAt: DateTime.now().toUtc().toIso8601String()));
    }
    notifyListeners();
    return from;
  }

  /// Loads the item's files (each part from its copy when complete, else streamed) at a position.
  Future<void> _setSources(Item it, int ms, {Duration? limit}) async {
    final parts = it.multiPart ? it.parts : const <Part>[];
    final (part, local) = _locate(ms, parts);
    _local = parts.isEmpty ? [it.kind != 'radio' && _hasLocal(it, null)] : [for (final p in parts) _hasLocal(it, p.index)];
    fromCache = _local.every((l) => l);
    _lastMs = ms;
    _lastPart = part;
    _switching = true;
    try {
      final load = audio.setAudioSources(
        parts.isEmpty ? [_source(it, null)] : [for (final p in parts) _source(it, p.index)],
        initialIndex: part,
        initialPosition: Duration(milliseconds: local),
      );
      await (limit == null ? load : load.timeout(limit));
    } finally {
      _switching = false;
    }
  }

  // ---------------------------------------------------------------- connection loss

  /// Last position heard here (whole item) and its part: where playback continues after a break.
  int _lastMs = 0;
  int _lastPart = 0;
  /// While sources are set or a part is chosen here, index changes are not playback moving on.
  bool _switching = false;
  /// Set while waiting for the server after a break: playback continues by itself.
  Timer? _retry;
  bool get waiting => _retry != null;
  /// Whether the current title (or part of a book) plays from the copy on this device.
  bool get partFromCopy {
    final i = _parts.isEmpty ? 0 : _part;
    return i < _local.length && _local[i];
  }
  /// A stream that stays buffering while playing (a connection that hangs) counts as broken.
  Timer? _stall;
  static const _stallAfter = Duration(seconds: 15);
  void _watchStall(PlayerState s) {
    if (s.playing && s.processingState == ProcessingState.buffering && !_cued) {
      _stall ??= Timer(_stallAfter, () {
        _stall = null;
        if (audio.playing && audio.processingState == ProcessingState.buffering) _interrupted();
      });
    } else {
      _stall?.cancel();
      _stall = null;
    }
  }

  /// A spot in the file that cannot be decoded (not the connection): mpv reports "Header missing" /
  /// "Error decoding audio" again on every attempt there (title 3 of an album on 171 at 186 s and at
  /// its end, user 2026-11-08). Counted per spot and attempt, see [_onError].
  int _badAt = -1, _badCount = 0;
  DateTime _badSeen = DateTime(0);
  /// The end of the item is being handled (one error can come as several messages).
  bool _ending = false;

  static bool _decoding(PlayerException e) {
    final m = '${e.message}'.toLowerCase();
    return m.contains('decod') || m.contains('header missing');
  }

  /// A playback error. Within the last 5 s of the item it counts as the end (the next title plays,
  /// user 2026-11-09 "92 ja"). A decoding error that comes back after two attempts at the same spot
  /// continues 5 s later ("93 ja"); everything else waits for the connection ([_interrupted]).
  void _onError(PlayerException e) {
    final it = item;
    if (_ending) return;
    if (it == null || _cued || remote.active || _switching) return _interrupted();
    final length = it.kind == 'radio' ? 0 : it.durationMs ?? 0;
    final ms = _lastMs;
    if (length > 0 && ms >= length - 5000) {
      _stopWaiting();
      unawaited(_atEnd());
      return;
    }
    if (length > 0 && _decoding(e)) {
      final now = DateTime.now();
      // The messages of one attempt come together: one count.
      if (now.difference(_badSeen) > const Duration(seconds: 1)) {
        if (_badAt >= 0 && (ms - _badAt).abs() <= 2000) {
          _badCount++;
        } else {
          _badAt = ms;
          _badCount = 1;
        }
      }
      _badSeen = now;
      if (_badCount >= 3) {
        _badAt = -1;
        _badCount = 0;
        final on = ms + 5000;
        if (on >= length - 5000) {
          _stopWaiting();
          unawaited(_atEnd());
          return;
        }
        _lastMs = on;
        return _interrupted(at: on);
      }
    }
    _interrupted();
  }

  /// The item ended here: the next title (or the next list entry), unless the sleep timer stops here.
  Future<void> _atEnd() async {
    if (_ending) return;
    _ending = true;
    try {
      final stopHere = sleepAtEnd != null;
      if (stopHere) setSleep();
      await _ended(stopHere);
    } finally {
      _ending = false;
    }
  }

  void _track() {
    if (_cued || item == null || _switching || audio.processingState == ProcessingState.idle) return;
    if (audio.processingState == ProcessingState.ready || audio.processingState == ProcessingState.buffering) {
      _lastMs = _localPosition;
      _lastPart = _part;
    }
  }

  /// The player moved to another part by itself: a stream that ended early (mpv treats a broken
  /// connection as the end of the file) must not skip the rest of the part.
  void _onIndex(int? i) {
    final it = item;
    if (it != null && !_switching && !_cued && i != null && _parts.isNotEmpty && i == _lastPart + 1 && _lastPart < _parts.length) {
      final p = _parts[_lastPart];
      if (_lastMs < p.startMs + p.durationMs - 5000) {
        _interrupted();
        return;
      }
    }
    if (i != null && !_switching) _lastPart = i;
    // A part saved while the one before played: play it from the copy.
    if (i != null && i < _local.length && !_local[i] && item != null && _hasLocal(item!, _parts.isEmpty ? null : _parts[i].index)) {
      unawaited(_reload(_parts.isEmpty ? _lastMs : _parts[i].startMs, play: audio.playing));
    }
    notifyListeners();
  }

  /// A download finished while its item plays from the stream: continue from the copy.
  void _onDownloads() {
    final it = item;
    if (it == null || _cued || remote.active || it.kind == 'radio' || _switching || _local.isEmpty) return;
    final i = _parts.isEmpty ? 0 : _part;
    if (i < _local.length && !_local[i] && _hasLocal(it, _parts.isEmpty ? null : _parts[i].index)) {
      unawaited(_reload(_localPosition, play: audio.playing));
    }
  }

  /// Sets the sources again at a position (from the copy where complete), keeping play or pause.
  Future<void> _reload(int ms, {required bool play}) async {
    final it = item;
    if (it == null) return;
    try {
      await _setSources(it, ms);
      await audio.setSpeed(_speed);
      if (play) unawaited(audio.play());
    } catch (_) {
      _interrupted(at: ms);
    }
    notifyListeners();
  }

  /// The stream broke (error, or an end before the end): continue from the copy, else wait here.
  void _interrupted({int? at}) {
    final it = item;
    if (it == null || _cued || remote.active || _switching) return;
    final ms = it.kind == 'radio' ? 0 : at ?? _lastMs;
    final parts = it.multiPart ? it.parts : const <Part>[];
    // The copy itself failed: not again, wait for the server instead.
    final now = _parts.isEmpty ? 0 : _part;
    if (at == null && now < _local.length && _local[now]) _badCopy.add(downloads.file(it.key, _parts.isEmpty ? null : _parts[now].index).path);
    final (part, _) = _locate(ms, parts);
    final copy = it.kind != 'radio' && _hasLocal(it, parts.isEmpty ? null : parts[part].index);
    if (copy) {
      unawaited(_reload(ms, play: true));
      return;
    }
    // Waits paused at the position; the position stays on this device (and goes to the server later).
    // The broken stream is dropped (a hanging connection would keep the player buffering).
    _cued = true;
    _cuedMs = ms;
    unawaited(audio.stop().catchError((_) {}));
    if (it.kind != 'radio') {
      sync.savePosition(Playback(key: it.key, positionMs: ms, durationMs: it.durationMs, finished: false, title: it.title,
          subtitle: it.subtitle, device: api.device, updatedAt: DateTime.now().toUtc().toIso8601String(), state: 'paused'));
    }
    _retry ??= Timer.periodic(const Duration(seconds: 5), (_) => _retryNow());
    notifyListeners();
  }

  /// One attempt to continue after a break (also when the event stream is back).
  Future<void> _retryNow() async {
    final it = item;
    if (_retry == null || it == null || !_cued || _switching) return;
    try {
      await _setSources(it, _cuedMs, limit: const Duration(seconds: 30));
      _cued = false;
      _stopWaiting();
      await audio.setSpeed(_speed);
      unawaited(audio.play());
    } catch (_) {
      // Still no connection: stays waiting at the position.
      _cued = true;
      unawaited(audio.stop().catchError((_) {}));
    }
    notifyListeners();
  }

  void _stopWaiting() {
    _retry?.cancel();
    _retry = null;
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
    final other = await _serverQueue(it.key);
    if (item != null) return;
    if (!_restoreQueue(it) && (other == null || !_restoreQueue(it, other))) {
      final album = await _albumOf(it);
      if (item != null) return;
      if (album != null) {
        _setAlbum(album);
        _saveQueue();
      } else {
        queue = [it];
        index = 0;
        entry = entryOf(it);
      }
    }
    item = it;
    fromCache = downloads.isOffline(it.key);
    final start = it.kind == 'radio' ? (ms: 0, from: null) : _startPosition(it);
    _followed = start.from == null ? null : (device: start.from!.device, at: start.from!.updatedAt);
    takenOver = null;
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
    // A position in the last seconds counts as heard (else the title ends at once and the next follows).
    final length = best.durationMs ?? it.durationMs ?? 0;
    if (length > 0 && best.positionMs >= length - 5000) return (ms: 0, from: null);
    final other = best.device.isNotEmpty && best.device != api.device;
    return (ms: other || _longAgo(best.updatedAt) ? _back(it, best.positionMs) : best.positionMs, from: other ? best : null);
  }

  Future<void> seekTo(int ms) async {
    if (remote.active) {
      await remote.command('seek', positionMs: ms.clamp(0, duration > 0 ? duration : ms));
      return;
    }
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
    if (remote.active) {
      unawaited(remote.command(remote.playing ? 'pause' : 'resume'));
      return;
    }
    if (waiting) {
      // Waiting after a break shows as playing: pause stops waiting, the position stays.
      _stopWaiting();
      return notifyListeners();
    }
    if (_cued && item != null) {
      final it = item!, from = _followed;
      // The cued position is the start: save it first, so loading begins there.
      if (it.kind != 'radio' && _cuedMs > 0) {
        sync.savePosition(Playback(key: it.key, positionMs: _cuedMs, durationMs: it.durationMs, finished: false, title: it.title,
            subtitle: it.subtitle, device: api.device, updatedAt: DateTime.now().toUtc().toIso8601String()));
      }
      final at = _cuedMs;
      unawaited(_load(it).then((_) {
        _takeOver(from);
        return audio.play();
      }).catchError((Object _) => _interrupted(at: at)));
      return;
    }
    if (audio.playing) {
      audio.pause();
      return;
    }
    // Paused here while following another device's reports: playing continues its position.
    if (_followed != null) _takeOver(_followed);
    final it = item, paused = _pausedAt;
    if (it != null && paused != null && _rewinds(it) && DateTime.now().difference(paused) >= _longPause) {
      unawaited(seekTo(_back(it, _localPosition)).then((_) => audio.play()));
      return;
    }
    audio.play();
  }

  Future<void> setRate(double r) async {
    rate = r;
    await audio.setSpeed(_speed);
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

  /// [afterEnd]: the title has just been saved as heard; saving again would store its end
  /// position as not heard. The next title of a queue starts at its beginning.
  Future<void> skip(int d, {bool afterEnd = false}) async {
    if (remote.active) {
      await remote.command(d > 0 ? 'next' : 'prev');
      return;
    }
    final i = index + d;
    if (i < 0 || i >= queue.length) return;
    if (!afterEnd) await _persist();
    index = i;
    final full = await meta(queue[i].key);
    if (full != null) queue[i] = full;
    _saveQueue();
    await _load(queue[i], fromStart: true);
    // just_audio's play() completes only when playback stops: do not wait for it.
    unawaited(audio.play());
  }

  /// Saves the position with this device's state. [report]: also right at the start of a title
  /// (other devices see at once what plays here).
  Future<void> _persist({bool finished = false, bool report = false, bool stopped = false}) async {
    final it = item;
    // Live radio has no position to continue from.
    // A cued item has not been played here, and while another device is controlled nothing plays here.
    if (it == null || _cued || remote.active || it.kind == 'radio' || (!finished && !report && _localPosition < 1000)) return;
    final d = _parts.isNotEmpty ? (it.durationMs ?? 0) : (audio.duration?.inMilliseconds ?? it.durationMs ?? 0);
    sync.savePosition(Playback(
      key: it.key,
      positionMs: _localPosition,
      durationMs: d > 0 ? d : null,
      finished: finished,
      title: it.title,
      subtitle: it.subtitle,
      device: api.device,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
      state: stopped || finished ? 'stopped' : audio.playing ? 'playing' : 'paused',
    ));
  }

  bool _wasPlaying = false;
  void _onState(PlayerState s) {
    _watchStall(s);
    if (s.playing != _wasPlaying) {
      _wasPlaying = s.playing;
      _pausedAt = s.playing ? null : DateTime.now();
      _saveTimer?.cancel();
      if (s.playing) {
        unawaited(_persist(report: true));
        _saveTimer = Timer.periodic(const Duration(seconds: 10), (_) => _persist());
      } else {
        unawaited(_persist());
      }
    }
    if (s.processingState == ProcessingState.completed && _endedEarly()) {
      _interrupted();
      return notifyListeners();
    }
    if (s.processingState == ProcessingState.completed) unawaited(_atEnd());
    notifyListeners();
  }

  /// An end more than 5 s before the item's length is a broken stream, not the end (mpv reports
  /// a lost connection as the end of the file). Without a known length it counts as the end.
  bool _endedEarly() {
    final it = item;
    if (it == null || it.kind == 'radio' || _switching) return false;
    final length = it.durationMs ?? 0;
    return length > 0 && _lastMs < length - 5000;
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
      await skip(1, afterEnd: true);
    } else if (after != null) {
      await after();
    }
  }

  /// Another device moved on: follow it while this device is not playing the item. When it moved
  /// to another title of this queue (a Sonos speaker reached the next track), switch to that title.
  void _onRemote(Playback p) {
    // While another device is controlled, its reports (event `device`) drive the view.
    if (item == null || audio.playing || remote.active || p.device == api.device) return;
    if (p.key != item!.key) {
      final i = queue.indexWhere((q) => q.key == p.key);
      if (i >= 0 && !p.finished) unawaited(_follow(i));
      return;
    }
    _followed = (device: p.device, at: p.updatedAt);
    final ms = _back(item!, p.positionMs);
    if (_cued) {
      _cuedMs = ms;
      return notifyListeners();
    }
    final (part, local) = _locate(ms, _parts);
    unawaited(audio.seek(Duration(milliseconds: local), index: _parts.isEmpty ? null : part));
    notifyListeners();
  }

  /// Shows title `i` of the queue at the position another device reported, without playing here.
  Future<void> _follow(int i) async {
    index = i;
    final full = await meta(queue[i].key);
    if (full != null) queue[i] = full;
    _saveQueue();
    await _load(queue[i]);
    notifyListeners();
  }

  /// Before the app ends (desktop window closed while playing): the position is saved as paused
  /// and sent, then libmpv is shut down. Without this mpv played on while Flutter tore down the Dart
  /// VM, then called its freed wake-up callback: SIGSEGV (user 2026-11-09, release-plan).
  Future<void> shutdown() async {
    _saveTimer?.cancel();
    _retry?.cancel();
    if (audio.playing) await audio.pause();
    await _persist(report: true);
    await sync.flush();
    await audio.dispose();
  }

  Future<void> stop() async {
    await _persist(stopped: true);
    await audio.stop();
    item = null;
    _cued = false;
    _followed = null;
    takenOver = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------- other devices

  /// Pauses this device (before it controls another one).
  Future<void> pauseHere() async {
    if (audio.playing) await audio.pause();
  }

  /// Shows the item another device plays, paused here, without loading its stream.
  Future<void> _show(String key, int ms) async {
    if (item?.key != key) {
      final i = queue.indexWhere((q) => q.key == key);
      Item? it = i >= 0 ? queue[i] : null;
      final full = await meta(key);
      it = full ?? it;
      if (it == null) return;
      if (i >= 0) {
        index = i;
        queue[i] = it;
      } else {
        final other = await _serverQueue(key);
        if (other == null || !_restoreQueue(it, other)) {
          final album = await _albumOf(it);
          if (album != null) {
            _setAlbum(album);
          } else {
            queue = [it];
            index = 0;
            entry = Player.entryOf(it);
          }
        }
      }
      if (audio.playing) await audio.pause();
      item = it;
      fromCache = downloads.isOffline(it.key);
    }
    _cued = true;
    _cuedMs = ms;
    notifyListeners();
  }

  /// The controlled device moved to another title: show it.
  Future<void> mirror(String key) => _show(key, remote.position);

  /// The controlled device ended: its title stays here, paused at its last position.
  Future<void> cueAt(String key, int ms) => _show(key, ms);

  /// "Here": continues an item here at a position another device left it.
  Future<void> takeOver(String key, int ms) async {
    await _show(key, ms);
    final it = item;
    if (it == null || it.key != key) return;
    // The title may be shown already without its album (e.g. after a restart while Sonos played on):
    // the queue of the device that played it continues here (user 2026-11-07).
    if (queue.length < 2) {
      final other = await _serverQueue(key);
      if (other != null && _restoreQueue(it, other)) {
        _saveQueue();
      } else if (await _albumOf(it) case final album?) {
        _setAlbum(album);
        _saveQueue();
      }
    }
    _cuedMs = _back(it, ms);
    sync.savePosition(Playback(key: key, positionMs: _cuedMs, durationMs: it.durationMs, finished: false, title: it.title,
        subtitle: it.subtitle, device: api.device, updatedAt: DateTime.now().toUtc().toIso8601String()));
    toggle();
  }

  /// A command from another device; this device reports its state right after it.
  Future<void> _onCommand(Map<String, dynamic> c) async {
    final at = c['position_ms'] as int?;
    switch (c['action']) {
      case 'pause' || 'takeover':
        await pauseHere();
      case 'resume':
        if (!audio.playing) toggle();
      case 'stop':
        await pauseHere();
        await _persist(report: true, stopped: true);
        return;
      case 'next':
        await skip(1);
      case 'prev':
        await skip(-1);
      case 'seek' when at != null:
        await seekTo(at);
      case 'play':
        final q = c['queue'] as Map?;
        final items = [for (final j in q?['items'] as List? ?? const []) Item.fromJson((j as Map).cast<String, dynamic>())];
        final i = q?['index'] as int? ?? 0;
        final key = c['key'] as String? ?? '';
        if (items.isEmpty || i >= items.length || items[i].key != key) {
          final it = await meta(key);
          if (it == null) return;
          items
            ..clear()
            ..add(it);
        }
        final idx = items.length == 1 ? 0 : i;
        final e = q?['entry'] as Map?;
        if ((at ?? 0) > 0) {
          sync.savePosition(Playback(key: key, positionMs: _back(items[idx], at!), finished: false, title: items[idx].title,
              subtitle: items[idx].subtitle, device: api.device, updatedAt: DateTime.now().toUtc().toIso8601String()));
        }
        await play(items, idx, e == null ? null : (list: e['list'] as String, key: e['key'] as String));
        return;
    }
    await _persist(report: true);
  }
}

final player = Player.instance;
