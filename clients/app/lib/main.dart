// audiojoe app for Android, Linux and Windows.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import 'api.dart';
import 'appearance.dart';
import 'downloads.dart';
import 'media_session.dart';
import 'remote.dart';
import 'player.dart';
import 'l10n.dart';
import 'store.dart';
import 'sync.dart';
import 'updates.dart';
import 'ui/common.dart';
import 'ui/lists.dart';
import 'ui/login.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    // Notification and lock-screen controls; keeps playing in the background.
    await startMediaSession();
  } else {
    // Desktop: libmpv (bit-exact FLAC, any sample rate).
    JustAudioMediaKit.ensureInitialized(linux: true, windows: true);
    JustAudioMediaKit.title = 'audiojoe';
  }
  await Stores.open();
  final signedIn = await api.loadSession();
  runApp(AudiojoeApp(signedIn: signedIn));
}

class AudiojoeApp extends StatefulWidget {
  final bool signedIn;
  const AudiojoeApp({super.key, required this.signedIn});
  @override
  State<AudiojoeApp> createState() => _AudiojoeAppState();
}

final messenger = GlobalKey<ScaffoldMessengerState>();

class _AudiojoeAppState extends State<AudiojoeApp> {
  late bool signedIn = widget.signedIn;
  bool started = false;

  @override
  void initState() {
    super.initState();
    api.onRejected = _rejected;
    player.problems.stream.listen((s) => messenger.currentState?.showSnackBar(SnackBar(content: Text(t(s)))));
  }

  /// The server rejected the token: back to the sign-in page, the server address stays filled in.
  Future<void> _rejected() async {
    if (!signedIn) return;
    signedIn = false;
    remote.release();
    await player.stop();
    await sync.stop();
    await api.clearSession();
    if (mounted) setState(() => started = false);
  }

  void _start() {
    if (started) return;
    started = true;
    sync.start();
    downloads.check();
    connectLists();
    unawaited(player.cueLast().then((_) => remote.findPlaying()));
    unawaited(_offerUpdate());
  }

  /// A newer app version the server knows: one banner per version, "Later" keeps quiet
  /// until the next version. Nothing is downloaded without a tap.
  Future<void> _offerUpdate() async {
    await Future<void>.delayed(const Duration(seconds: 4));
    AppUpdate? u;
    try {
      u = await checkAppUpdate();
    } catch (_) {
      return;
    }
    if (u == null || !mounted) return;
    if (Stores.device.get('update')?['skip'] == u.latest) return;
    final m = messenger.currentState;
    if (m == null) return;
    void say(String s) => m.showSnackBar(SnackBar(content: Text(s)));
    final update = u;
    m.showMaterialBanner(MaterialBanner(
      content: Text(t('audiojoe {v} is available.', {'v': update.latest})),
      leading: const Icon(Icons.system_update_alt),
      actions: [
        TextButton(
          onPressed: () {
            m.hideCurrentMaterialBanner();
            Stores.device.put('update', {'skip': update.latest});
          },
          child: Text(t('Later')),
        ),
        FilledButton(
          onPressed: () {
            m.hideCurrentMaterialBanner();
            unawaited(runAppUpdate(update, say));
          },
          child: Text(Platform.isAndroid ? t('Install') : t('Download')),
        ),
      ],
    ));
  }

  Future<void> _signOut() async {
    try {
      await api.call('POST', '/auth/logout');
    } catch (_) {}
    await player.stop();
    await sync.stop();
    await api.clearSession();
    setState(() => (signedIn = false, started = false));
  }

  @override
  Widget build(BuildContext context) {
    if (signedIn) _start();
    return ValueListenableBuilder(
      valueListenable: appearance,
      builder: (context, mode, _) => MaterialApp(
        title: 'audiojoe',
        scaffoldMessengerKey: messenger,
        navigatorKey: appNavigator,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: mode,
        // Below the app the platform brightness is known: the title bar follows the moon button.
        builder: (context, child) {
          syncTitleBar(isDark(context));
          return child!;
        },
        home: signedIn ? Shell(onSignOut: _signOut) : LoginView(onDone: () => setState(() => signedIn = true)),
      ),
    );
  }
}
