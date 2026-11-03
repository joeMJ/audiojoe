// Now playing: large cover, format chips and where it plays, then −15 / play / +30; tabs for
// details and chapters. Progress and buttons always stay in view. Desktop: the cover takes the
// left third, progress, buttons and footer (sleep timer, speed, output, offline) sit at the
// bottom right, no volume (the output overlay has it). Phone: volume and footer at the bottom.

import 'package:flutter/material.dart';

import '../downloads.dart';
import '../l10n.dart';
import '../models.dart';
import '../player.dart';
import '../sonos.dart';
import '../volume.dart';
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
        final out = sonos.output;
        // Title, subtitle, chapter, format chips.
        final head = [
          // "(16 of 21)" after the title in a queue (an album), after the chapter name with chapters.
          // A long title flows, so the count stays visible.
          Marquee(
              TextSpan(text: it.title, children: [
                if (player.chapters.isEmpty && player.queue.length > 1)
                  TextSpan(text: ' ${_count(player.index, player.queue.length)}', style: TextStyle(color: k.muted, fontWeight: FontWeight.w600)),
              ]),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(it.subtitle, textAlign: TextAlign.center, maxLines: 1,
              overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, color: k.muted, fontWeight: FontWeight.w600)),
          if (player.chapter.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Marquee(
                  TextSpan(text: player.chapter, children: [
                    TextSpan(text: ' ${_count(player.chapterIndex, player.chapters.length)}', style: TextStyle(color: k.muted, fontWeight: FontWeight.w600)),
                  ]),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          const SizedBox(height: 12),
          _FormatChips(it),
          if (out != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.speaker, size: 18, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(t('Playing on {device}', {'device': out.label}), maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
        ];
        // Progress (or "Live") and the buttons.
        final play = [
          if (player.live)
            Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Badge2(t('Live'), kind: 'ok'))
          else
            _Progress(),
          _Controls(),
          if (out == null && player.takenOver != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(t('Taken over from {device} · {ago}', {'device': player.takenOver!.device, 'ago': ago(player.takenOver!.at)}),
                  textAlign: TextAlign.center, style: TextStyle(color: k.muted)),
            ),
        ];
        if (desktop) {
          // Cover in the left third; on the right the title at the top, the progress, buttons and
          // footer fixed at the bottom. Only the title and facts scroll when the window is low.
          // Too low for all of it: the footer goes as 2 × 2 below the cover.
          const pad = EdgeInsets.fromLTRB(16, 16, 16, 12);
          final h = c.maxHeight - pad.vertical;
          final tight = h < 470;
          final third = (c.maxWidth - pad.horizontal) / 3;
          final side = [third, tight ? h - 136 : h].reduce((a, b) => a < b ? a : b).clamp(80.0, 2000.0);
          return Padding(
            padding: pad,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: tight ? third.clamp(side, 2000.0) : side,
                child: Column(children: [
                  CoverThumb(image: it.image, label: it.subtitle.isEmpty ? it.title : it.subtitle, size: side),
                  if (tight) ...[const Spacer(), _Toolbar(it, grid: true)],
                ]),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(children: [
                  Expanded(child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: head))),
                  const SizedBox(height: 4),
                  ...play,
                  if (!tight) ...[const SizedBox(height: 12), _Toolbar(it)],
                ]),
              ),
            ]),
          );
        }
        // Phone: cover, title and facts scroll; progress, buttons, volume and footer stay in view.
        final size = [c.maxWidth - 32, c.maxHeight * 0.36, 420.0].reduce((a, b) => a < b ? a : b);
        final cover = CoverThumb(image: it.image, label: it.subtitle.isEmpty ? it.title : it.subtitle, size: size);
        return Column(children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(children: [cover, const SizedBox(height: 16), ...head]),
            ),
          ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  ...play,
                  const SizedBox(height: 8),
                  const _Volume(),
                  const SizedBox(height: 8),
                  _Toolbar(it),
                ]),
              ),
            ),
          ),
        ]);
      });
}

/// One line with what is played (the source; "Cache" first when it comes from there); when a
/// Sonos speaker gets something else, that in brackets as the target.
/// "(16 of 21)": position i (from 0) of n.
String _count(int i, int n) => t('({i} of {n})', {'i': i + 1, 'n': n});

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
    Widget chip(String s, {Color? color, Color? bg}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
              color: bg, border: Border.all(color: color ?? k.line, width: 1.5), borderRadius: BorderRadius.circular(6)),
          child: Text(s, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color)),
        );
    // Lossless from 24 bit red, at 16 bit yellow.
    Widget fact(String c) => c == src.codecLabel && src.tier != null
        ? (src.tier == 'hi' ? chip(c, color: k.bad, bg: k.badBg) : chip(c, color: k.warn, bg: k.warnBg))
        : chip(c);
    return Wrap(alignment: WrapAlignment.center, crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 4, children: [
      if (out == null && player.fromCache) chip(t('Cache'), color: Theme.of(context).colorScheme.primary),
      for (final c in src.chips) fact(c),
      if (target != null && !target.sameAs(src))
        Text(t('(Target: {q})', {'q': target.chips.join(' ')}), style: TextStyle(color: k.muted, fontSize: 13)),
    ]);
  }
}

/// Volume above the footer: this device's media volume, or the Sonos output's; for a group the
/// whole group, its rooms open upwards above it.
class _Volume extends StatefulWidget {
  const _Volume();

  @override
  State<_Volume> createState() => _VolumeState();
}

class _VolumeState extends State<_Volume> {
  bool open = false;

  @override
  void initState() {
    super.initState();
    if (!desktop) localVolume.start();
  }

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: Listenable.merge([sonos, localVolume]), builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final out = sonos.output;
    if (out == null) {
      if (desktop) return const SizedBox.shrink();
      // Phones have about 15 steps; a smaller step would often not change anything.
      return _VolumeRow(value: localVolume.level, label: t('Volume'), onChanged: localVolume.set, step: 7, big: true);
    }
    final members = out.grouped ? sonos.members : const <Room>[];
    final k = context.tok;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (members.length > 1) ...[
        InkWell(
          onTap: () => setState(() => open = !open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(children: [
              Text(t('Rooms ({n})', {'n': members.length}), style: TextStyle(color: k.muted, fontWeight: FontWeight.w600)),
              const Spacer(),
              Icon(open ? Icons.expand_more : Icons.expand_less, color: k.muted),
            ]),
          ),
        ),
        if (open)
          for (final r in members)
            Row(children: [
              SizedBox(width: 100, child: Text(r.name, overflow: TextOverflow.ellipsis, style: TextStyle(color: k.muted))),
              Expanded(child: _VolumeRow(value: r.volume ?? 0, label: r.name, onChanged: (v) => sonos.setVolume(v, room: r))),
            ]),
        if (open && desktop)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Align(alignment: Alignment.centerLeft, child: Text(t('Group'), style: TextStyle(color: k.muted, fontWeight: FontWeight.w600))),
          ),
      ],
      _VolumeRow(value: sonos.level, label: out.grouped ? t('Group volume') : t('Volume'), onChanged: (v) => sonos.setVolume(v), big: true),
    ]);
  }
}

/// − slider + value. Buttons and value keep the same width in every size, so rows end flush.
class _VolumeRow extends StatelessWidget {
  final int value, step;
  final String label;
  final ValueChanged<int> onChanged;
  final bool big;
  const _VolumeRow({required this.value, required this.label, required this.onChanged, this.step = 3, this.big = false});

  @override
  Widget build(BuildContext context) {
    final size = big ? 52.0 : 40.0;
    // − at the left edge, + at the right edge, the value between slider and + (all rows end flush).
    Widget btn(IconData icon, String tip, int delta) => SizedBox(
          width: 52,
          height: size,
          child: Align(
            alignment: delta < 0 ? Alignment.centerLeft : Alignment.centerRight,
            child: SizedBox(
              width: size,
              height: size,
              child: IconButton.filledTonal(
                tooltip: tip,
                padding: EdgeInsets.zero,
                iconSize: big ? 28 : 22,
                onPressed: () => onChanged(value + delta),
                icon: Icon(icon),
              ),
            ),
          ),
        );
    return Row(children: [
      btn(Icons.remove, t('Quieter'), -step),
      Expanded(
        child: Semantics(
          label: label,
          child: Slider(value: value.clamp(0, 100).toDouble(), max: 100, label: '$value', onChanged: (v) => onChanged(v.round())),
        ),
      ),
      SizedBox(
        width: 44,
        child: Text('$value', textAlign: TextAlign.center, style: TextStyle(fontSize: big ? 18 : 15, fontWeight: FontWeight.w800)),
      ),
      btn(Icons.add, t('Louder'), step),
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
    // With chapters ⏮ ⏭ go by chapter (after the last one to the next title), else by title.
    final byChapter = player.chapters.isNotEmpty;
    final many = byChapter || player.queue.length > 1;
    final scheme = Theme.of(context).colorScheme;
    return Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
      if (many)
        IconButton(
            iconSize: 32,
            tooltip: byChapter ? t('Previous chapter') : t('Previous'),
            onPressed: () => byChapter ? player.previousChapter() : player.skip(-1),
            icon: const Icon(Icons.skip_previous)),
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
      if (many)
        IconButton(
            iconSize: 32,
            tooltip: byChapter ? t('Next chapter') : t('Next'),
            onPressed: () => byChapter ? player.nextChapter() : player.skip(1),
            icon: const Icon(Icons.skip_next)),
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
  /// 2 × 2 instead of one row (desktop window too low).
  final bool grid;
  const _Toolbar(this.it, {this.grid = false});

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
    final tools = [
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
    ];
    return Container(
      decoration: BoxDecoration(color: k.panel2, borderRadius: BorderRadius.circular(14)),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: grid
          ? Column(mainAxisSize: MainAxisSize.min, children: [Row(children: tools.sublist(0, 2)), Row(children: tools.sublist(2))])
          : Row(children: tools),
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
    final current = player.chapterIndex;
    return ListView.builder(
      itemCount: it.chapters.length,
      itemBuilder: (context, i) {
        final c = it.chapters[i];
        final active = i == current;
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
