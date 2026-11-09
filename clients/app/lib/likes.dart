// Likes (user 2026-11-09, "142–147 ja"): music titles marked with the heart in the player go to the
// continue list "likes" on the server; they stay there when heard. The heart is a switch: a second tap
// takes the title out again. Kept current from the server's "lists" events.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'models.dart';
import 'sync.dart';

class Likes extends ChangeNotifier {
  Likes._();
  static final instance = Likes._();

  Set<String> keys = {};
  bool _started = false;

  bool has(String key) => keys.contains(key);

  /// Only music titles can be liked (podcast episodes, books and radio keep the speed button).
  static bool likeable(Item it) => it.kind == 'track';

  Future<void> refresh() async {
    try {
      final l = await api.call('GET', '/lists/likes') as List;
      keys = {for (final e in l) (e as Map)['key'] as String};
      notifyListeners();
    } catch (_) {}
  }

  void start() {
    unawaited(refresh());
    if (_started) return;
    _started = true;
    sync.lists.listen((l) => l == 'likes' ? unawaited(refresh()) : null);
    sync.reconnected.listen((_) => unawaited(refresh()));
  }

  /// Adds the title to the likes or takes it out; shown at once, undone when the server refuses.
  Future<void> toggle(Item it) async {
    final on = !has(it.key);
    on ? keys.add(it.key) : keys.remove(it.key);
    notifyListeners();
    try {
      if (on) {
        await api.call('POST', '/lists/likes', body: {'key': it.key, 'title': it.title, 'subtitle': it.subtitle});
      } else {
        await api.call('DELETE', '/lists/likes/${Uri.encodeComponent(it.key)}');
      }
    } catch (e) {
      on ? keys.remove(it.key) : keys.add(it.key);
      notifyListeners();
      rethrow;
    }
  }
}

final likes = Likes.instance;
