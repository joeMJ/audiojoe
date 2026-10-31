// Appearance per device: dark mode on or off; without a choice the system decides. Kept in the
// device store, so signing out does not reset it.

import 'package:flutter/material.dart';

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
