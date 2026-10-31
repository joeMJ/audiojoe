// Playback positions: stored locally first, sent when the server is reachable; changes
// from other devices arrive via Server-Sent Events.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'models.dart';
import 'store.dart';

class Sync {
  Sync._();
  static final instance = Sync._();

  final pendingCount = ValueNotifier<int>(0);

  /// True once a position has waited more than 30 s for the server (online or not); saves that
  /// go through in time never show. Back to false as soon as nothing waits.
  final stale = ValueNotifier<bool>(false);
  Timer? _staleTimer;

  void _updateStale() {
    if (pendingCount.value == 0) {
      _staleTimer?.cancel();
      _staleTimer = null;
      stale.value = false;
    } else if (_staleTimer == null && !stale.value) {
      _staleTimer = Timer(const Duration(seconds: 30), () {
        _staleTimer = null;
        stale.value = pendingCount.value > 0;
      });
    }
  }
  final _remote = StreamController<Playback>.broadcast();
  Stream<Playback> get remote => _remote.stream;
  /// A continue list changed (on any device): the name of the list.
  final _lists = StreamController<String>.broadcast();
  Stream<String> get lists => _lists.stream;

  StreamSubscription<String>? _events;
  Timer? _probe;
  bool _flushing = false;

  Playback? localPosition(String key) {
    final j = Stores.positions.get(key);
    return j == null ? null : Playback.fromJson(j, key: key);
  }

  void savePosition(Playback p) {
    Stores.positions.put(p.key, p.toJson());
    Stores.pending.put(p.key, p.toJson());
    pendingCount.value = Stores.pending.data.length;
    unawaited(flush());
  }

  Future<void> flush() async {
    if (_flushing || !api.online.value || Stores.pending.data.isEmpty) return;
    _flushing = true;
    try {
      final list = Stores.pending.data.values.toList();
      await api.call('POST', '/playback', body: list);
      for (final u in list) {
        // Only remove what was sent; a newer local update keeps waiting.
        if (Stores.pending.get(u['key'] as String)?['updated_at'] == u['updated_at']) {
          Stores.pending.remove(u['key'] as String);
        }
      }
    } catch (_) {
      // stays pending
    } finally {
      _flushing = false;
      pendingCount.value = Stores.pending.data.length;
    }
  }

  void start() {
    pendingCount.addListener(_updateStale);
    pendingCount.value = Stores.pending.data.length;
    _updateStale();
    api.online.addListener(() {
      if (api.online.value) {
        unawaited(flush());
        if (_events == null) _connect();
      }
    });
    _connect();
    // While offline, check every 20 s whether the server is back.
    _probe = Timer.periodic(const Duration(seconds: 20), (_) async {
      if (api.online.value && _events != null) return;
      try {
        await api.call('GET', '/health');
      } catch (_) {}
    });
  }

  bool _connecting = false;

  Future<void> _connect() async {
    if (_connecting) return;
    _connecting = true;
    await _events?.cancel();
    _events = null;
    try {
      final req = http.Request('GET', api.uri('/events'))
        ..headers.addAll(api.authHeaders)
        ..headers['accept'] = 'text/event-stream';
      final res = await api.client.send(req);
      if (res.statusCode != 200) throw ApiError(res.statusCode, 'events');
      api.online.value = true;
      String event = '';
      _events = res.stream.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (line.startsWith('event:')) {
          event = line.substring(6).trim();
        } else if (line.startsWith('data:') && event == 'playback') {
          final p = Playback.fromJson((jsonDecode(line.substring(5))['state'] as Map).cast<String, dynamic>());
          Stores.positions.put(p.key, p.toJson());
          _remote.add(p);
        } else if (line.startsWith('data:') && event == 'lists') {
          _lists.add((jsonDecode(line.substring(5))['list'] ?? '') as String);
        }
      }, onDone: _lost, onError: (_) => _lost(), cancelOnError: true);
    } catch (_) {
      _lost();
    } finally {
      _connecting = false;
    }
  }

  void _lost() {
    _events = null;
    // Reconnect after a pause once the server answers again (else the probe timer does).
    Future.delayed(const Duration(seconds: 3), () => api.call('GET', '/health').then((_) => _connect(), onError: (_) {}));
  }

  Future<void> stop() async {
    _probe?.cancel();
    await _events?.cancel();
    _events = null;
  }
}

final sync = Sync.instance;
