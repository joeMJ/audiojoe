// Linux and Windows: the app draws the title bar itself (window_manager 0.5.2), one line as in
// tvjoe, but the name on the left (user 2026-11-04): line icon, "audiojoe" and the version on the
// left; on the right the pills, the moon and the window buttons in the look of the system
// (Ubuntu: round GNOME buttons, always on the right; Windows: the Windows 11 caption buttons).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n.dart';
import 'common.dart';
import 'pills.dart';
import 'shell.dart';

/// Height of the title bar (GNOME header bar: 46 px plus border).
const titleBarHeight = 48.0;

/// Version shown next to the name; set in main from the package info.
String appVersion = '';

/// Tests leave out the window buttons (no window manager there).
bool withWindowButtons = true;

/// Above everything on Linux and Windows (sign-in, pages, details): the title bar, and below it
/// the app. Its own overlay, so the tooltips of the pills work above the navigator.
class DesktopFrame extends StatefulWidget {
  final bool signedIn;
  final Widget child;
  const DesktopFrame({super.key, required this.signedIn, required this.child});
  @override
  State<DesktopFrame> createState() => _DesktopFrameState();
}

class _DesktopFrameState extends State<DesktopFrame> {
  // One entry for the whole life of the frame; it reads the current widget when it builds.
  late final entry = OverlayEntry(builder: _build);

  @override
  void didUpdateWidget(DesktopFrame old) {
    super.didUpdateWidget(old);
    // Allowed during this build: the overlay is below us and builds after us.
    entry.markNeedsBuild();
  }

  Widget _build(BuildContext context) => ValueListenableBuilder(
        valueListenable: shellPage,
        builder: (context, page, _) => Column(children: [
          // (Tests switch to the phone layout: then without the bar.)
          if (desktop) Builder(builder: (context) {
            final signedIn = widget.signedIn;
            final narrow = MediaQuery.sizeOf(context).width < 720;
            return TitleBar(windowButtons: withWindowButtons, actions: [
              if (signedIn) ...[
                const CachePill(),
                const StatusPills(),
                StoragePill(open: page == 7, onTap: () => shellPage.value = 7),
              ],
              const MoonButton(),
              // Narrow window (phone layout): the settings are not in the bottom bar.
              if (signedIn && narrow)
                IconButton(tooltip: t('Settings'), onPressed: () => shellPage.value = 6, icon: const Icon(Icons.settings)),
            ]);
          }),
          Expanded(child: widget.child),
        ]),
      );

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [entry]);
}

/// The line icon (Android monochrome icon): black when light, white when dark.
Widget lineIcon(BuildContext context, {double size = 24}) => Image.asset('assets/icon-line.png',
    height: size, width: size, color: Theme.of(context).colorScheme.onSurface, semanticLabel: 'audiojoe');

class TitleBar extends StatelessWidget implements PreferredSizeWidget {
  /// Pills and buttons between the name and the window buttons.
  final List<Widget> actions;
  /// Tests leave out the window buttons (no window manager there).
  final bool windowButtons;
  const TitleBar({super.key, required this.actions, this.windowButtons = true});

  @override
  Size get preferredSize => const Size.fromHeight(titleBarHeight);

  @override
  Widget build(BuildContext context) {
    final k = context.tok, scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Container(
        height: titleBarHeight,
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: k.line))),
        child: Stack(children: [
          // The whole bar moves the window; a double click maximizes. Buttons on top take their clicks.
          const Positioned.fill(child: DragToMoveArea(child: SizedBox.expand())),
          Row(children: [
            const SizedBox(width: 12),
            IgnorePointer(
              child: Row(children: [
                lineIcon(context),
                const SizedBox(width: 8),
                const Text('audiojoe', key: ValueKey('app-name'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                if (appVersion.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(appVersion, key: const ValueKey('app-version'), style: TextStyle(fontSize: 13, color: k.muted, fontWeight: FontWeight.w600)),
                ],
              ]),
            ),
            const SizedBox(width: 12),
            const Spacer(),
            Flexible(
              flex: 1000,
              child: Align(
                alignment: Alignment.centerRight,
                child: SingleChildScrollView(scrollDirection: Axis.horizontal, reverse: true, child: Row(mainAxisSize: MainAxisSize.min, children: actions)),
              ),
            ),
            const SizedBox(width: 10),
            if (windowButtons) const WindowButtons(),
          ]),
        ]),
      ),
    );
  }
}

/// Minimize, maximize/restore, close: on Windows the Windows 11 buttons, elsewhere round GNOME ones.
class WindowButtons extends StatefulWidget {
  const WindowButtons({super.key});
  @override
  State<WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<WindowButtons> with WindowListener {
  bool maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((m) => mounted ? setState(() => maximized = m) : null);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => maximized = true);
  @override
  void onWindowUnmaximize() => setState(() => maximized = false);

  void _toggle() => maximized ? windowManager.unmaximize() : windowManager.maximize();

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    if (Platform.isWindows) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 46, height: titleBarHeight, child: WindowCaptionButton.minimize(brightness: b, onPressed: windowManager.minimize)),
        SizedBox(
          width: 46,
          height: titleBarHeight,
          child: maximized
              ? WindowCaptionButton.unmaximize(brightness: b, onPressed: _toggle)
              : WindowCaptionButton.maximize(brightness: b, onPressed: _toggle),
        ),
        SizedBox(width: 46, height: titleBarHeight, child: WindowCaptionButton.close(brightness: b, onPressed: windowManager.close)),
      ]);
    }
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        GnomeButton(icon: Icons.minimize, tip: 'minimize', onTap: windowManager.minimize),
        GnomeButton(icon: maximized ? Icons.filter_none : Icons.crop_square, tip: 'maximize', onTap: _toggle),
        GnomeButton(icon: Icons.close, tip: 'close', onTap: windowManager.close),
      ]),
    );
  }
}

/// A round window button as in GNOME (Adwaita): 24 px circle, light grey, darker on hover.
class GnomeButton extends StatefulWidget {
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  const GnomeButton({super.key, required this.icon, required this.tip, required this.onTap});
  @override
  State<GnomeButton> createState() => _GnomeButtonState();
}

class _GnomeButtonState extends State<GnomeButton> {
  bool hover = false, down = false;

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).colorScheme.onSurface;
    final alpha = down ? 0.28 : hover ? 0.2 : 0.1;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: MouseRegion(
        onEnter: (_) => setState(() => hover = true),
        onExit: (_) => setState(() => (hover = false, down = false)),
        child: GestureDetector(
          key: ValueKey('window-${widget.tip}'),
          onTapDown: (_) => setState(() => down = true),
          onTapCancel: () => setState(() => down = false),
          onTap: () {
            setState(() => down = false);
            widget.onTap();
          },
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(shape: BoxShape.circle, color: fg.withValues(alpha: alpha)),
            child: Icon(widget.icon, size: widget.icon == Icons.filter_none ? 11 : 14, color: fg),
          ),
        ),
      ),
    );
  }
}
