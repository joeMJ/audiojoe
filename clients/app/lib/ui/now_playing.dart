// Now playing: large cover, format chips right above the controls, −15 / play / +30, a
// toolbar (sleep timer, speed, output, offline); tabs for details and chapters.

import 'package:flutter/material.dart';

import '../downloads.dart';
import '../l10n.dart';
import '../models.dart';
import '../player.dart';
import '../sonos.dart';
import 'common.dart';
import 'notes.dart';

class NowPlayingView extends StatelessWidget {
  const NowPlayingView({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([player, sonos, downloads]),
        builder: (context, _) {
          final it = player.item;
          if (it == null) return emptyText(context, t('Nothing is playing.'));
          final tabs = [t('Playback'), t('Details'), if (it.chapters.isNotEmpty) t('Chapters')];
          return DefaultTabController(
            // A new length needs a new controller (books have chapters, episodes not).
            key: ValueKey(tabs.length),
            length: tabs.length,
            child: Column(children: [
              TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [for (final s in tabs) Tab(text: s)]),
              Expanded(
                child: TabBarView(children: [
                  _PlaybackTab(it),
                  _DetailsTab(it),
                  if (it.chapters.isNotEmpty) _ChaptersTab(it),
                ]),
              ),
            ]),
          );
        },
      );
}

// ---------------------------------------------------------------- playback

class _PlaybackTab extends StatelessWidget {
  final Item it;
  const _PlaybackTab(this.it);

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final k = context.tok;
        final wide = c.maxWidth >= 720;
        final size = wide ? 300.0 : [c.maxWidth - 32, c.maxHeight * 0.36, 420.0].reduce((a, b) => a < b ? a : b);
        final cover = CoverThumb(image: it.image, label: it.subtitle.isEmpty ? it.title : it.subtitle, size: size);
        final out = sonos.output;
        final controls = Column(mainAxisSize: MainAxisSize.min, children: [
          Text(it.title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(player.chapter.isNotEmpty ? player.chapter : it.subtitle, textAlign: TextAlign.center, maxLines: 1,
              overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, color: k.muted, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          _FormatChips(it),
          const SizedBox(height: 4),
          if (player.live)
            Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Badge2(t('Live'), kind: 'ok'))
          else
            _Progress(),
          _Controls(),
          const SizedBox(height: 12),
          _Toolbar(it),
          if (out != null)
            const _Volume()
          else if (player.takenOver != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(t('Taken over from {device} · {ago}', {'device': player.takenOver!.device, 'ago': ago(player.takenOver!.at)}),
                  textAlign: TextAlign.center, style: TextStyle(color: k.muted)),
            ),
        ]);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  cover,
                  const SizedBox(width: 24),
                  Expanded(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: controls)),
                ])
              : Column(children: [cover, const SizedBox(height: 16), controls]),
        );
      });
}

/// One line with what is played (the source; "Cache" first when it comes from there); when a
/// Sonos speaker gets something else, that in brackets as the target.
class _FormatChips extends StatelessWidget {
  final Item it;
  const _FormatChips(this.it);

  @override
  Widget build(BuildContext context) {
    final k = context.tok;
    final src = it.quality;
    if (src == null || src.codec.isEmpty) return const SizedBox.shrink();
    final out = sonos.output;
    final target = out == null ? null : src.forSonos(out.s2);
    Widget chip(String s, {Color? color}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
              border: Border.all(color: color ?? k.line, width: 1.5), borderRadius: BorderRadius.circular(6)),
          child: Text(s, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color)),
        );
    return Wrap(alignment: WrapAlignment.center, crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 4, children: [
      if (out == null && player.fromCache) chip(t('Cache'), color: Theme.of(context).colorScheme.primary),
      for (final c in src.chips) chip(c),
      if (target != null && !target.sameAs(src))
        Text(t('(Target: {q})', {'q': target.chips.join(' ')}), style: TextStyle(color: k.muted, fontSize: 13)),
    ]);
  }
}

/// Sonos volume: − slider + and the value; for a group the whole group, its rooms below.
class _Volume extends StatelessWidget {
  const _Volume();

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: sonos, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final out = sonos.output;
    if (out == null) return const SizedBox.shrink();
    final members = out.grouped ? sonos.members : const <Room>[];
    return Column(children: [
      const SizedBox(height: 8),
      _VolumeRow(
        value: sonos.level,
        label: out.grouped ? t('Group volume') : t('Volume'),
        onChanged: (v) => sonos.setVolume(v),
        big: true,
      ),
      if (members.length > 1)
        ExpansionTile(
          title: Text(t('Rooms ({n})', {'n': members.length})),
          tilePadding: const EdgeInsets.symmetric(horizontal: 4),
          children: [
            for (final r in members)
              Row(children: [
                SizedBox(width: 110, child: Text(r.name, overflow: TextOverflow.ellipsis, style: TextStyle(color: context.tok.muted))),
                Expanded(child: _VolumeRow(value: r.volume ?? 0, label: r.name, onChanged: (v) => sonos.setVolume(v, room: r))),
              ]),
          ],
        ),
    ]);
  }
}

class _VolumeRow extends StatelessWidget {
  final int value;
  final String label;
  final ValueChanged<int> onChanged;
  final bool big;
  const _VolumeRow({required this.value, required this.label, required this.onChanged, this.big = false});

  @override
  Widget build(BuildContext context) {
    final size = big ? 52.0 : 40.0;
    Widget step(IconData icon, String tip, int delta) => SizedBox(
          width: size,
          height: size,
          child: IconButton.filledTonal(
            tooltip: tip,
            padding: EdgeInsets.zero,
            iconSize: big ? 28 : 22,
            onPressed: () => onChanged(value + delta),
            icon: Icon(icon),
          ),
        );
    return Row(children: [
      step(Icons.remove, t('Quieter'), -3),
      Expanded(
        child: Semantics(
          label: label,
          child: Slider(
            value: value.clamp(0, 100).toDouble(),
            max: 100,
            label: '$value',
            onChanged: (v) => onChanged(v.round()),
          ),
        ),
      ),
      step(Icons.add, t('Louder'), 3),
      SizedBox(
        width: big ? 44 : 36,
        child: Text('$value', textAlign: TextAlign.right, style: TextStyle(fontSize: big ? 18 : 15, fontWeight: FontWeight.w800)),
      ),
    ]);
  }
}

class _Progress extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final pos = player.position, dur = player.duration;
    final k = context.tok;
    return Column(children: [
      Slider(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
        value: dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0,
        onChanged: dur > 0 ? (v) => player.seekTo((v * dur).round()) : null,
      ),
      Row(children: [
        Text(clock(pos), style: TextStyle(color: k.muted)),
        const Spacer(),
        Text(dur > 0 ? '−${clock(dur - pos)}' : '', style: TextStyle(color: k.muted)),
      ]),
    ]);
  }
}

class _Controls extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final playing = sonos.output?.playing ?? player.playing;
    final many = player.queue.length > 1;
    final scheme = Theme.of(context).colorScheme;
    return Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
      if (many) IconButton(iconSize: 32, tooltip: t('Previous'), onPressed: () => player.skip(-1), icon: const Icon(Icons.skip_previous)),
      if (!player.live) _Skip(seconds: 15, back: true),
      SizedBox(
        width: 88,
        height: 88,
        child: IconButton.filled(
          iconSize: 56,
          tooltip: playing ? t('Pause') : t('Play'),
          style: IconButton.styleFrom(backgroundColor: scheme.onSurface, foregroundColor: scheme.surface),
          onPressed: () => sonos.output != null ? sonos.toggle() : player.toggle(),
          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
        ),
      ),
      if (!player.live) _Skip(seconds: 30, back: false),
      if (many) IconButton(iconSize: 32, tooltip: t('Next'), onPressed: () => player.skip(1), icon: const Icon(Icons.skip_next)),
    ]);
  }
}

/// Circular arrow with the number of seconds inside, like the usual podcast players.
class _Skip extends StatelessWidget {
  final int seconds;
  final bool back;
  const _Skip({required this.seconds, required this.back});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: back ? t('Back {n} s', {'n': seconds}) : t('Forward {n} s', {'n': seconds}),
        onPressed: () => player.seekBy((back ? -seconds : seconds) * 1000),
        icon: SizedBox(
          width: 60,
          height: 60,
          child: Stack(alignment: Alignment.center, children: [
            Transform.flip(flipX: !back, child: const Icon(Icons.replay, size: 60)),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('$seconds', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
            ),
          ]),
        ),
      );
}

class _Toolbar extends StatelessWidget {
  final Item it;
  const _Toolbar(this.it);

  @override
  Widget build(BuildContext context) {
    final k = context.tok;
    final out = sonos.output;
    final local = out == null; // sleep timer and speed act on this device only
    final e = downloads.entry(it.key);
    Widget tool(Widget icon, String label, VoidCallback? onTap, {String? tip}) => Expanded(
          child: Tooltip(
            message: tip ?? label,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap,
              child: Opacity(
                opacity: onTap == null ? 0.4 : 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    SizedBox(height: 30, child: Center(child: icon)),
                    const SizedBox(height: 2),
                    Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: k.muted)),
                  ]),
                ),
              ),
            ),
          ),
        );
    final left = player.sleepAt?.difference(DateTime.now());
    final sleepLabel = !player.sleeping
        ? t('Sleep timer')
        : left != null
            ? t('{n} min', {'n': (left.inSeconds / 60).ceil()})
            : player.sleepAtEnd == 'chapter' ? t('End of chapter') : t('End of item');
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      decoration: BoxDecoration(color: k.panel2, borderRadius: BorderRadius.circular(14)),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(children: [
        tool(Icon(player.sleeping ? Icons.bedtime : Icons.bedtime_outlined, size: 28, color: player.sleeping ? accent : null), sleepLabel,
            local && !player.live ? () => _sleepSheet(context) : null, tip: t('Sleep timer')),
        tool(Text('${_rate(player.rate)}×', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)), t('Speed'),
            local && !player.live ? () => _rateSheet(context) : null),
        tool(Icon(local ? Icons.smartphone : Icons.speaker, size: 28, color: local ? null : accent),
            local ? t('This device') : out.label, () => showModalBottomSheet(context: context, builder: (_) => const OutputSheet()),
            tip: t('Output')),
        tool(
          switch (e?.status) {
            'done' => Icon(Icons.download_done, size: 28, color: k.ok),
            'loading' => SizedBox(width: 24, height: 24, child: CircularProgressIndicator(value: e?.progress, strokeWidth: 3)),
            'error' => Icon(Icons.error_outline, size: 28, color: k.bad),
            String() => Icon(Icons.schedule, size: 28, color: k.warn),
            null => const Icon(Icons.download, size: 28),
          },
          e?.status == 'done' ? t('in cache') : t('Offline'),
          e == null && !player.live ? () => downloads.add([it]) : null,
          tip: e == null ? t('Save offline') : null,
        ),
      ]),
    );
  }

  static String _rate(double r) => r == r.roundToDouble() ? r.toStringAsFixed(1) : '$r';

  void _sleepSheet(BuildContext context) => showModalBottomSheet(
        context: context,
        builder: (ctx) {
          void set({Duration? after, String? atEnd}) {
            player.setSleep(after: after, atEnd: atEnd);
            Navigator.pop(ctx);
          }

          return SafeArea(
            child: ListView(shrinkWrap: true, children: [
              ListTile(title: Text(t('Sleep timer'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
              for (final m in [5, 15, 30, 45, 60])
                ListTile(leading: const Icon(Icons.timer_outlined), title: Text(t('{n} min', {'n': m})), onTap: () => set(after: Duration(minutes: m))),
              if (player.item?.chapters.isNotEmpty ?? false)
                ListTile(leading: const Icon(Icons.bookmark_outline), title: Text(t('End of chapter')), onTap: () => set(atEnd: 'chapter')),
              ListTile(leading: const Icon(Icons.stop_circle_outlined), title: Text(t('End of item')), onTap: () => set(atEnd: 'item')),
              if (player.sleeping) ListTile(leading: const Icon(Icons.close), title: Text(t('Off')), onTap: () => set()),
            ]),
          );
        },
      );

  void _rateSheet(BuildContext context) => showModalBottomSheet(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(shrinkWrap: true, children: [
            ListTile(title: Text(t('Speed'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
            for (final r in [0.8, 1.0, 1.1, 1.2, 1.5, 1.8, 2.0])
              ListTile(
                title: Text('${_rate(r)}×'),
                trailing: r == player.rate ? const Icon(Icons.check) : null,
                onTap: () {
                  player.setRate(r);
                  Navigator.pop(ctx);
                },
              ),
          ]),
        ),
      );
}

// ---------------------------------------------------------------- details

class _DetailsTab extends StatelessWidget {
  final Item it;
  const _DetailsTab(this.it);

  @override
  Widget build(BuildContext context) {
    final k = context.tok;
    final date = it.published == null ? null : DateTime.tryParse(it.published!);
    final facts = [
      if (date != null) '${date.day}.${date.month}.${date.year}' else if (it.published != null) it.published!,
      if (it.year != null && date == null && it.published == null) '${it.year}',
      if (player.duration > 0 && !player.live) clock(player.duration),
      if (it.chapters.isNotEmpty) t('{n} chapters', {'n': it.chapters.length}),
    ];
    final desc = it.description ?? '';
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CoverThumb(image: it.image, label: it.subtitle.isEmpty ? it.title : it.subtitle, size: 96),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(it.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            if (it.subtitle.isNotEmpty) Text(it.subtitle, style: TextStyle(color: k.muted, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [for (final f in facts) Badge2(f)]),
          ]),
        ),
      ]),
      const SizedBox(height: 20),
      Text(t('Description'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      Divider(color: k.line),
      if ((it.notes ?? '').isNotEmpty)
        NotesView(it.notes!)
      else
        SelectableText(desc.isEmpty ? t('No description.') : desc, style: TextStyle(fontSize: 15, height: 1.45, color: desc.isEmpty ? k.muted : null)),
      if (it.quality != null && it.quality!.codec.isNotEmpty) ...[
        const SizedBox(height: 20),
        Text(t('Format'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        Divider(color: k.line),
        Text(it.quality!.text, style: const TextStyle(fontSize: 15)),
      ],
    ]);
  }
}

// ---------------------------------------------------------------- chapters

class _ChaptersTab extends StatelessWidget {
  final Item it;
  const _ChaptersTab(this.it);

  @override
  Widget build(BuildContext context) {
    final current = player.chapter;
    return ListView.builder(
      itemCount: it.chapters.length,
      itemBuilder: (context, i) {
        final c = it.chapters[i];
        final active = c.title == current && player.position >= c.startMs && player.position < c.endMs;
        return ListTile(
          selected: active,
          leading: Icon(active ? Icons.play_arrow : Icons.bookmark_outline),
          title: Text(c.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: Text(clock(c.startMs)),
          onTap: () => player.seekTo(c.startMs),
        );
      },
    );
  }
}

// ---------------------------------------------------------------- output

/// Ticked: the room plays together with the current output.
class _GroupBox extends StatefulWidget {
  final Room room;
  final VoidCallback reload;
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
      width: 32,
      child: busy
          ? const Padding(padding: EdgeInsets.all(6), child: CircularProgressIndicator(strokeWidth: 2.5))
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
                widget.reload();
              },
            ),
    );
  }
}

class OutputSheet extends StatelessWidget {
  const OutputSheet({super.key});

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(t('Output'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            ItemRow(
              leading: const Icon(Icons.smartphone, size: 32),
              title: t('This device'),
              subtitle: t('from cache or stream'),
              trailing: [
                FilledButton(
                  onPressed: sonos.output == null ? null : () {
                    Navigator.pop(context);
                    sonos.backToDevice();
                  },
                  child: Text(sonos.output == null ? t('active') : t('Switch here')),
                ),
              ],
            ),
            Flexible(
              child: Loader<List<Room>>(
                load: sonos.rooms,
                builder: (context, rooms, reload) => ListView(shrinkWrap: true, children: [
                  for (final r in rooms)
                    ItemRow(
                      leading: sonos.output == null || !r.reachable
                          ? const Icon(Icons.speaker, size: 32)
                          : r.id == sonos.output!.id
                              ? Icon(Icons.speaker, size: 32, color: Theme.of(context).colorScheme.primary)
                              : _GroupBox(r, reload),
                      title: 'Sonos ${r.name}',
                      subtitle: '${r.model} · ${r.s2 ? t('up to 24 bit / 48 kHz') : t('up to 16 bit / 48 kHz')}',
                      trailing: [
                        Badge2(!r.reachable ? t('switched off') : r.playing ? t('playing') : t('available'),
                            kind: !r.reachable ? 'bad' : r.playing ? 'warn' : 'ok'),
                        FilledButton(
                          // Close the sheet at once; an error shows on the player view below.
                          onPressed: !r.reachable ? null : () async {
                            final messenger = ScaffoldMessenger.of(context);
                            Navigator.pop(context);
                            try {
                              await sonos.playOn(r);
                            } catch (e) {
                              messenger.showSnackBar(SnackBar(content: Text('${t('Error')}: $e')));
                            }
                          },
                          child: Text(t('Play here')),
                        ),
                      ],
                    ),
                ]),
              ),
            ),
          ]),
        ),
      );
}
