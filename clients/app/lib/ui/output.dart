// Output overlay (the footer's device button): over the whole area right of the navigation,
// on phones the whole page. At the top the device or group being played on, with the Sonos
// volumes; below all apps and web players of the account and the Sonos rooms – control an
// app, fetch its stream here, send this device's title there, stop it.

import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../l10n.dart';
import '../models.dart';
import '../player.dart';
import '../remote.dart';
import '../sonos.dart';
import '../tokens.g.dart';
import 'common.dart';

/// Whether the overlay is open (it replaces the playback view while open).
final outputOpen = ValueNotifier<bool>(false);

const _h = 32.0, _w = 84.0;

ButtonStyle _size(ButtonStyle? s) => (s ?? const ButtonStyle()).copyWith(
      minimumSize: const WidgetStatePropertyAll(Size(_w, _h)),
      fixedSize: const WidgetStatePropertyAll(Size.fromHeight(_h)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );

Widget _primary(String label, VoidCallback? onPressed) =>
    FilledButton(style: _size(FilledButton.styleFrom()), onPressed: onPressed, child: Text(label, maxLines: 1));

Widget _secondary(String label, VoidCallback? onPressed) =>
    FilledButton.tonal(style: _size(FilledButton.styleFrom()), onPressed: onPressed, child: Text(label, maxLines: 1));

/// Pill as high and wide as the buttons.
class _Pill extends StatelessWidget {
  final String text;
  final String kind; // ok | bad | accent | plain
  const _Pill(this.text, {this.kind = 'plain'});

  @override
  Widget build(BuildContext context) {
    final k = context.tok;
    final accent = Theme.of(context).colorScheme;
    final (fg, bg) = switch (kind) {
      'ok' => (k.ok, k.okBg),
      'bad' => (k.bad, k.badBg),
      'accent' => (accent.onPrimaryContainer, accent.primaryContainer),
      _ => (k.muted, k.panel2),
    };
    return Container(
      constraints: const BoxConstraints(minWidth: _w, minHeight: _h),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(_h / 2)),
      // As wide as the text (at least as a button), not the whole row.
      child: Align(widthFactor: 1, heightFactor: 1,
          child: Text(text, maxLines: 1, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 13))),
    );
  }
}

String _kindLabel(String kind) => switch (kind) {
      'linux' => t('Linux app'),
      'windows' => t('Windows app'),
      'android' => t('Android app'),
      'web' => t('Web player'),
      _ => t('App'),
    };

/// "playing · Title · 12:40"
String _stateLine(Device d) {
  if (d.key.isEmpty || d.state == 'stopped') return '';
  return [d.playing ? t('playing') : t('paused'), if (d.title.isNotEmpty) d.title, if (d.positionMs > 0) clock(d.positionMs)].join(' · ');
}

class OutputOverlay extends StatefulWidget {
  const OutputOverlay({super.key});

  @override
  State<OutputOverlay> createState() => _OutputOverlayState();
}

class _OutputOverlayState extends State<OutputOverlay> {
  List<Room>? rooms;
  bool grouping = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    // Rooms change outside the app (switched off, played from elsewhere).
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    await remote.refresh();
    try {
      final r = await sonos.rooms();
      if (mounted) setState(() => rooms = r);
    } catch (_) {
      if (mounted) setState(() => rooms ??= []);
    }
  }

  void _close() => outputOpen.value = false;

  /// Runs an action; an error shows below. [close]: back to the playback view first.
  Future<void> _run(Future<void> Function() f, {bool close = false}) async {
    final messenger = ScaffoldMessenger.of(context);
    if (close) _close();
    try {
      await f();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('${t('Error')}: $e')));
    }
    if (mounted && !close) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([remote, sonos, player]),
        builder: (context, _) {
          final k = context.tok;
          final apps = remote.devices.where((d) => !d.speaker).toList()
            ..sort((a, b) => a.current != b.current ? (a.current ? -1 : 1) : a.name.compareTo(b.name));
          if (!apps.any((d) => d.current)) {
            apps.insert(0, Device(name: api.device, kind: deviceKind, state: 'stopped', key: '', title: '', subtitle: '',
                updatedAt: '', positionMs: 0, online: true, current: true));
          }
          Widget section(String s) => Padding(
                padding: const EdgeInsets.fromLTRB(4, 18, 4, 6),
                child: Text(s.toUpperCase(), style: TextStyle(color: k.muted, fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 0.6)),
              );
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(children: [
                Text(t('Output'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                const Spacer(),
                IconButton(tooltip: t('Close'), onPressed: _close, icon: const Icon(Icons.close)),
              ]),
            ),
            Expanded(
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), children: [
                _selected(context),
                section(t('Apps and web player')),
                for (final d in apps) _app(context, d),
                if ((rooms ?? const []).isNotEmpty) ...[
                  section(t('Sonos')),
                  for (final r in rooms!) _room(context, r),
                ],
                if (rooms == null) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
              ]),
            ),
          ]);
        },
      );

  Widget _card(BuildContext context, {required Widget child, bool selected = false, bool dim = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Opacity(
      opacity: dim ? 0.5 : 1,
      child: Card(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SizeTokens.radius),
            side: selected ? BorderSide(color: scheme.primary, width: 2) : BorderSide.none),
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), child: child),
      ),
    );
  }

  Widget _head(BuildContext context, IconData icon, String title, String line, List<Widget> pills) {
    final k = context.tok;
    return Row(children: [
      Icon(icon, size: 28),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ...pills,
          ]),
          if (line.isNotEmpty) Text(line, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: k.muted)),
        ]),
      ),
    ]);
  }

  // ---------------------------------------------------------------- the device played on

  Widget _selected(BuildContext context) {
    final out = sonos.output;
    final it = player.item;
    String line({String? by}) => it == null
        ? ''
        : [
            player.playing ? t('playing') : t('paused'),
            it.title,
            if (!player.live && player.duration > 0) t('{n} of {m}', {'n': clock(player.position), 'm': clock(player.duration)}),
            if (by != null) t('started by {device}', {'device': by}),
          ].join(' · ');
    if (out != null) {
      final members = out.grouped ? sonos.members : const <Room>[];
      return _card(
        context,
        selected: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _head(context, Icons.speaker, 'Sonos ${out.grouped ? out.groupName ?? out.name : out.name}', line(by: out.startedBy),
              [_Pill(t('controlled'), kind: 'accent')]),
          const SizedBox(height: 8),
          if (members.length > 1) ...[
            _VolumeLine(t('Group'), sonos.level, (v) => sonos.setVolume(v)),
            for (final r in members) _VolumeLine(r.name, r.volume ?? 0, (v) => sonos.setVolume(v, room: r)),
          ] else
            _VolumeLine(t('Volume'), sonos.level, (v) => sonos.setVolume(v)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _primary(t('Here'), () => _run(() => remote.takeHere(remote.target!), close: true)),
            _secondary(t('Stop'), () => _run(() => remote.stop(remote.target!))),
            grouping ? _primary(t('Group'), () => setState(() => grouping = false)) : _secondary(t('Group'), () => setState(() => grouping = true)),
          ]),
        ]),
      );
    }
    final target = remote.target;
    if (target != null) {
      final d = remote.device(target);
      return _card(
        context,
        selected: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _head(context, Icons.smartphone, target, [if (d != null) _kindLabel(d.kind), line()].where((s) => s.isNotEmpty).join(' · '),
              [_Pill(t('controlled'), kind: 'accent')]),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _primary(t('Here'), () => _run(() => remote.takeHere(target), close: true)),
            _secondary(t('Stop'), () => _run(() => remote.stop(target))),
          ]),
        ]),
      );
    }
    return _card(
      context,
      selected: true,
      child: _head(context, Icons.smartphone, '${t('This device')} · ${api.device}', line(), [_Pill(t('here'), kind: 'accent')]),
    );
  }

  // ---------------------------------------------------------------- apps and web players

  Widget _app(BuildContext context, Device d) {
    final k = context.tok;
    if (d.current) {
      final what = remote.active ? t('controls {device}', {'device': sonos.output?.label ?? remote.target!}) : '';
      return _card(
        context,
        child: _head(context, Icons.smartphone, '${t('This device')} · ${d.name}', [_kindLabel(deviceKind), what].where((s) => s.isNotEmpty).join(' · '),
            [_Pill(t('here'), kind: 'accent')]),
      );
    }
    final line = d.online
        ? [_kindLabel(d.kind), _stateLine(d)].where((s) => s.isNotEmpty).join(' · ')
        : [_kindLabel(d.kind), t('offline'), if (d.lastSeen != null) t('last seen {ago}', {'ago': ago(d.lastSeen!)})].join(' · ');
    final controlled = remote.target == d.name;
    final buttons = d.web
        ? [_primary(t('Take over'), d.key.isEmpty ? null : () => _run(() => remote.takeFrom(d), close: true))]
        : [
            if (controlled)
              _Pill(t('controlled'), kind: 'accent')
            else
              _secondary(t('Control'), d.online ? () => _run(() => remote.control(d.name), close: true) : null),
            _primary(t('Here'), d.online && d.key.isNotEmpty ? () => _run(() => remote.takeHere(d.name), close: true) : null),
            _secondary(t('Stop'), d.online && d.state != 'stopped' ? () => _run(() => remote.stop(d.name)) : null),
          ];
    return _card(
      context,
      dim: !d.online && !d.web,
      child: LayoutBuilder(builder: (context, c) {
        final head = _head(context, d.web ? Icons.public : Icons.smartphone, d.web ? '${t('Web player')} · ${d.name}' : d.name, line, const []);
        final row = Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.end, children: buttons);
        // Narrow: the buttons below the name.
        if (c.maxWidth < 560) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [head, const SizedBox(height: 8), Align(alignment: Alignment.centerRight, child: row)]);
        }
        return Row(children: [Expanded(child: head), DefaultTextStyle.merge(style: TextStyle(color: k.muted), child: row)]);
      }),
    );
  }

  // ---------------------------------------------------------------- Sonos rooms

  Widget _room(BuildContext context, Room r) {
    final out = sonos.output;
    final inOutput = out != null && (r.id == out.id || (out.group != null && r.group == out.group));
    final pill = inOutput
        ? _Pill(t('controlled'), kind: 'accent')
        : !r.reachable
            ? _Pill(t('switched off'))
            : r.busy
                ? _Pill(t('busy'), kind: 'bad')
                : _Pill(t('available'), kind: 'ok');
    final canPlay = r.reachable && !r.busy && player.item != null;
    return _card(
      context,
      child: Row(children: [
        if (grouping && out != null && r.id != out.id && r.reachable && !r.busy)
          _GroupBox(r, _load)
        else
          const Icon(Icons.speaker, size: 28),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Sonos ${r.name}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            Text('${r.model} · ${r.s2 ? t('up to 24 bit / 48 kHz') : t('up to 16 bit / 48 kHz')}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: context.tok.muted)),
          ]),
        ),
        const SizedBox(width: 8),
        pill,
        if (!inOutput) ...[
          const SizedBox(width: 8),
          _primary(t('There'), canPlay ? () => _run(() => sonos.playOn(r), close: true) : null),
        ],
      ]),
    );
  }
}

/// Name − slider + value, for the group and each room.
class _VolumeLine extends StatelessWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  const _VolumeLine(this.label, this.value, this.onChanged);

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData i, String tip, int d) => SizedBox(
          width: 36,
          height: 36,
          child: IconButton.filledTonal(tooltip: tip, padding: EdgeInsets.zero, iconSize: 20, onPressed: () => onChanged(value + d), icon: Icon(i)),
        );
    return Row(children: [
      SizedBox(width: 100, child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700))),
      btn(Icons.remove, t('Quieter'), -3),
      Expanded(
        child: Semantics(
          label: label,
          child: Slider(value: value.clamp(0, 100).toDouble(), max: 100, label: '$value', onChanged: (v) => onChanged(v.round())),
        ),
      ),
      btn(Icons.add, t('Louder'), 3),
      SizedBox(width: 40, child: Text('$value', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800))),
    ]);
  }
}

/// Ticked: the room plays together with the output.
class _GroupBox extends StatefulWidget {
  final Room room;
  final Future<void> Function() reload;
  const _GroupBox(this.room, this.reload);

  @override
  State<_GroupBox> createState() => _GroupBoxState();
}

class _GroupBoxState extends State<_GroupBox> {
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.room, o = sonos.output!;
    final inGroup = r.group != null && r.group == o.group;
    return SizedBox(
      width: 28,
      child: busy
          ? const Padding(padding: EdgeInsets.all(4), child: CircularProgressIndicator(strokeWidth: 2.5))
          : Checkbox(
              value: inGroup,
              semanticLabel: inGroup ? t('Remove from group') : t('Add to group'),
              onChanged: (v) async {
                setState(() => busy = true);
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await sonos.setInGroup(r, v ?? false);
                } catch (e) {
                  messenger.showSnackBar(SnackBar(content: Text('${t('Error')}: $e')));
                }
                if (mounted) setState(() => busy = false);
                await widget.reload();
              },
            ),
    );
  }
}
