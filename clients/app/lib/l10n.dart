// Base language English; German translation. Keys are the English texts.
// The German table is generated from po/de.po (tools/i18n.py), shared with the web app.

import 'dart:ui';

import 'l10n_de.g.dart';

const _de = deStrings;

final bool isDe = PlatformDispatcher.instance.locale.languageCode == 'de';

String t(String s, [Map<String, Object> vars = const {}]) {
  var out = isDe ? (_de[s] ?? s) : s;
  vars.forEach((k, v) => out = out.replaceAll('{$k}', '$v'));
  return out;
}

String ago(String iso) {
  final s = DateTime.now().difference(DateTime.parse(iso)).inSeconds;
  if (s < 90) return t('just now');
  if (s < 3600) return t('{n} min ago', {'n': (s / 60).round()});
  if (s < 86400 * 2) return t('{n} h ago', {'n': (s / 3600).round()});
  return t('{n} days ago', {'n': (s / 86400).round()});
}

/// Local date and time of an ISO time, "02.11.2026, 13:05" (German) or "2026-11-02 13:05".
String when(String iso) {
  final d = DateTime.parse(iso).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${two(d.hour)}:${two(d.minute)}';
  return isDe ? '${two(d.day)}.${two(d.month)}.${d.year}, $time' : '${d.year}-${two(d.month)}-${two(d.day)} $time';
}

String clock(int ms) {
  final s = (ms / 1000).floor().clamp(0, 1 << 31);
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
  return '${h > 0 ? '$h:' : ''}$mm:${sec.toString().padLeft(2, '0')}';
}

String bytes(int n) {
  if (n >= 1 << 30) return '${(n / (1 << 30)).toStringAsFixed(1)} GB';
  if (n >= 1 << 20) return '${(n / (1 << 20)).round()} MB';
  return '${(n / 1024).round()} kB';
}
