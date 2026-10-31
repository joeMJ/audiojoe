// Output to Sonos speakers: the server starts playback on the speaker, which fetches the
// stream itself; the app then only controls it. Rooms with several speakers (stereo
// pairs, surround) are shown once; grouping only ever moves whole rooms.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'player.dart';

class Room {
  final int id;
  final String name, model;
  final bool s2, reachable, visible;
  String? state, group, groupName;
  int? volume, groupVolume;
  List<int> groupRooms;
  Room(this.id, this.name, this.model, this.s2, this.reachable, this.state, this.volume,
      {this.visible = true, this.group, this.groupName, this.groupVolume, this.groupRooms = const []});

  static Room fromJson(Map j) => Room(j['id'] as int, j['name'] as String, (j['model'] ?? '') as String, (j['s2'] ?? true) as bool,
      (j['reachable'] ?? false) as bool, j['state'] as String?, j['volume'] as int?,
      visible: (j['visible'] ?? true) as bool,
      group: j['group'] as String?,
      groupName: j['group_name'] as String?,
      groupVolume: j['group_volume'] as int?,
      groupRooms: [for (final r in (j['group_rooms'] as List? ?? const [])) r as int]);

  bool get playing => state == 'PLAYING' || state == 'TRANSITIONING';
  bool get grouped => groupRooms.length > 1;

  /// "Badezimmer + Buero" when grouped, else "Sonos Buero".
  String get label => grouped ? groupName ?? name : 'Sonos $name';
}

class Sonos extends ChangeNotifier {
  Sonos._();
  static final instance = Sonos._();

  Room? output;

  /// All rooms from the last refresh (for the rooms of the output's group).
  List<Room> all = [];
  Timer? _timer, _send;
  int? _pending;
  bool _pendingGroup = true;
  Room? _pendingRoom;

  Future<List<Room>> rooms() async {
    final list = (await api.call('GET', '/sonos') as List).map((e) => Room.fromJson(e as Map)).where((r) => r.visible);
    final byName = <String, Room>{};
    for (final r in list) {
      final cur = byName[r.name];
      if (cur == null || (!cur.reachable && r.reachable)) byName[r.name] = r;
    }
    return all = byName.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  /// The rooms playing together with the output, the output first.
  List<Room> get members {
    final o = output;
    if (o == null) return const [];
    return [for (final id in o.groupRooms) ...all.where((r) => r.id == id)];
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
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final o = output;
    if (o == null) return;
    try {
      final r = (await rooms()).where((r) => r.id == o.id).firstOrNull;
      // While the slider is being moved, its value wins over the speaker's.
      if (r != null && output != null) {
        if (_send != null) {
          r.groupVolume = o.groupVolume;
          r.volume = o.volume;
        }
        output = r;
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> refresh() => _refresh();

  Future<void> toggle() async {
    final o = output;
    if (o == null) return;
    await api.call('POST', '/sonos/${o.id}/command', body: {'action': o.playing ? 'pause' : 'resume'});
    o.state = o.playing ? 'PAUSED_PLAYBACK' : 'PLAYING';
    notifyListeners();
  }

  /// Volume shown for the output: the group's when grouped.
  int get level => (output?.grouped ?? false) ? output?.groupVolume ?? output?.volume ?? 0 : output?.volume ?? 0;

  /// Sets the output's (group) volume, or one room's; while dragging at most five per second.
  void setVolume(int v, {Room? room}) {
    final o = output;
    if (o == null) return;
    v = v.clamp(0, 100);
    if (room == null) {
      if (o.grouped) {
        o.groupVolume = v;
      } else {
        o.volume = v;
      }
    } else {
      room.volume = v;
    }
    if (_send != null && (_pendingRoom?.id != room?.id || _pendingGroup != (room == null))) _flush();
    _pending = v;
    _pendingRoom = room;
    _pendingGroup = room == null;
    _send ??= Timer(const Duration(milliseconds: 200), _flush);
    notifyListeners();
  }

  void _flush() {
    _send?.cancel();
    _send = null;
    final v = _pending, o = output;
    if (v == null || o == null) return;
    _pending = null;
    final r = _pendingRoom;
    unawaited(api
        .call('POST', '/sonos/${r?.id ?? o.id}/command', body: {'action': r == null ? 'volume' : 'room_volume', 'volume': v})
        .catchError((_) => null));
  }

  void volume(int delta) => setVolume(level + delta);

  /// Adds a room to the output's group, or takes it out; pairs and home theatres move whole.
  Future<void> setInGroup(Room r, bool inGroup) async {
    final o = output;
    if (o == null || r.id == o.id) return;
    if (inGroup) {
      await api.call('POST', '/sonos/${r.id}/join', body: {'to': o.id});
    } else {
      await api.call('POST', '/sonos/${r.id}/leave');
    }
    await _refresh();
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
