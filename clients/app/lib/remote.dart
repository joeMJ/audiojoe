// Controlling another device: one of the account's apps or a Sonos room. While a target is
// set, the playback view shows its title and position (the clock runs here, every report from
// the server sets it anew) and its buttons send commands; this device's player stays paused.
// The target ends (stop, taken over, offline, the speaker plays something else): back to this
// device, the title paused at the last position.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'l10n.dart';
import 'models.dart';
import 'player.dart';
import 'sonos.dart';
import 'sync.dart';

class Remote extends ChangeNotifier {
  Remote._() {
    sync.devices.listen(_onDevice);
    sync.sonosEnded.listen((e) {
      if (sonos.output != null && e['room'] == sonos.output!.id) unawaited(_ended());
    });
    // The first connection belongs to the start (main.dart: cueLast, then findPlaying). After an
    // interruption (standby, network) events of that time do not come again: look as at the start
    // (user 2026-11-09, "110 ja").
    sync.reconnected.listen((_) => unawaited(_connects++ == 0 ? refresh() : findPlaying()));
  }
  int _connects = 0;
  static final instance = Remote._();

  /// The account's devices from the last refresh and events since (this one included).
  List<Device> devices = [];

  /// The controlled app ("Pixel 8") or Sonos room ("Sonos Buero"); null: this device.
  String? target;
  String key = '';
  String state = 'stopped';
  int _pos = 0;
  int? durationMs;
  DateTime _at = DateTime.now();
  Timer? _tick;
  /// Reports of the target received so far (tests check that they keep coming).
  int reports = 0;
  /// Set when a command failed (target offline): shown once by the view.
  final message = ValueNotifier<String?>(null);

  bool get active => target != null;
  bool get onSonos => sonos.output != null;
  bool get playing => state == 'playing';

  /// The target's position, running on here between its reports.
  int get position {
    final p = playing ? _pos + DateTime.now().difference(_at).inMilliseconds : _pos;
    final d = durationMs;
    return d != null && d > 0 && p > d ? d : p;
  }

  Device? device(String name) => devices.where((d) => d.name == name).firstOrNull;

  /// The name a device is shown with: given in the settings, else its device name.
  String shown(String name) => device(name)?.shown ?? name;

  Future<void> refresh() async {
    try {
      devices = [for (final j in await api.call('GET', '/devices') as List) Device.fromJson(j as Map)];
      final d = target == null ? null : device(target!);
      if (d != null) _take(d);
      notifyListeners();
    } catch (_) {}
  }

  void _onDevice(Device d) {
    final i = devices.indexWhere((x) => x.name == d.name);
    // Another app or one of our speakers begins to play while nothing plays here and nothing is
    // controlled: show it and control it, as after a start (user 2026-11-09, "106 ja": Office PC showed
    // the radio while the notebook had sent an album to the bedroom).
    final began = d.playing && !d.current && d.online && !d.web && (i < 0 || !devices[i].playing);
    if (began && !active && !player.playing) unawaited(_followStart());
    if (i < 0) {
      devices = [...devices, d];
    } else {
      devices = [...devices]..[i] = d;
    }
    if (d.name == target) {
      reports++;
      // Gone or stopped: the target has ended. A speaker ends with its session (event `sonos`).
      if (!d.online || (d.state == 'stopped' && !d.speaker)) {
        unawaited(_ended());
        return;
      }
      _take(d);
    }
    notifyListeners();
  }

  void _take(Device d) {
    final moved = d.key != key && d.key.isNotEmpty;
    key = d.key;
    state = d.state;
    _pos = d.positionMs;
    durationMs = d.durationMs;
    _at = DateTime.now();
    _tick?.cancel();
    if (playing) _tick = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    if (moved) unawaited(player.mirror(key));
  }

  /// Controls an app ("Control"); this device pauses.
  Future<void> control(String name) async {
    await player.pauseHere();
    sonos.clearOutput();
    target = name;
    final d = device(name);
    if (d != null) _take(d);
    notifyListeners();
    unawaited(refresh());
  }

  /// Controls the Sonos room that just started playing (after "There", or found playing).
  void controlRoom(Room r) {
    target = 'Sonos ${r.name}';
    final d = device(target!);
    if (d != null) {
      _take(d);
    } else {
      key = player.item?.key ?? '';
      state = 'playing';
      _pos = player.position;
      _at = DateTime.now();
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    }
    notifyListeners();
  }

  /// Back to this device without touching the target.
  void release() {
    _tick?.cancel();
    target = null;
    sonos.clearOutput();
    notifyListeners();
  }

  /// The target ended: the title stays here, paused at its last position.
  Future<void> _ended() async {
    if (!active) return;
    final (k, at) = (key, position);
    release();
    if (k.isNotEmpty) await player.cueAt(k, at);
  }

  /// A command to the target. Sonos rooms take theirs at `/sonos/{id}/command`.
  Future<Map?> command(String action, {int? positionMs, Map<String, dynamic>? extra}) async {
    final name = target;
    if (name == null) return null;
    final room = sonos.output;
    try {
      final r = room != null
          ? await api.call('POST', '/sonos/${room.id}/command', body: {'action': action, 'position_ms': ?positionMs})
          : await api.call('POST', '/devices/${Uri.encodeComponent(name)}/command',
              body: {'action': action, 'position_ms': ?positionMs, ...?extra});
      _optimistic(action, positionMs);
      return r is Map ? r : null;
    } on ApiError catch (e) {
      if (e.status == 409 && room == null) {
        message.value = t('{device} is offline.', {'device': shown(name)});
        await _ended();
        return null;
      }
      rethrow;
    }
  }

  void _optimistic(String action, int? positionMs) {
    switch (action) {
      case 'pause':
        _pos = position;
        state = 'paused';
      case 'resume':
        _at = DateTime.now();
        state = 'playing';
      case 'seek':
        _pos = positionMs ?? _pos;
        _at = DateTime.now();
    }
    _tick?.cancel();
    if (playing) _tick = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    notifyListeners();
  }

  /// "Here": the target pauses, this device continues where it was.
  Future<void> takeHere(String name) async {
    final room = sonos.output;
    if (room != null && name == target) {
      final r = await api.call('POST', '/sonos/${room.id}/command', body: {'action': 'takeover'}) as Map?;
      final (k, at) = ((r?['key'] ?? key) as String, (r?['position_ms'] ?? position) as int);
      release();
      if (k.isNotEmpty) await player.takeOver(k, at);
      return;
    }
    await api.call('POST', '/devices/${Uri.encodeComponent(name)}/command', body: {'action': 'takeover'});
    // The target reports its last position right after pausing.
    final d = await sync.devices.where((d) => d.name == name && !d.playing).first.timeout(const Duration(seconds: 4),
        onTimeout: () => device(name)!);
    if (name == target) release();
    if (d.key.isNotEmpty) await player.takeOver(d.key, d.positionMs);
  }

  /// "Take over" from the web player: only its last position, the web player is not asked.
  Future<void> takeFrom(Device d) async {
    if (d.key.isNotEmpty) await player.takeOver(d.key, d.playing ? d.positionMs + _since(d.updatedAt) : d.positionMs);
  }

  int _since(String iso) {
    final t = DateTime.tryParse(iso);
    return t == null ? 0 : DateTime.now().toUtc().difference(t).inMilliseconds.clamp(0, 60000);
  }

  /// "There" to an app: it plays this device's title and queue from here on, this device controls it.
  /// When another device plays (an app or a Sonos room under control), that one is paused first.
  Future<void> sendTo(String name) async {
    final it = player.item;
    if (it == null) return;
    final position = player.live ? 0 : player.position;
    final queue = player.queueJson;
    if (active) {
      await command('pause');
      release();
    }
    await api.call('POST', '/devices/${Uri.encodeComponent(name)}/command', body: {
      'action': 'play',
      'key': it.key,
      'position_ms': position,
      'queue': queue,
    });
    await control(name);
  }

  /// "Stop" for an app or the target.
  Future<void> stop(String name) async {
    if (name == target) {
      await command('stop');
      await _ended();
      return;
    }
    await api.call('POST', '/devices/${Uri.encodeComponent(name)}/command', body: {'action': 'stop'});
  }

  /// After a start (and a reconnect): when nothing plays here but another app or one of our speakers
  /// does, show that. True when it now controls one.
  Future<bool> findPlaying() async {
    if (_finding) return false;
    _finding = true;
    try {
      await refresh();
      if (active || player.playing) return false;
      final d = devices.where((d) => !d.current && d.online && d.playing && !d.web).firstOrNull;
      if (d == null) return false;
      if (d.speaker) {
        final rooms = await sonos.rooms();
        final r = rooms.where((r) => 'Sonos ${r.name}' == d.name && r.playing).firstOrNull;
        if (r == null || active || player.playing) return false;
        await controlSpeaker(r);
      } else {
        await player.mirror(d.key);
        await control(d.name);
      }
      return true;
    } finally {
      _finding = false;
    }
  }
  bool _finding = false;

  /// A device began to play: a speaker reports PLAYING only a moment after its session started,
  /// so up to three looks, two seconds apart.
  Future<void> _followStart() async {
    for (var n = 0; n < 3; n++) {
      if (n > 0) await Future<void>.delayed(const Duration(seconds: 2));
      if (active || player.playing) return;
      if (await findPlaying()) return;
    }
  }

  /// Controls the Sonos room where one of our sessions plays (started by another device): its
  /// title shows here, this device pauses.
  Future<void> controlSpeaker(Room r) async {
    final name = 'Sonos ${r.name}';
    final key = device(name)?.key ?? r.sessionKey ?? '';
    await player.pauseHere();
    if (key.isNotEmpty) await player.mirror(key);
    sonos.output = r;
    controlRoom(r);
    sonos.follow();
  }

  /// "Here" for such a room: control it, then continue its title here.
  Future<void> takeHereFrom(Room r) async {
    await controlSpeaker(r);
    await takeHere('Sonos ${r.name}');
  }
}

final remote = Remote.instance;
