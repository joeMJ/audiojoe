// Settings: sources (Jellyfin, Audiobookshelf) and which of their libraries to show, music
// (reading in the album directory, labels from MusicBrainz), Sonos speakers, podcast import/export (OPML),
// signed-in devices, sign out, about.

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../l10n.dart';
import 'common.dart';

class SettingsView extends StatefulWidget {
  final VoidCallback onSignOut;
  const SettingsView({super.key, required this.onSignOut});
  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  int _gen = 0;

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(12), children: [
        Row(children: [
          Text(t('Sources'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const Spacer(),
          FilledButton.icon(
            icon: const Icon(Icons.add),
            label: Text(t('Add source')),
            onPressed: () async {
              if (await showDialog<bool>(context: context, builder: (_) => const AddSourceDialog()) == true) setState(() => _gen++);
            },
          ),
        ]),
        const SizedBox(height: 8),
        Loader<List>(
          key: ValueKey('src$_gen'),
          load: () async => await api.call('GET', '/sources') as List,
          builder: (context, list, reload) => Column(children: [
            if (list.isEmpty) emptyText(context, t('No sources yet. Add one in the settings.')),
            for (final s in list.cast<Map>()) ...[
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
            ],
          ]),
        ),
        const SizedBox(height: 20),
        Text(t('Music'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        MusicSettings(key: ValueKey('music$_gen')),
        const SizedBox(height: 20),
        Text(t('Sonos'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        const SonosSettings(),
        const SizedBox(height: 20),
        Text(t('Maintenance'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        MaintenanceSettings(key: ValueKey('maint$_gen')),
        const SizedBox(height: 20),
        Text(t('Devices'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Loader<List>(
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
        ),
        const SizedBox(height: 20),
        Text(t('Podcasts'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(t('Subscriptions as OPML file, the format other podcast apps read and write.'), style: TextStyle(color: context.tok.muted)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(icon: const Icon(Icons.file_upload_outlined), label: Text(t('Import OPML')), onPressed: _import),
          OutlinedButton.icon(icon: const Icon(Icons.file_download_outlined), label: Text(t('Export OPML')), onPressed: _export),
        ]),
        const SizedBox(height: 20),
        OutlinedButton.icon(icon: const Icon(Icons.logout), label: Text(t('Sign out this device')), onPressed: widget.onSignOut),
        const SizedBox(height: 8),
        OutlinedButton.icon(icon: const Icon(Icons.info_outline), label: Text(t('About audiojoe')), onPressed: () => showAbout(context)),
      ]);

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

  @override
  Widget build(BuildContext context) => Loader<Map>(
        key: ValueKey('m$_gen'),
        load: () async => await api.call('GET', '/maintenance') as Map,
        builder: (context, m, reload) {
          final muted = TextStyle(color: context.tok.muted);
          final st = m['status'] as Map?;
          if (m['managed'] != true || st == null) {
            return Text(t('Server {v}. Updates are not managed here (server not installed from the package, see the installation guide).', {'v': '${m['version']}'}),
                style: muted);
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
