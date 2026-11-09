// Now playing: large cover, format chips and where it plays, then −15 / play / +30; tabs for
// details and chapters. Progress and buttons always stay in view. Desktop: the cover takes the
// left third, progress, buttons and footer (sleep timer, speed, output, up next) sit at the
// bottom right, no volume (the output overlay has it). Phone: volume and footer at the bottom.

import 'dart:async';

import 'package:flutter/material.dart';

import '../downloads.dart';
import '../l10n.dart';
import '../models.dart';
import '../player.dart';
import '../remote.dart';
import '../sonos.dart';
import '../sync.dart';
import '../volume.dart';
import 'common.dart';
import 'notes.dart';
import 'output.dart';
import 'up_next.dart';

class NowPlayingView extends StatefulWidget {
  const NowPlayingView({super.key});

  @override
  State<NowPlayingView> createState() => _NowPlayingViewState();
}

class _NowPlayingViewState extends State<NowPlayingView> {
  @override
  void initState() {
    super.initState();
    remote.message.addListener(_message);
  }

  @override
  void dispose() {
    remote.message.removeListener(_message);
    // Phones: leaving the page closes the overlay with it.
    outputOpen.value = false;
    super.dispose();
  }

  /// A controlled device went offline: say so once.
  void _message() {
    final m = remote.message.value;
    if (m == null || !mounted) return;
    remote.message.value = null;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([player, sonos, downloads, remote, outputOpen]),
        builder: (context, _) {
          if (outputOpen.value) return const OutputOverlay();
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
          _UpNextLine(it),
          if (remote.active)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.speaker, size: 18, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(t('Playing on {device}', {'device': out == null ? remote.shown(remote.target!) : 'Sonos ${out.grouped ? out.groupName ?? out.name : out.name}'}),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700)),
                ),
              ]),
            )
          // Below the facts as in the web player, so the fixed block with the buttons never moves.
          else if (_origin() case final line?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(line, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: k.muted)),
            ),
        ];
        // Progress (or "Live") and the buttons.
        final play = [
          if (player.live)
            Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Badge2(t('Live'), kind: 'ok'))
          else
            _Progress(),
          _Controls(),
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

/// Where the position comes from, grey below the facts (user 2026-11-07): "Taken over from …" for a few
/// seconds after playing here continued another device's position; while this device does not play and
/// the position comes from another device, "Playing on …" (it plays this title) or "Played on … · ago".
String? _origin() {
  final over = player.takenOver;
  if (over != null) return t('Taken over from {device} · {ago}', {'device': remote.shown(over.device), 'ago': ago(over.at)});
  final from = player.followed;
  if (from == null) return null;
  final d = remote.device(from.device);
  if (d != null && d.playing && d.key == player.item?.key) return t('Playing on {device}', {'device': d.shown});
  return t('Played on {device} · {ago}', {'device': remote.shown(from.device), 'ago': ago(from.at)});
}

/// "Up next: …" small and grey below the format chips (user 2026-11-09); nothing when nothing follows.
/// Looked up again only when the title, its place in the queue, the chapter, the controlled device or
/// the podcast continue list changes – not with every position tick.
class _UpNextLine extends StatefulWidget {
  final Item it;
  const _UpNextLine(this.it);
  @override
  State<_UpNextLine> createState() => _UpNextLineState();
}

class _UpNextLineState extends State<_UpNextLine> {
  String _sig = '';
  Future<String?>? _next;
  StreamSubscription<String>? _lists;

  @override
  void initState() {
    super.initState();
    _lists = sync.lists.listen((l) {
      if (l == 'podcasts' && widget.it.kind == 'episode' && mounted) setState(() => _sig = '');
    });
  }

  @override
  void dispose() {
    _lists?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.it;
    // An episode's continue list can change without an event reaching this view: again every 30 s.
    final slot = it.kind == 'episode' ? DateTime.now().millisecondsSinceEpoch ~/ 30000 : 0;
    final sig = [it.key, player.index, player.queue.length, player.chapterIndex, remote.target ?? '', slot].join('|');
    if (sig != _sig || _next == null) {
      _sig = sig;
      _next = upNextNow(it).catchError((_) => null);
    }
    return FutureBuilder<String?>(
      future: _next,
      builder: (context, snap) {
        final next = snap.data;
        if (next == null || next.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(t('Up next: {title}', {'title': next}),
              key: const ValueKey('up-next-line'),
              textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: context.tok.muted, fontSize: 13)),
        );
      },
    );
  }
}

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
      if (!remote.active && player.fromCache) chip(t('Cache'), color: Theme.of(context).colorScheme.primary),
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
    final playing = player.playing;
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
          onPressed: player.toggle,
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
    final local = !remote.active; // sleep timer and speed act on this device only
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
        tool(Icon(local ? Icons.smartphone : out != null ? Icons.speaker : Icons.devices, size: 28, color: local ? null : accent),
            local ? t('This device') : out?.short ?? remote.shown(remote.target!), () => outputOpen.value = true,
            tip: t('Output')),
        // "Up next" in place of "Offline" (user 2026-11-04; the cache pill at the top saves).
        tool(const Icon(Icons.queue_music, size: 28), t('Up next'), player.live ? null : () => showUpNext(context, it)),
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
