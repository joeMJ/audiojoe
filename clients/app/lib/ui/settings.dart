// Settings: sources (Jellyfin, Audiobookshelf) and which of their libraries to show, music
// (reading in the album directory, labels from MusicBrainz), Sonos speakers, podcast import/export (OPML),
// signed-in devices, sign out, about. Phones: one list; desktop: pages on the left, groups on the right.

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../l10n.dart';
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

  Widget _phone(BuildContext context) => ListView(padding: const EdgeInsets.all(12), children: [
        Row(children: [_h(t('Sources')), const Spacer(), _addSource()]),
        const SizedBox(height: 8),
        _sources(),
        const SizedBox(height: 20),
        _h(t('Music')),
        const SizedBox(height: 8),
        MusicSettings(key: ValueKey('music$_gen')),
        const SizedBox(height: 20),
        _h(t('Sonos')),
        const SizedBox(height: 8),
        const SonosSettings(),
        const SizedBox(height: 20),
        _h(t('Sync with other podcast apps')),
        const SizedBox(height: 8),
        GpodderSettings(key: ValueKey('gpodder$_gen')),
        const SizedBox(height: 20),
        _h(t('Maintenance')),
        const SizedBox(height: 8),
        MaintenanceSettings(key: ValueKey('maint$_gen')),
        const SizedBox(height: 20),
        _h(t('Devices')),
        const SizedBox(height: 8),
        _devices(),
        const SizedBox(height: 20),
        _h(t('Podcasts')),
        const SizedBox(height: 4),
        Text(t('Subscriptions as OPML file, the format other podcast apps read and write.'), style: TextStyle(color: context.tok.muted)),
        const SizedBox(height: 8),
        _opml(),
        const SizedBox(height: 20),
        _signOut(),
        const SizedBox(height: 8),
        OutlinedButton.icon(icon: const Icon(Icons.info_outline), label: Text(t('About audiojoe')), onPressed: () => showAbout(context)),
      ]);

  /// Desktop: the pages on the left, the chosen page on the right in groups.
  List<(IconData, String)> get _pages => [
        (Icons.storage, t('Sources')),
        (Icons.podcasts, t('Podcasts')),
        (Icons.library_music, t('Music')),
        (Icons.speaker, t('Sonos')),
        (Icons.devices, t('Devices')),
        (Icons.system_update_alt, t('Maintenance')),
        (Icons.info_outline, t('About')),
      ];

  List<Widget> _pageContent(BuildContext context) => switch (_page) {
        0 => [_sources(grouped: true)],
        1 => [
            SettingsGroup(
              title: 'OPML',
              desc: t('Subscriptions as OPML file, the format other podcast apps read and write.'),
              children: [_opml()],
            ),
            SettingsGroup(title: t('Sync with other podcast apps'), children: [GpodderSettings(key: ValueKey('gpodder$_gen'))]),
          ],
        2 => [SettingsGroup(children: [MusicSettings(key: ValueKey('music$_gen'))])],
        3 => [const SettingsGroup(children: [SonosSettings()])],
        4 => [
            SettingsGroup(children: [_devices()]),
            SettingsGroup(children: [Align(alignment: Alignment.centerLeft, child: _signOut())]),
          ],
        5 => [SettingsGroup(children: [MaintenanceSettings(key: ValueKey('maint$_gen'))])],
        _ => [const SettingsGroup(children: [AboutPanel()])],
      };

  Widget _desktop(BuildContext context) {
    final k = context.tok, scheme = Theme.of(context).colorScheme;
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        width: 200,
        decoration: BoxDecoration(color: scheme.surface, border: Border(right: BorderSide(color: k.line))),
        child: ListView(padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8), children: [
          for (final (i, (icon, label)) in _pages.indexed)
            Padding(
              key: ValueKey('settings-page-$i'),
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
          Row(children: [_h(_pages[_page].$2), const Spacer(), if (_page == 0) _addSource()]),
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

/// Server updates (nightly at 04:00 or only reported), Debian updates and database backups, as
/// `audiojoe-update` on the server last reported them.
class MaintenanceSettings extends StatefulWidget {
  const MaintenanceSettings({super.key});
  @override
  State<MaintenanceSettings> createState() => _MaintenanceSettingsState();
}

class _MaintenanceSettingsState extends State<MaintenanceSettings> {
  int _gen = 0;

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

  String _server(Map st) {
    final last = st['last_update'] as Map?;
    switch (st['result']) {
      case 'available':
        return t('Version {v} is available.', {'v': '${st['latest']}'});
      case 'updated':
        return t('Updated from {from} to {to} {ago}.', {'from': '${last?['from']}', 'to': '${last?['to']}', 'ago': ago('${last?['at']}')});
      case 'rolled_back':
        return t('Version {v} did not start; the server went back to {from}.', {'v': '${last?['to'] ?? st['latest']}', 'from': '${last?['from']}'});
      case 'failed':
        return t('Last update failed: {msg}', {'msg': '${st['message']}'});
      default:
        return t('Up to date.');
    }
  }

  Widget _app(Map m, TextStyle muted) => _AppUpdateRow(latest: (m['apps'] as Map?)?['latest'] as String?, muted: muted, say: _say);

  @override
  Widget build(BuildContext context) => Loader<Map>(

        key: ValueKey('m$_gen'),
        load: () async => await api.call('GET', '/maintenance') as Map,
        builder: (context, m, reload) {
          final muted = TextStyle(color: context.tok.muted);
          final st = m['status'] as Map?;
          if (m['managed'] != true || st == null) {
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t('Server {v}. Updates are not managed here (server not installed from the package, see the installation guide).', {'v': '${m['version']}'}),
                  style: muted),
              const SizedBox(height: 12),
              _app(m, muted),
            ]);
          }
          final deb = (st['debian'] as Map?) ?? const {};
          final backups = ((st['backups'] as List?) ?? const []).cast<Map>();
          final newer = st['latest'] != null && st['latest'] != st['installed'] && st['result'] != 'ok';
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('Server {v}', {'v': '${st['installed']}'}), style: const TextStyle(fontWeight: FontWeight.w700)),
            Text('${_server(st)} ${t('Checked {ago}.', {'ago': ago('${st['checked_at']}')})}', style: muted),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: 'auto', label: Text(t('Update at 04:00'))),
                  ButtonSegment(value: 'notify', label: Text(t('Only report'))),
                ],
                selected: {'${m['mode']}'},
                onSelectionChanged: (v) => _call('PUT', '/maintenance', {'mode': v.first}),
              ),
              if (newer)
                FilledButton.icon(
                  icon: const Icon(Icons.system_update_alt),
                  label: Text(m['requested'] == true ? t('Update requested') : t('Update now')),
                  onPressed: m['requested'] == true
                      ? null
                      : () => _call('POST', '/maintenance/update', null, t('Update started; the server restarts briefly.')),
                ),
            ]),
            const SizedBox(height: 12),
            _app(m, muted),
            const SizedBox(height: 12),
            Text(t('Debian updates'), style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(
              [
                deb['automatic'] == true ? t('Installed automatically every day; unused packages are removed.') : t('Not set up for automatic installation.'),
                if (deb['last_run'] != null) t('Last run {ago}.', {'ago': ago('${deb['last_run']}')}),
                if ((deb['upgraded'] as List?)?.isNotEmpty == true) t('Last updated: {pkgs}.', {'pkgs': (deb['upgraded'] as List).join(', ')}),
                if ((deb['pending'] ?? 0) != 0) t('{n} updates waiting.', {'n': deb['pending']}),
              ].join(' '),
              style: muted,
            ),
            const SizedBox(height: 12),
            Text(t('Database backups'), style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(
              backups.isEmpty
                  ? t('None yet; one is made before every server update.')
                  : t('{n} kept (before every server update), latest {ago}.', {'n': backups.length, 'ago': ago('${backups.first['at']}')}),
              style: muted,
            ),
          ]);
        },
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

/// This app: version, and the newer one the server knows (github build only).
class _AppUpdateRow extends StatefulWidget {
  final String? latest;
  final TextStyle muted;
  final void Function(String) say;
  const _AppUpdateRow({required this.latest, required this.muted, required this.say});
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
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('App {v}', {'v': v}), style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(
              !appUpdatesEnabled
                  ? t('Updates come from F-Droid.')
                  : u != null
                      ? t('Version {v} is available.', {'v': u.latest})
                      : widget.latest == null
                          ? t('The server knows no newer version yet.')
                          : t('Up to date.'),
              style: widget.muted,
            ),
            if (u != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: FilledButton.icon(
                  icon: const Icon(Icons.download),
                  label: Text(Platform.isAndroid ? t('Install version {v}', {'v': u.latest}) : t('Download version {v}', {'v': u.latest})),
                  onPressed: () => runAppUpdate(u, widget.say, t),
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
              const Text('audiojoe', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
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
            TextButton.icon(
              icon: const Icon(Icons.description_outlined, size: 18),
              label: Text(t('Third-party licences')),
              onPressed: () => showLicensePage(context: context, applicationName: 'audiojoe', applicationVersion: app),
            ),
          ]);
        },
      );
}

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
        Text([
          t('App {v}', {'v': app.version}),
          if (server.isNotEmpty) t('Server {v}', {'v': server}),
        ].join(' · ')),
        const SizedBox(height: 4),
        Text(t('Licence: Apache 2.0'), style: TextStyle(color: context.tok.muted)),
        const SizedBox(height: 8),
        link(t('Manual'), 'manual'),
        link(t('Privacy'), 'privacy'),
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
