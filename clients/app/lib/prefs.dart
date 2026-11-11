// Settings of the account, the same on all its devices (GET/PUT /api/v1/settings/playback); a copy
// on the device keeps them while offline.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'store.dart';
import 'sync.dart';

class PlaybackPrefs extends ChangeNotifier {
  PlaybackPrefs._() {
    _apply(Stores.device.get('playback_prefs'));
    sync.settings.listen((e) => _apply(e['playback'], save: true));
    sync.reconnected.listen((_) => unawaited(refresh()));
  }
  static final instance = PlaybackPrefs._();

  /// Continue podcasts / books 10 s earlier after another device or a pause of 5 minutes.
  bool rewindPodcasts = true;
  bool rewindBooks = true;

  void _apply(Object? v, {bool save = false}) {
    if (v is! Map) return;
    rewindPodcasts = v['rewind_podcasts'] != false;
    rewindBooks = v['rewind_books'] != false;
    if (save) Stores.device.put('playback_prefs', {'rewind_podcasts': rewindPodcasts, 'rewind_books': rewindBooks});
    notifyListeners();
  }

  Future<void> refresh() async {
    try {
      _apply(await api.call('GET', '/settings/playback'), save: true);
    } catch (_) {}
  }

  Future<void> set({bool? podcasts, bool? books}) async {
    final r = await api.call('PUT', '/settings/playback', body: {
      'rewind_podcasts': ?podcasts,
      'rewind_books': ?books,
    });
    _apply(r, save: true);
  }
}

final playbackPrefs = PlaybackPrefs.instance;

/// Sonos settings of the account (0.3.1, user 2026-11-11 „204 ja“, „205 ja“): the start volume the server sets when
/// playback starts on a speaker, and whether switched-off speakers are hidden in the output overlay.
class SonosPrefs extends ChangeNotifier {
  SonosPrefs._() {
    _apply(Stores.device.get('sonos_prefs'));
    sync.settings.listen((e) => _apply(e['sonos'], save: true));
    sync.reconnected.listen((_) => unawaited(refresh()));
  }
  static final instance = SonosPrefs._();

  int startVolume = 8;
  bool hideOff = true;

  void _apply(Object? v, {bool save = false}) {
    if (v is! Map) return;
    startVolume = (v['start_volume'] as num?)?.toInt() ?? 8;
    hideOff = v['hide_off'] != false;
    if (save) Stores.device.put('sonos_prefs', {'start_volume': startVolume, 'hide_off': hideOff});
    notifyListeners();
  }

  Future<void> refresh() async {
    try {
      _apply(await api.call('GET', '/settings/sonos'), save: true);
    } catch (_) {}
  }

  Future<void> set({int? startVolume, bool? hideOff}) async {
    final r = await api.call('PUT', '/settings/sonos', body: {
      'start_volume': ?startVolume,
      'hide_off': ?hideOff,
    });
    _apply(r, save: true);
  }
}

final sonosPrefs = SonosPrefs.instance;
