// Media volume of this device: the same the volume keys change. The slider sets it (at most
// five times per second while dragging) and follows the keys.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:volume_controller/volume_controller.dart';

class LocalVolume extends ChangeNotifier {
  LocalVolume._();
  static final instance = LocalVolume._();

  /// 0–100.
  int level = 50;
  StreamSubscription<double>? _sub;
  Timer? _send;
  int? _pending;

  void start() {
    if (_sub != null) return;
    try {
      VolumeController.instance.showSystemUI = false;
      _sub = VolumeController.instance.addListener((v) {
        // While the slider is being moved, its value wins.
        if (_send != null) return;
        level = (v * 100).round();
        notifyListeners();
      });
    } catch (_) {}
  }

  void set(int v) {
    level = v.clamp(0, 100);
    _pending = level;
    _send ??= Timer(const Duration(milliseconds: 200), _flush);
    notifyListeners();
  }

  void _flush() {
    _send = null;
    final v = _pending;
    _pending = null;
    if (v != null) unawaited(VolumeController.instance.setVolume(v / 100).catchError((_) {}));
  }
}

final localVolume = LocalVolume.instance;
