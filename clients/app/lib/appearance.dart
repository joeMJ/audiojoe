// Appearance per device: automatic (follows the system), light or dark. Kept in the
// device store, so signing out does not reset it.

import 'package:flutter/material.dart';

import 'store.dart';

final appearance = ValueNotifier<ThemeMode>(_load());

ThemeMode _load() => switch (Stores.device.get('appearance')?['mode']) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

/// Next step of the moon button: automatic → light → dark → automatic.
void nextAppearance() {
  appearance.value = switch (appearance.value) {
    ThemeMode.system => ThemeMode.light,
    ThemeMode.light => ThemeMode.dark,
    ThemeMode.dark => ThemeMode.system,
  };
  Stores.device.put('appearance', {'mode': appearance.value.name});
}
