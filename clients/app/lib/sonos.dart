// Output to Sonos speakers: the server starts playback on the speaker, which fetches the
// stream itself; the app then only controls it. Rooms with several speakers (stereo
// pairs, surround) are shown once.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'player.dart';

class Room {
  final int id;
  final String name, model;
  final bool s2, reachable;
  String? state;
  int? volume;
  Room(this.id, this.name, this.model, this.s2, this.reachable, this.state, this.volume);

  static Room fromJson(Map j) => Room(j['id'] as int, j['name'] as String, (j['model'] ?? '') as String, (j['s2'] ?? true) as bool,
      (j['reachable'] ?? false) as bool, j['state'] as String?, j['volume'] as int?);

  bool get playing => state == 'PLAYING' || state == 'TRANSITIONING';
}

class Sonos extends ChangeNotifier {
  Sonos._();
  static final instance = Sonos._();

  Room? output;
  Timer? _timer;

  Future<List<Room>> rooms() async {
    final all = (await api.call('GET', '/sonos') as List).map((e) => Room.fromJson(e as Map));
    final byName = <String, Room>{};
    for (final r in all) {
      final cur = byName[r.name];
      if (cur == null || (!cur.reachable && r.reachable)) byName[r.name] = r;
    }
    return byName.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  Future<void> playOn(Room room) async {
    final it = player.item;
    if (it == null) return;
    final pos = player.position;
    if (player.playing) await player.audio.pause();
    await api.call('POST', '/sonos/${room.id}/play', body: {'key': it.key, 'position_ms': player.live ? 0 : pos});
    output = room..state = 'PLAYING';
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
    notifyListeners();
  }

  Future<void> _refresh() async {
    final o = output;
    if (o == null) return;
    try {
      final r = (await api.call('GET', '/sonos') as List).map((e) => Room.fromJson(e as Map)).where((r) => r.id == o.id).firstOrNull;
      if (r != null && output != null) output = r;
    } catch (_) {}
    notifyListeners();
  }

  Future<void> toggle() async {
    final o = output;
    if (o == null) return;
    await api.call('POST', '/sonos/${o.id}/command', body: {'action': o.playing ? 'pause' : 'resume'});
    o.state = o.playing ? 'PAUSED_PLAYBACK' : 'PLAYING';
    notifyListeners();
  }

  Future<void> volume(int delta) async {
    final o = output;
    if (o == null) return;
    final v = ((o.volume ?? 15) + delta).clamp(0, 100);
    await api.call('POST', '/sonos/${o.id}/command', body: {'action': 'volume', 'volume': v});
    o.volume = v;
    notifyListeners();
  }

  /// Back to this device: the speaker pauses; its last position arrives via the server.
  Future<void> backToDevice() async {
    final o = output;
    if (o != null) {
      try {
        await api.call('POST', '/sonos/${o.id}/command', body: {'action': 'pause'});
      } catch (_) {}
    }
    output = null;
    _timer?.cancel();
    notifyListeners();
  }
}

final sonos = Sonos.instance;
