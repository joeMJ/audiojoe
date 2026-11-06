// Settings: sources (Jellyfin, Audiobookshelf) and which of their libraries to show, music
// (reading in the album directory, labels from MusicBrainz), Sonos speakers, podcast import/export (OPML),
// signed-in devices, sign out, about. Phones: a list of the pages, a tap opens one; desktop: pages on the
// left, groups on the right.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../appearance.dart';
import '../downloads.dart';
import '../l10n.dart';
import '../prefs.dart';
import '../storage.dart';
import '../updates.dart';
import 'common.dart';

class SettingsView extends StatefulWidget {
  final VoidCallback onSignOut;
  const SettingsView({super.key, required this.onSignOut});
  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  int _gen = 0;
  int _page = 0;

  static Widget _h(String s) => Text(s, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800));

  Widget _addSource() => FilledButton.icon(
        icon: const Icon(Icons.add),
        label: Text(t('Add source')),
        onPressed: () async {
          if (await showDialog<bool>(context: context, builder: (_) => const AddSourceDialog()) == true) setState(() => _gen++);
        },
      );

  /// Each source with its libraries; on the desktop each in its own group.
  Widget _sources({bool grouped = false}) => Loader<List>(
        key: ValueKey('src$_gen'),
        load: () async => await api.call('GET', '/sources') as List,
        builder: (context, list, reload) => Column(children: [
          if (list.isEmpty) emptyText(context, t('No sources yet. Add one in the settings.')),
          for (final s in list.cast<Map>())
            _maybeGroup(grouped, [
              ItemRow(
                leading: Icon(s['kind'] == 'audiobookshelf' ? Icons.menu_book : Icons.library_music, size: 32),
                title: '${s['name']}',
                subtitle: '${s['kind']} · ${s['url']}',
                trailing: [
                  IconButton(
                    tooltip: t('Remove'),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await api.call('DELETE', '/sources/${s['id']}');
                      reload();
                    },
                  ),
                ],
              ),
              Libraries(source: s['id'] as int),
            ]),
        ]),
      );

  Widget _maybeGroup(bool grouped, List<Widget> children) =>
      grouped ? SettingsGroup(children: children) : Column(children: children);

  Widget _devices() => Loader<List>(
        key: ValueKey('dev$_gen'),
        load: () async => await api.call('GET', '/sessions') as List,
        builder: (context, list, reload) => Column(children: [
          for (final s in list.cast<Map>())
            ItemRow(
              leading: const Icon(Icons.devices, size: 32),
              title: '${s['device']}${s['current'] == true ? ' (${t('this device')})' : ''}',
              subtitle: t('last seen {ago}', {'ago': ago('${s['last_seen']}')}),
              trailing: [
                if (s['current'] != true)
                  TextButton(
                    onPressed: () async {
                      await api.call('DELETE', '/sessions/${s['id']}');
                      reload();
                    },
                    child: Text(t('Sign out')),
                  ),
              ],
            ),
        ]),
      );

  Widget _opml() => Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(icon: const Icon(Icons.file_upload_outlined), label: Text(t('Import OPML')), onPressed: _import),
        OutlinedButton.icon(icon: const Icon(Icons.file_download_outlined), label: Text(t('Export OPML')), onPressed: _export),
      ]);

  Widget _signOut() => OutlinedButton.icon(icon: const Icon(Icons.logout), label: Text(t('Sign out this device')), onPressed: widget.onSignOut);

  @override
  Widget build(BuildContext context) => desktop ? _desktop(context) : _phone(context);

  /// Phones: the pages as one list (mockup android-einstellungen, picture 1), each row with its state
  /// in one line; a tap opens the page, ← or the system back gesture returns to the list.
  int? _phonePage;

  Widget _phone(BuildContext context) {
    final p = _phonePage;
    return PopScope(
      canPop: p == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _phonePage = null);
      },
      child: p == null ? _overview(context) : _phoneSub(context, p),
    );
  }

  /// One line per page: sources and libraries, speakers, devices, versions; fixed text where nothing is counted.
  Future<Map<String, String>> _summary() async {
    final out = <String, String>{
      'podcasts': t('OPML, sync with podcast apps'),
      'playback': PlaybackSettings.summary(),
      'music': t('MusicBrainz labels'),
      'storage': t('Keep at least {n} GB free', {'n': storage.keepFreeGb}),
      'appearance': switch (appearance.value) {
        ThemeMode.light => t('Light'),
        ThemeMode.dark => t('Dark'),
        _ => t('System'),
      },
      'about': t('Version, guide, privacy, licences'),
    };
    Future<void> one(String i, Future<String> Function() f) async {
      try {
        out[i] = await f();
      } catch (_) {}
    }

    await Future.wait([
      one('sources', () async {
        final list = (await api.call('GET', '/sources') as List).cast<Map>();
        if (list.isEmpty) return t('No sources yet');
        var libs = 0;
        for (final s in list) {
          // Not every kind lists libraries (Audiobookshelf answers 400); the names still count.
          try {
            libs += (await api.call('GET', '/sources/${s['id']}/libraries') as List).length;
          } catch (_) {}
        }
        return '${list.map((s) => '${s['name']}').join(', ')} · ${t('{n} libraries', {'n': libs})}';
      }),
      one('sonos', () async {
        if ((await api.call('GET', '/sonos/setup') as Map)['enabled'] != true) return t('not set up');
        return t('{n} speakers', {'n': (await api.call('GET', '/sonos') as List).length});
      }),
      one('devices', () async => t('{n} signed in · sign out this device', {'n': (await api.call('GET', '/sessions') as List).length})),
      one('maintenance', () async {
        final m = await api.call('GET', '/maintenance') as Map;
        final app = (await PackageInfo.fromPlatform()).version;
        final latest = (m['status'] as Map?)?['latest'] as String?;
        final state = latest == null
            ? t('not checked yet')
            : compareVersions(latest, '${m['version']}') > 0 || compareVersions(latest, app) > 0
                ? t('update available')
                : t('up to date');
        return 'Server ${m['version']} · App $app · $state';
      }),
    ]);
    return out;
  }

  Widget _overview(BuildContext context) {
    final k = context.tok;
    return Loader<Map<String, String>>(
      key: ValueKey('sum$_gen'),
      load: _summary,
      builder: (context, sum, reload) => ListView(padding: const EdgeInsets.all(12), children: [
        _h(t('Settings')),
        const SizedBox(height: 8),
        for (final (i, (id, icon, label)) in _pages.indexed) ...[
          ListTile(
            key: ValueKey('settings-page-$id'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            leading: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: k.panel2, borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 20),
            ),
            title: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            subtitle: sum[id] == null ? null : Text(sum[id]!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: k.muted)),
            trailing: Icon(Icons.chevron_right, color: k.muted),
            onTap: () => setState(() => _phonePage = i),
          ),
          Divider(height: 1, color: k.line),
        ],
      ]),
    );
  }

  Widget _phoneSub(BuildContext context, int page) {
    return ListView(key: PageStorageKey('phone-settings$page'), padding: const EdgeInsets.fromLTRB(4, 4, 12, 12), children: [
      Row(children: [
        IconButton(tooltip: t('Back'), icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => _phonePage = null)),
        Expanded(child: _h(_pages[page].$3)),
      ]),
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ..._pageContent(context, page),
          if (page == 0) Align(alignment: Alignment.centerLeft, child: _addSource()),
        ]),
      ),
    ]);
  }

  /// The pages (mockup android-einstellungen); "Storage" in all apps (user 2026-11-04, moved forward
  /// from 0.2.0), "Appearance" on Android only (the desktop has the moon in the title bar).
  List<(String, IconData, String)> get _pages => [
        ('sources', Icons.storage, t('Sources')),
        ('podcasts', Icons.podcasts, t('Podcasts')),
        ('playback', Icons.replay_10, t('Playback')),
        ('music', Icons.library_music, t('Music')),
        ('sonos', Icons.speaker, t('Sonos')),
        ('storage', Icons.download_for_offline_outlined, t('Storage')),
        if (!desktop) ('appearance', Icons.dark_mode_outlined, t('Appearance')),
        ('devices', Icons.devices, t('Devices')),
        ('maintenance', Icons.system_update_alt, t('Maintenance')),
        ('about', Icons.info_outline, t('About')),
      ];

  List<Widget> _pageContent(BuildContext context, [int? page]) => switch (_pages[page ?? _page].$1) {
        'sources' => [_sources(grouped: true)],
        'podcasts' => [
            SettingsGroup(
              title: 'OPML',
              desc: t('Subscriptions as OPML file, the format other podcast apps read and write.'),
              children: [_opml()],
            ),
            SettingsGroup(title: t('Sync with other podcast apps'), children: [GpodderSettings(key: ValueKey('gpodder$_gen'))]),
          ],
        'playback' => [const PlaybackSettings()],
        'music' => [SettingsGroup(children: [MusicSettings(key: ValueKey('music$_gen'))])],
        'sonos' => [const SettingsGroup(children: [SonosSettings()])],
        'storage' => [const StorageSettings()],
        'appearance' => [const AppearanceSettings()],
        'devices' => [
            SettingsGroup(children: [_devices()]),
            SettingsGroup(children: [Align(alignment: Alignment.centerLeft, child: _signOut())]),
          ],
        'maintenance' => [MaintenanceSettings(key: ValueKey('maint$_gen'))],
        _ => [
            const SettingsGroup(children: [AboutPanel()]),
            // As in tvjoe (prefs.rs, group "Mitwirkende").
            SettingsGroup(title: t('Contributors'), children: [
              const ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('John Lose (joeMJ)', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('© 2026 John Lose · Apache-2.0'),
              ),
            ]),
          ],
      };

  Widget _desktop(BuildContext context) {
    final k = context.tok, scheme = Theme.of(context).colorScheme;
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        width: 200,
        decoration: BoxDecoration(color: scheme.surface, border: Border(right: BorderSide(color: k.line))),
        child: ListView(padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8), children: [
          for (final (i, (id, icon, label)) in _pages.indexed)
            Padding(
              key: ValueKey('settings-page-$id'),
              padding: const EdgeInsets.only(bottom: 2),
              child: Material(
                color: i == _page ? k.panel2 : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setState(() => _page = i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    child: Row(children: [
                      Icon(icon, size: 20, color: i == _page ? scheme.primary : null),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(label, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 15, fontWeight: i == _page ? FontWeight.w700 : FontWeight.w500, color: i == _page ? scheme.primary : null)),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      ),
      Expanded(
        child: ListView(key: PageStorageKey('settings$_page'), padding: const EdgeInsets.fromLTRB(20, 16, 20, 16), children: [
          Row(children: [_h(_pages[_page].$3), const Spacer(), if (_page == 0) _addSource()]),
          const SizedBox(height: 12),
          ..._pageContent(context),
        ]),
      ),
    ]);
  }

  void _say(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _import() async {
    final picked = await FilePicker.pickFiles(dialogTitle: t('Import OPML'));
    if (picked.isEmpty) return;
    final bytes = await picked.first.xFile.readAsBytes();
    _say(t('Importing …'));
    try {
      final r = await api.call('POST', '/podcasts/opml', text: utf8.decode(bytes, allowMalformed: true), timeout: const Duration(minutes: 10)) as Map;
      final failed = (r['failed'] as List).length;
      _say(t('{added} added, {existing} already subscribed, {failed} failed',
          {'added': r['added'], 'existing': r['existing'], 'failed': failed}));
    } catch (e) {
      _say('${t('Error')}: $e');
    }
  }

  Future<void> _export() async {
    try {
      final bytes = utf8.encode(await api.call('GET', '/podcasts/opml') as String);
      final where = await FilePicker.saveFile(
          dialogTitle: t('Export OPML'), fileName: 'audiojoe.opml', mimeType: 'text/x-opml', bytes: bytes);
      if (where == null) return;
      _say(t('Saved: {path}', {'path': where.scheme == 'file' ? where.toFilePath() : 'audiojoe.opml'}));
    } catch (e) {
      _say('${t('Error')}: $e');
    }
  }
}

class AddSourceDialog extends StatefulWidget {
  const AddSourceDialog({super.key});
  @override
  State<AddSourceDialog> createState() => _AddSourceDialogState();
}

class _AddSourceDialogState extends State<AddSourceDialog> {
  String kind = 'jellyfin';
  final name = TextEditingController(), url = TextEditingController(), key = TextEditingController();
  String error = '';
  bool busy = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(t('Add source')),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              initialValue: kind,
              decoration: InputDecoration(labelText: t('Kind')),
              items: const [
                DropdownMenuItem(value: 'jellyfin', child: Text('Jellyfin')),
                DropdownMenuItem(value: 'audiobookshelf', child: Text('Audiobookshelf')),
                DropdownMenuItem(value: 'emby', child: Text('Emby')),
                DropdownMenuItem(value: 'plex', child: Text('Plex')),
              ],
              onChanged: (v) => setState(() => kind = v!),
            ),
            const SizedBox(height: 10),
            TextField(controller: name, decoration: InputDecoration(labelText: t('Name'))),
            const SizedBox(height: 10),
            TextField(controller: url, decoration: InputDecoration(labelText: t('Address'), hintText: 'https://media.example.org')),
            const SizedBox(height: 10),
            TextField(controller: key, obscureText: true, decoration: InputDecoration(labelText: kind == 'plex' ? 'X-Plex-Token' : t('API key'))),
            if (busy) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator()),
            if (error.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text(error, style: TextStyle(color: context.tok.bad))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t('Cancel'))),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() => (busy = true, error = ''));
                    try {
                      await api.call('POST', '/sources', body: {'kind': kind, 'name': name.text, 'url': url.text, 'api_key': key.text});
                      if (context.mounted) Navigator.pop(context, true);
                    } catch (e) {
                      setState(() => (busy = false, error = '$e'));
                    }
                  },
            child: Text(t('Add')),
          ),
        ],
      );
}

/// The libraries of one source, each with a switch; hidden ones are left out on all devices.
class Libraries extends StatelessWidget {
  final int source;
  const Libraries({super.key, required this.source});

  @override
  Widget build(BuildContext context) => Loader<List>(
        load: () async => await api.call('GET', '/sources/$source/libraries') as List,
        builder: (context, list, reload) => list.length < 2
            ? const SizedBox.shrink()
            : ExpansionTile(
                tilePadding: const EdgeInsets.only(left: 56, right: 8),
                title: Text(t('Libraries ({shown} of {n} shown)',
                    {'shown': list.where((l) => l['hidden'] != true).length, 'n': list.length})),
                children: [
                  for (final l in list.cast<Map>())
                    SwitchListTile(
                      contentPadding: const EdgeInsets.only(left: 56, right: 8),
                      title: Text('${l['title']}'),
                      value: l['hidden'] != true,
                      onChanged: (show) async {
                        await api.call('PUT', '/sources/$source/libraries/${Uri.encodeComponent('${l['id']}')}', body: {'hidden': !show});
                        reload();
                      },
                    ),
                ],
              ),
      );
}

/// How often the album directory is read in again, "Read in again now", and labels from
/// MusicBrainz (off unless switched on; it asks for a contact address MusicBrainz wants).
class MusicSettings extends StatefulWidget {
  const MusicSettings({super.key});
  @override
  State<MusicSettings> createState() => _MusicSettingsState();
}

class _MusicSettingsState extends State<MusicSettings> {
  final contact = TextEditingController();
  bool busy = false;

  @override
  void dispose() {
    contact.dispose();
    super.dispose();
  }

  void _say(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _refresh() async {
    setState(() => busy = true);
    var n = 0;
    try {
      final sources = (await api.call('GET', '/sources') as List).cast<Map>().where((s) => ['jellyfin', 'emby', 'plex'].contains(s['kind']));
      for (final s in sources) {
        for (final l in (await api.call('GET', '/sources/${s['id']}/libraries') as List).cast<Map>()) {
          if (l['hidden'] == true) continue;
          final r = await api.call('POST', '/sources/${s['id']}/music/refresh',
              query: {'parent': '${l['id']}'}, timeout: const Duration(minutes: 5)) as Map;
          n += r['albums'] as int;
        }
      }
      _say(t('{n} albums read in.', {'n': n}));
    } catch (e) {
      _say('${t('Error')}: $e');
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Loader<Map>(
        load: () async {
          final m = await api.call('GET', '/settings/music') as Map;
          contact.text = '${m['musicbrainz_contact'] ?? ''}';
          return m;
        },
        builder: (context, m, reload) {
          Future<void> put(Map<String, dynamic> body) async {
            try {
              await api.call('PUT', '/settings/music', body: body);
            } catch (e) {
              _say('${t('Error')}: $e');
            }
            reload();
          }

          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('Read in the album directory again'), style: TextStyle(color: context.tok.muted)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: 'daily', label: Text(t('Daily'))),
                  ButtonSegment(value: 'weekly', label: Text(t('Weekly'))),
                  ButtonSegment(value: 'manual', label: Text(t('Only by hand'))),
                ],
                selected: {'${m['refresh']}'},
                onSelectionChanged: (v) => put({'refresh': v.first}),
              ),
              OutlinedButton.icon(
                icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh),
                label: Text(t('Read in again now')),
                onPressed: busy ? null : _refresh,
              ),
            ]),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('Labels from MusicBrainz')),
              subtitle: Text(t('Asks musicbrainz.org for the label of albums whose files name none. Only the release id is sent, with your contact address, which MusicBrainz asks for; at most one request per second.')),
              value: m['musicbrainz'] == true,
              onChanged: (on) {
                if (on && contact.text.trim().isEmpty) {
                  _say(t('Enter a contact address first.'));
                  return;
                }
                put({'musicbrainz': on, 'musicbrainz_contact': contact.text.trim()});
              },
            ),
            TextField(
              controller: contact,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(labelText: t('Contact for MusicBrainz (e-mail or web address)')),
              onSubmitted: (v) => put({'musicbrainz_contact': v.trim()}),
            ),
          ]);
        },
      );
}

/// Continue 10 s earlier, per kind, for the account (user 2026-11-06: two switches, on by default,
/// 10 s and 5 minutes fixed).
class PlaybackSettings extends StatefulWidget {
  const PlaybackSettings({super.key});

  /// "10 s back: Podcasts, Audiobooks" for the overview.
  static String summary() {
    final on = [if (playbackPrefs.rewindPodcasts) t('Podcasts'), if (playbackPrefs.rewindBooks) t('Audiobooks')];
    return on.isEmpty ? t('10 s back: off') : t('10 s back: {list}', {'list': on.join(', ')});
  }

  @override
  State<PlaybackSettings> createState() => _PlaybackSettingsState();
}

class _PlaybackSettingsState extends State<PlaybackSettings> {
  @override
  void initState() {
    super.initState();
    playbackPrefs.addListener(_changed);
    unawaited(playbackPrefs.refresh());
  }

  @override
  void dispose() {
    playbackPrefs.removeListener(_changed);
    super.dispose();
  }

  void _changed() => mounted ? setState(() {}) : null;

  Future<void> _set({bool? podcasts, bool? books}) async {
    try {
      await playbackPrefs.set(podcasts: podcasts, books: books);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${t('Error')}: $e')));
    }
  }

  @override
  Widget build(BuildContext context) => SettingsGroup(
        title: t('Continue 10 s earlier'),
        desc: t('When you continue on another device or after a pause of 5 minutes or more, playback starts 10 seconds earlier. Applies to all your devices.'),
        children: [
          SwitchListTile(
            key: const ValueKey('rewind-podcasts'),
            contentPadding: EdgeInsets.zero,
            title: Text(t('Podcasts')),
            value: playbackPrefs.rewindPodcasts,
            onChanged: (v) => _set(podcasts: v),
          ),
          SwitchListTile(
            key: const ValueKey('rewind-books'),
            contentPadding: EdgeInsets.zero,
            title: Text(t('Audiobooks')),
            value: playbackPrefs.rewindBooks,
            onChanged: (v) => _set(books: v),
          ),
        ],
      );
}

/// Server updates (nightly at 04:00 or only reported), Debian updates and database backups, as
/// `audiojoe-update` on the server last reported them.
class MaintenanceSettings extends StatefulWidget {
  const MaintenanceSettings({super.key});

  /// How long "Check for updates" waits for the script's answer, and how often it asks.
  static Duration checkWait = const Duration(seconds: 90), checkEvery = const Duration(seconds: 2);
  @override
  State<MaintenanceSettings> createState() => _MaintenanceSettingsState();
}

/// The app's filled buttons are 56 high (touch size); on this page they stand next to outlined
/// and segmented buttons (40), so all of them are 40 here.
final _pflegeButton = FilledButton.styleFrom(minimumSize: const Size(64, 40));

class _MaintenanceSettingsState extends State<MaintenanceSettings> {
  int _gen = 0;
  bool _checking = false;

  void _say(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _call(String method, String path, [Map<String, dynamic>? body, String? done]) async {
    try {
      await api.call(method, path, body: body);
      if (done != null) _say(done);
    } catch (e) {
      _say('${t('Error')}: $e');
    }
    if (mounted) setState(() => _gen++);
  }

  /// "Check for updates": the script looks for the newest release now (server and apps); the
  /// view waits until the status shows the new check, then shows it (button "Install now" when
  /// the server is behind, the app row offers a newer app).
  Future<void> _check(Map m) async {
    final before = (m['status'] as Map?)?['checked_at'];
    setState(() => _checking = true);
    try {
      await api.call('POST', '/maintenance/check');
      final end = DateTime.now().add(MaintenanceSettings.checkWait);
      var done = false;
      while (!done && DateTime.now().isBefore(end) && mounted) {
        await Future.delayed(MaintenanceSettings.checkEvery);
        final n = await api.call('GET', '/maintenance') as Map;
        done = n['request'] == null && n['requested'] != true && (n['status'] as Map?)?['checked_at'] != before;
      }
      if (!done) _say(t('The check takes longer; the result appears here later.'));
    } catch (e) {
      _say('${t('Error')}: $e');
    }
    if (mounted) {
      setState(() {
        _checking = false;
        _gen++;
      });
    }
  }

  /// "Last server update": from → to, when, and how it ended.
  String _lastUpdate(Map? last) {
    if (last == null) return '–';
    final base = t('{from} → {to} on {when}', {'from': '${last['from'] ?? '–'}', 'to': '${last['to']}', 'when': when('${last['at']}')});
    return switch (last['result']) {
      'rolled_back' => '$base · ${t('did not start, back on {v}', {'v': '${last['from']}'})}',
      'failed' => '$base · ${t('failed')}',
      _ => base,
    };
  }

  /// "{date} – n packages (a, b)" of a Debian log entry, null without one.
  String? _debian(Map? e, {bool removed = false}) {
    final pkgs = ((e?['packages'] as List?) ?? const []).cast<String>();
    if (e == null || pkgs.isEmpty) return null;
    final at = e['at'] == null ? '' : '${when('${e['at']}')} – ';
    final n = pkgs.length;
    final count = removed
        ? (n == 1 ? t('1 package removed') : t('{n} packages removed', {'n': n}))
        : (n == 1 ? t('1 package') : t('{n} packages', {'n': n}));
    return '$at$count (${pkgs.join(', ')})';
  }

  @override
  Widget build(BuildContext context) => Loader<Map>(
        key: ValueKey('m$_gen'),
        load: () async => {...await api.call('GET', '/maintenance') as Map, 'app_version': (await PackageInfo.fromPlatform()).version},
        builder: (context, m, reload) {
          final k = context.tok;
          final muted = TextStyle(color: k.muted);
          final apps = m['apps'] as Map?;
          final app = SettingsGroup(title: t('App'), children: [_AppUpdateRow(latest: apps?['latest'] as String?, say: _say)]);
          if (m['managed'] != true) {
            // A server before 0.1.3 without a status file also reports "not managed", although its
            // update script installs the newest release on request ("check" fails there, so only
            // "update"). Offered when the server is older than this app.
            final older = compareVersions('${m['version']}', '${m['app_version']}') < 0;
            final requested = m['request'] == 'now' || (m['request'] == null && m['requested'] == true);
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SettingsGroup(title: t('Server'), children: [
                KeyValue(t('Installed'), Text('${m['version']}')),
                if (older) KeyValue(t('Available'), Text(t('unknown – not checked yet'))),
                const SizedBox(height: 6),
                if (!older) Text(t('Updates are not managed here (server not installed from the package, see the installation guide).'), style: muted),
                if (older)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(style: _pflegeButton, 
                      icon: const Icon(Icons.system_update_alt),
                      label: Text(requested ? t('Update requested') : t('Update server now')),
                      onPressed: requested ? null : () => _call('POST', '/maintenance/update', null, t('Update started; the server restarts briefly.')),
                    ),
                  ),
              ]),
              app,
            ]);
          }
          final st = m['status'] as Map?;
          final running = '${m['version']}';
          final latest = st?['latest'] as String?;
          final newer = latest != null && compareVersions(latest, running) > 0;
          final deb = (st?['debian'] as Map?) ?? const {};
          final backups = ((st?['backups'] as List?) ?? const []).cast<Map>();
          final installRequested = m['request'] == 'now' || (m['request'] == null && m['requested'] == true);
          final checking = _checking || m['request'] == 'check';
          // Before 0.1.3 the status only had the package list of the last Debian update.
          final upgraded = _debian(deb['last_upgrade'] as Map?) ??
              (((deb['upgraded'] as List?) ?? const []).isNotEmpty ? (deb['upgraded'] as List).join(', ') : null);
          final removed = _debian(deb['last_removal'] as Map?, removed: true);
          final failed = st?['result'] == 'failed';

          final check = checking
              ? OutlinedButton.icon(
                  icon: const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5)),
                  label: Text(t('Checking …')),
                  onPressed: null)
              : newer
                  ? OutlinedButton.icon(icon: const Icon(Icons.refresh), label: Text(t('Check for updates')), onPressed: installRequested ? null : () => _check(m))
                  : FilledButton.icon(style: _pflegeButton, icon: const Icon(Icons.refresh), label: Text(t('Check for updates')), onPressed: installRequested ? null : () => _check(m));
          final install = installRequested
              ? FilledButton.icon(style: _pflegeButton, icon: const Icon(Icons.system_update_alt), label: Text(t('Update requested')), onPressed: null)
              : newer && !checking
                  ? FilledButton.icon(style: _pflegeButton, 
                      icon: const Icon(Icons.system_update_alt),
                      label: Text(t('Update server now to {v}', {'v': latest})),
                      onPressed: () => _call('POST', '/maintenance/update', null, t('Update started; the server restarts briefly.')),
                    )
                  : OutlinedButton.icon(icon: const Icon(Icons.system_update_alt), label: Text(t('Update server now')), onPressed: null);

          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SettingsGroup(title: t('Server'), children: [
              KeyValue(t('Installed'), Text(running)),
              KeyValue(
                t('Available'),
                latest == null
                    ? Text(t('unknown – not checked yet'))
                    : Row(children: [Text(latest), if (newer) ...[const SizedBox(width: 8), Badge2(t('newer'), kind: 'warn')]]),
              ),
              KeyValue(t('Last checked'), Text(st?['checked_at'] == null ? t('never') : '${when('${st!['checked_at']}')} (${ago('${st['checked_at']}')})')),
              KeyValue(t('Last server update'), Text(_lastUpdate(st?['last_update'] as Map?))),
              KeyValue(
                t('Database backups'),
                Text(backups.isEmpty ? t('none') : t('{n}, latest on {when}', {'n': backups.length, 'when': when('${backups.first['at']}')})),
              ),
              if (failed)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(t('Last check or update failed: {msg}', {'msg': '${st!['message']}'}), style: TextStyle(color: k.bad, fontWeight: FontWeight.w700)),
                ),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                check,
                install,
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: 'auto', label: Text(t('Update at 04:00'))),
                    ButtonSegment(value: 'notify', label: Text(t('Only report'))),
                  ],
                  selected: {'${m['mode']}'},
                  onSelectionChanged: (v) => _call('PUT', '/maintenance', {'mode': v.first}),
                ),
              ]),
            ]),
            SettingsGroup(title: t('Debian'), children: [
              KeyValue(t('Updates last installed'), Text(upgraded ?? t('not yet'))),
              KeyValue(t('Last cleaned up'), Text(removed ?? t('not yet'))),
              KeyValue(t('Waiting updates'), Text(deb['pending'] == null ? t('unknown') : '${deb['pending']}')),
              KeyValue(
                t('Automatic'),
                Row(children: [
                  Flexible(child: Text(deb['automatic'] == true ? t('install and clean up daily') : t('not set up'))),
                  const SizedBox(width: 8),
                  deb['automatic'] == true ? Badge2(t('on'), kind: 'ok') : Badge2(t('off')),
                ]),
              ),
            ]),
            app,
          ]);
        },
      );
}

/// A label and its value in one line; on narrow screens the value goes below the label.
class KeyValue extends StatelessWidget {
  final String label;
  final Widget value;
  const KeyValue(this.label, this.value, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: LayoutBuilder(builder: (context, c) {
          final l = Text(label, style: TextStyle(color: context.tok.muted));
          if (c.maxWidth < 440) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [l, value]);
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 220, child: l), Expanded(child: value)]);
        }),
      );
}

/// gpodder-compatible sync (AntennaPod, Kasts …): an app password for those clients, shown
/// once; the devices that synced so far; switching off ends their access.
class GpodderSettings extends StatefulWidget {
  const GpodderSettings({super.key});
  @override
  State<GpodderSettings> createState() => _GpodderSettingsState();
}

class _GpodderSettingsState extends State<GpodderSettings> {
  int _gen = 0;

  void _say(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _newPassword() async {
    Map r;
    try {
      r = await api.call('POST', '/gpodder/password') as Map;
    } catch (e) {
      return _say('${t('Error')}: $e');
    }
    if (!mounted) return;
    final host = Uri.parse(api.base).host;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('App password for podcast apps')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t('Enter these in the other app under gpodder.net sync (custom server). The password is shown only once.'),
              style: TextStyle(color: context.tok.muted)),
          const SizedBox(height: 12),
          Text(t('Server'), style: const TextStyle(fontWeight: FontWeight.w700)),
          SelectableText(host),
          const SizedBox(height: 8),
          Text(t('User name'), style: const TextStyle(fontWeight: FontWeight.w700)),
          SelectableText('${r['username']}'),
          const SizedBox(height: 8),
          Text(t('Password'), style: const TextStyle(fontWeight: FontWeight.w700)),
          SelectableText('${r['password']}', style: const TextStyle(fontFamily: 'monospace', fontSize: 18)),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t('Done')))],
      ),
    );
    if (mounted) setState(() => _gen++);
  }

  Future<void> _off() async {
    try {
      await api.call('DELETE', '/gpodder/password');
      _say(t('Sync switched off; the other apps are signed out.'));
    } catch (e) {
      _say('${t('Error')}: $e');
    }
    if (mounted) setState(() => _gen++);
  }

  @override
  Widget build(BuildContext context) => Loader<Map>(
        key: ValueKey('g$_gen'),
        load: () async => await api.call('GET', '/gpodder') as Map,
        builder: (context, g, reload) {
          final muted = TextStyle(color: context.tok.muted);
          final on = g['enabled'] == true;
          final devices = ((g['devices'] as List?) ?? const []).cast<Map>();
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('Subscriptions and listening positions shared with AntennaPod, Kasts and other apps that know gpodder.net sync. Those apps sign in with user name and a separate app password (no code from the authenticator).'),
                style: muted),
            const SizedBox(height: 8),
            Text(
              !on
                  ? t('Switched off.')
                  : devices.isEmpty
                      ? t('Switched on; no app has synced yet.')
                      : t('Switched on. Apps: {list}', {'list': devices.map((d) => (d['caption'] as String).isEmpty ? d['id'] : '${d['caption']} (${d['id']})').join(', ')}),
              style: muted,
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(icon: const Icon(Icons.key), label: Text(on ? t('New app password') : t('Switch on, create app password')), onPressed: _newPassword),
              if (on) OutlinedButton.icon(icon: const Icon(Icons.sync_disabled), label: Text(t('Switch off')), onPressed: _off),
            ]),
          ]);
        },
      );
}

/// This app: running and available version (the newest release the server knows) and the
/// download, github build only.
class _AppUpdateRow extends StatefulWidget {
  final String? latest;
  final void Function(String) say;
  const _AppUpdateRow({required this.latest, required this.say});
  @override
  State<_AppUpdateRow> createState() => _AppUpdateRowState();
}

class _AppUpdateRowState extends State<_AppUpdateRow> {
  late final Future<(String, AppUpdate?)> info = _load();

  Future<(String, AppUpdate?)> _load() async {
    final v = (await PackageInfo.fromPlatform()).version;
    AppUpdate? u;
    if (appUpdatesEnabled) {
      try {
        u = await checkAppUpdate();
      } catch (_) {}
    }
    return (v, u);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<(String, AppUpdate?)>(
        future: info,
        builder: (context, snap) {
          final (v, u) = snap.data ?? ('…', null);
          final latest = widget.latest;
          final android = Platform.isAndroid;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            KeyValue(t('Installed'), Text(v)),
            KeyValue(
              t('Available'),
              !appUpdatesEnabled
                  ? Text(t('Updates come from F-Droid.'))
                  : latest == null
                      ? Text(t('unknown – only after “Check for updates”'))
                      : Row(children: [Text(u?.latest ?? latest), if (u != null) ...[const SizedBox(width: 8), Badge2(t('newer'), kind: 'warn')]]),
            ),
            if (appUpdatesEnabled)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: u != null
                      ? FilledButton.icon(style: _pflegeButton, 
                          icon: const Icon(Icons.download),
                          label: Text(android ? t('Install version {v}', {'v': u.latest}) : t('Download version {v}', {'v': u.latest})),
                          onPressed: () => runAppUpdate(u, widget.say),
                        )
                      : OutlinedButton.icon(
                          icon: const Icon(Icons.download),
                          label: Text(android ? t('Install version') : t('Download version')),
                          onPressed: null,
                        ),
                ),
              ),
          ]);
        },
      );
}

/// Sonos speakers of the server: add by address, search the configured range, remove.
/// Speakers are shared by all users; the server needs a stream port for them (`[sonos] listen`).
class SonosSettings extends StatefulWidget {
  const SonosSettings({super.key});
  @override
  State<SonosSettings> createState() => _SonosSettingsState();
}

class _SonosSettingsState extends State<SonosSettings> {
  final ip = TextEditingController();
  bool busy = false;
  int _gen = 0;

  void _say(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _run(Future<String> Function() f) async {
    setState(() => busy = true);
    try {
      _say(await f());
    } catch (e) {
      _say('${t('Error')}: $e');
    }
    if (mounted) {
      setState(() {
        busy = false;
        _gen++;
      });
    }
  }

  @override
  void dispose() {
    ip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Loader<List>(
        key: ValueKey('sonos$_gen'),
        load: () async => [await api.call('GET', '/sonos/setup') as Map, await api.call('GET', '/sonos') as List],
        builder: (context, data, reload) {
          final setup = data[0] as Map;
          final speakers = (data[1] as List).cast<Map>()..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
          if (setup['enabled'] != true) {
            return Text(t('Sonos is not set up on this server (stream port missing in the configuration, see the installation guide).'),
                style: TextStyle(color: context.tok.muted));
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final sp in speakers)
              ItemRow(
                leading: Icon(sp['reachable'] == true ? Icons.speaker : Icons.speaker_outlined, size: 32),
                title: '${sp['name']}',
                subtitle: [
                  '${sp['model']}',
                  '${sp['ip']}',
                  sp['s2'] == true ? 'S2' : 'S1',
                  if (sp['reachable'] != true) t('not reachable'),
                ].where((x) => x.isNotEmpty).join(' · '),
                trailing: [
                  IconButton(
                    tooltip: t('Remove'),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: busy ? null : () => _run(() async {
                      await api.call('DELETE', '/sonos/${sp['id']}');
                      return t('Removed: {name}', {'name': '${sp['name']}'});
                    }),
                  ),
                ],
              ),
            if (speakers.isEmpty) emptyText(context, t('No speakers yet.')),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SizedBox(
                width: 200,
                child: TextField(
                  controller: ip,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: t('IP address of the speaker'), hintText: '192.0.2.40'),
                ),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: Text(t('Add speaker')),
                onPressed: busy ? null : () => _run(() async {
                  final r = await api.call('POST', '/sonos', body: {'ip': ip.text.trim()}) as Map;
                  ip.clear();
                  return t('Added: {name}', {'name': '${r['name']}'});
                }),
              ),
              if (setup['scan'] != null)
                OutlinedButton.icon(
                  icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.search),
                  label: Text(t('Search {range}', {'range': '${setup['scan']}'})),
                  onPressed: busy ? null : () => _run(() async {
                    final found = await api.call('POST', '/sonos/scan', timeout: const Duration(minutes: 2)) as List;
                    return t('{n} speakers found', {'n': found.length});
                  }),
                ),
            ]),
          ]);
        },
      );
}

/// Version of app and server, licence, and the manual and privacy notes the server delivers.
/// A framed group on a settings page (desktop): optional title and one sentence, then the rows.
class SettingsGroup extends StatelessWidget {
  final String? title, desc;
  final List<Widget> children;
  const SettingsGroup({super.key, this.title, this.desc, required this.children});

  @override
  Widget build(BuildContext context) {
    final k = context.tok;
    // Material, not a coloured box: list tiles inside paint their ink on it.
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(side: BorderSide(color: k.line), borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (title != null) Text(title!, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            if (desc != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(desc!, style: TextStyle(color: k.muted))),
            if (title != null || desc != null) const SizedBox(height: 10),
            ...children,
          ]),
        ),
      ),
    );
  }
}

/// Versions, manual, privacy and licences: the page "About" on the desktop, the dialog on phones.
class AboutPanel extends StatelessWidget {
  const AboutPanel({super.key});

  static Future<(String, String)> _versions() async {
    final app = (await PackageInfo.fromPlatform()).version;
    String server = '';
    try {
      server = ((await api.call('GET', '/health') as Map)['version'] ?? '') as String;
    } catch (_) {}
    return (app, server);
  }

  /// Troubleshooting lives on GitHub only: it must work while the own server is unreachable.
  static Widget _troubleshooting() => TextButton.icon(
        icon: const Icon(Icons.open_in_new, size: 18),
        label: Text(t('Troubleshooting')),
        onPressed: () => launchUrl(Uri.parse(troubleshootingUrl), mode: LaunchMode.externalApplication),
      );

  static Widget _link(String label, String page) => TextButton.icon(
        icon: const Icon(Icons.open_in_new, size: 18),
        label: Text(label),
        onPressed: () => launchUrl(Uri.parse('${api.base}/docs/${isDe ? 'de/' : ''}$page.html'), mode: LaunchMode.externalApplication),
      );

  @override
  Widget build(BuildContext context) => FutureBuilder(
        future: _versions(),
        builder: (context, snap) {
          final (app, server) = snap.data ?? ('', '');
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Image.asset('assets/icon.png', width: 48, height: 48),
              const SizedBox(width: 12),
              const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('audiojoe', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                // Developer below the name, as in tvjoe (prefs.rs, about page head).
                Text('John Lose (joeMJ)'),
              ]),
            ]),
            const SizedBox(height: 10),
            Text([
              if (app.isNotEmpty) t('App {v}', {'v': app}),
              if (server.isNotEmpty) t('Server {v}', {'v': server}),
            ].join(' · ')),
            const SizedBox(height: 4),
            Text(t('Licence: Apache 2.0'), style: TextStyle(color: context.tok.muted)),
            const SizedBox(height: 8),
            _link(t('Manual'), 'manual'),
            _link(t('Privacy'), 'privacy'),
            _troubleshooting(),
            TextButton.icon(
              icon: const Icon(Icons.description_outlined, size: 18),
              label: Text(t('Third-party licences')),
              onPressed: () => showLicensePage(context: context, applicationName: 'audiojoe', applicationVersion: app),
            ),
          ]);
        },
      );
}

/// Troubleshooting on GitHub (not built into the server, so it opens while the server is down).
String get troubleshootingUrl =>
    'https://github.com/joeMJ/audiojoe/blob/main/docs/TROUBLESHOOTING${isDe ? '' : '.en'}.md';

Future<void> showAbout(BuildContext context) async {
  final app = await PackageInfo.fromPlatform();
  String server = '';
  try {
    server = ((await api.call('GET', '/health') as Map)['version'] ?? '') as String;
  } catch (_) {}
  if (!context.mounted) return;
  Widget link(String label, String page) => TextButton.icon(
        icon: const Icon(Icons.open_in_new, size: 18),
        label: Text(label),
        onPressed: () => launchUrl(Uri.parse('${api.base}/docs/${isDe ? 'de/' : ''}$page.html'), mode: LaunchMode.externalApplication),
      );
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Row(children: [
        Image.asset('assets/icon.png', width: 48, height: 48),
        const SizedBox(width: 12),
        const Text('audiojoe'),
      ]),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('John Lose (joeMJ)'),
        const SizedBox(height: 4),
        Text([
          t('App {v}', {'v': app.version}),
          if (server.isNotEmpty) t('Server {v}', {'v': server}),
        ].join(' · ')),
        const SizedBox(height: 4),
        Text(t('Licence: Apache 2.0'), style: TextStyle(color: context.tok.muted)),
        const SizedBox(height: 8),
        link(t('Manual'), 'manual'),
        link(t('Privacy'), 'privacy'),
        TextButton.icon(
          icon: const Icon(Icons.open_in_new, size: 18),
          label: Text(t('Troubleshooting')),
          onPressed: () => launchUrl(Uri.parse(troubleshootingUrl), mode: LaunchMode.externalApplication),
        ),
      ]),
      actions: [
        TextButton(
          onPressed: () => showLicensePage(context: context, applicationName: 'audiojoe', applicationVersion: app.version),
          child: Text(t('Third-party licences')),
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: Text(t('Close'))),
      ],
    ),
  );
}

/// "Storage": free space and "Keep at least … free" (5 GB the default and the smallest value,
/// steps of 1 GB). Below it no download starts. Per device, not synced.
class StorageSettings extends StatelessWidget {
  const StorageSettings({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([storage, downloads]),
        builder: (context, _) {
          final k = context.tok;
          final used = downloads.entries.fold<int>(0, (s, e) => s + e.bytes);
          final n = storage.keepFreeGb;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SettingsGroup(children: [
              Text(
                  storage.free == null
                      ? t('{used} used', {'used': bytes(used)})
                      : t('{used} used · {free} free', {'used': bytes(used), 'free': bytes(storage.free!)}),
                  key: const ValueKey('storage-usage'),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ]),
            SettingsGroup(title: t('Keep at least free'), desc: t('Below it no download starts.'), children: [
              Row(children: [
                IconButton.outlined(
                  key: const ValueKey('keep-free-minus'),
                  tooltip: '−1 GB',
                  onPressed: n > Storage.minKeepFreeGb ? () => storage.keepFreeGb = n - 1 : null,
                  icon: const Icon(Icons.remove),
                ),
                SizedBox(
                  width: 90,
                  child: Text('$n GB', key: const ValueKey('keep-free'), textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                ),
                IconButton.outlined(key: const ValueKey('keep-free-plus'), tooltip: '+1 GB', onPressed: () => storage.keepFreeGb = n + 1, icon: const Icon(Icons.add)),
                const SizedBox(width: 12),
                if (storage.low)
                  Flexible(child: Text(t('Waiting for space'), style: TextStyle(color: k.bad, fontWeight: FontWeight.w700))),
              ]),
            ]),
          ]);
        },
      );
}

/// Android "Appearance": system, light or dark (the desktop has the moon in the title bar).
class AppearanceSettings extends StatelessWidget {
  const AppearanceSettings({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: appearance,
        builder: (context, mode, _) => SettingsGroup(children: [
          SegmentedButton<ThemeMode>(
            key: const ValueKey('appearance-mode'),
            segments: [
              ButtonSegment(value: ThemeMode.system, label: Text(t('System')), icon: const Icon(Icons.brightness_auto)),
              ButtonSegment(value: ThemeMode.light, label: Text(t('Light')), icon: const Icon(Icons.light_mode)),
              ButtonSegment(value: ThemeMode.dark, label: Text(t('Dark')), icon: const Icon(Icons.dark_mode)),
            ],
            selected: {mode},
            onSelectionChanged: (s) => setAppearance(s.first),
          ),
        ]),
      );
}
