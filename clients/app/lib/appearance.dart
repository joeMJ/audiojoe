// Appearance per device: dark mode on or off; without a choice the system decides. Kept in the
// device store, so signing out does not reset it. On Linux and Windows the title bar follows.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'store.dart';

final appearance = ValueNotifier<ThemeMode>(_load());

ThemeMode _load() => switch (Stores.device.get('appearance')?['mode']) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

/// Dark mode as shown now: the own choice, else the system's.
bool isDark(BuildContext context) =>
    appearance.value == ThemeMode.dark ||
    (appearance.value == ThemeMode.system && MediaQuery.platformBrightnessOf(context) == Brightness.dark);

/// The moon button: dark mode on or off (as in the web app).
void toggleDark(BuildContext context) {
  appearance.value = isDark(context) ? ThemeMode.light : ThemeMode.dark;
  Stores.device.put('appearance', {'mode': appearance.value.name});
}

bool? _titleBarDark;

/// Tells the window (GTK header bar, Windows title bar) whether to be dark; only on change.
void syncTitleBar(bool dark) {
  if (!(Platform.isLinux || Platform.isWindows) || dark == _titleBarDark) return;
  _titleBarDark = dark;
  const MethodChannel('io.github.joemj.audiojoe/window').invokeMethod('dark', dark).catchError((_) => null);
}
