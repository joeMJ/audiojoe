// Base language English; German translation. Keys are the English texts.
// (Same strings as the web app; both will be generated from po/de.po.)

import 'dart:ui';

const _de = <String, String>{
  'Now playing': 'Jetzt läuft',
  'Continue': 'Weiterhören',
  'Podcasts': 'Podcasts',
  'Audiobooks': 'Hörbücher',
  'Music': 'Musik',
  'Offline': 'Offline',
  'Settings': 'Einstellungen',
  'Server reachable': 'Server erreichbar',
  'Offline · cache': 'Offline · Cache',
  'Positions synced': 'Stände aktuell',
  '{n} waiting to sync': '{n} warten auf Abgleich',
  'Sign in': 'Anmelden',
  'Server': 'Server',
  'User name': 'Benutzername',
  'Password': 'Kennwort',
  'Code from the authenticator app': 'Code aus der Authenticator-App',
  'Device name': 'Gerätename',
  'Sign-in failed. Check name, password and code.': 'Anmeldung fehlgeschlagen. Name, Kennwort und Code prüfen.',
  'Too many attempts. Please wait 15 minutes.': 'Zu viele Versuche. Bitte 15 Minuten warten.',
  'Server not reachable.': 'Server nicht erreichbar.',
  'Nothing is playing.': 'Es läuft nichts.',
  'Source': 'Quelle',
  'Here': 'Hier',
  'unchanged': 'unverändert',
  'from cache': 'aus dem Cache',
  'converted': 'umgerechnet',
  'Taken over from {device} · {ago}': 'Übernommen von {device} · {ago}',
  'Last on {device} · {ago}': 'Zuletzt auf {device} · {ago}',
  'Play': 'Abspielen',
  'Resume': 'Weiter',
  'Play all': 'Alle abspielen',
  'Save offline': 'Offline',
  'Remove': 'Entfernen',
  'New': 'Neu',
  'Subscribed': 'Abonniert',
  'Back': 'Zurück',
  'Nothing to continue.': 'Nichts zum Weiterhören.',
  'No podcasts subscribed yet.': 'Noch keine Podcasts abonniert.',
  'No sources yet. Add one in the settings.': 'Noch keine Quellen. In den Einstellungen hinzufügen.',
  'in cache': 'im Cache',
  'online only': 'nur online',
  'Nothing saved offline yet.': 'Noch nichts offline gespeichert.',
  'waiting': 'wartet',
  'loading {p}': 'lädt {p}',
  'ready': 'fertig',
  'failed': 'fehlgeschlagen',
  'missing – will reload': 'fehlt – wird nachgeladen',
  'Sign out this device': 'Dieses Gerät abmelden',
  'just now': 'gerade eben',
  '{n} min ago': 'vor {n} Min.',
  '{n} h ago': 'vor {n} Std.',
  '{n} days ago': 'vor {n} Tagen',
  'Error': 'Fehler',
  'Add podcast': 'Podcast hinzufügen',
  'Search or feed URL': 'Suche oder Feed-Adresse',
  'Subscribe': 'Abonnieren',
  'Unsubscribe': 'Abbestellen',
  'Sources': 'Quellen',
  'Add source': 'Quelle hinzufügen',
  'Kind': 'Art',
  'Name': 'Name',
  'Address': 'Adresse',
  'API key': 'API-Schlüssel',
  'Add': 'Hinzufügen',
  'Cancel': 'Abbrechen',
  'Devices': 'Geräte',
  'this device': 'dieses Gerät',
  'last seen {ago}': 'zuletzt {ago}',
  'Sign out': 'Abmelden',
  'Used {used}': 'Belegt {used}',
};

final bool _isDe = PlatformDispatcher.instance.locale.languageCode == 'de';

String t(String s, [Map<String, Object> vars = const {}]) {
  var out = _isDe ? (_de[s] ?? s) : s;
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
