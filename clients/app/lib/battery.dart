// Battery usage on Android (0.3.0, user 2026-11-10: after an update GrapheneOS set audiojoe to "Optimized",
// and playback stopped about 4 s after the app went to the background; „190–192 ja“): the app asks whether it
// is exempt from battery optimization ("Unrestricted") and warns once per app start when playback starts,
// and on Settings → Playback; "Change" opens the system question.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n.dart';
import 'main.dart' show messenger;

class BatteryUsage extends ChangeNotifier {
  BatteryUsage._() {
    if (Platform.isAndroid) {
      // Back from the system question or the settings: read again.
      _lifecycle = AppLifecycleListener(onResume: () => unawaited(refresh()));
    }
  }
  static final instance = BatteryUsage._();

  static const _channel = MethodChannel('io.github.joemj.audiojoe/battery');
  // ignore: unused_field
  AppLifecycleListener? _lifecycle;

  /// Exempt from battery optimization ("Unrestricted"); null: not known (yet) or not Android.
  bool? unrestricted;
  bool _warned = false;

  static String get warning => t('Battery optimization is on for audiojoe. Android may stop playback in the background. Set battery usage to Unrestricted.');

  Future<void> refresh() async {
    if (!Platform.isAndroid) return;
    try {
      final v = await _channel.invokeMethod<bool>('unrestricted');
      if (v != unrestricted) {
        // Exempt now (back from the system question): the message of this start goes away at once.
        if (v == true && unrestricted == false && _warned) messenger.currentState?.hideCurrentSnackBar();
        unrestricted = v;
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Opens the system question that exempts audiojoe from battery optimization.
  Future<void> request() async {
    try {
      await _channel.invokeMethod('request');
    } catch (_) {}
  }

  /// When playback starts: a message once per app start while battery optimization is on.
  Future<void> warnOnce() async {
    if (!Platform.isAndroid || _warned) return;
    await refresh();
    if (unrestricted != false || _warned) return;
    _warned = true;
    messenger.currentState?.showSnackBar(SnackBar(
      key: const ValueKey('battery-warning'),
      content: Text(warning),
      duration: const Duration(seconds: 12),
      action: SnackBarAction(label: t('Change'), onPressed: () => unawaited(request())),
    ));
  }
}

final battery = BatteryUsage.instance;
