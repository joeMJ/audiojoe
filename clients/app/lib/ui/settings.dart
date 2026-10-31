// Settings: sources (Jellyfin, Audiobookshelf), podcast import/export (OPML), signed-in
// devices, sign out.

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

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
            for (final s in list.cast<Map>())
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
          ]),
        ),
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
