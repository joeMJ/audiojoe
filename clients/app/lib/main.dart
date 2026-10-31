// audiojoe app for Android, Linux and Windows.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import 'api.dart';
import 'downloads.dart';
import 'player.dart';
import 'store.dart';
import 'sync.dart';
import 'ui/common.dart';
import 'ui/login.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    // Notification and lock-screen controls; keeps playing in the background.
    await JustAudioBackground.init(
      androidNotificationChannelId: 'io.github.joemj.audiojoe.playback',
      androidNotificationChannelName: 'Playback',
      androidNotificationOngoing: true,
    );
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

class _AudiojoeAppState extends State<AudiojoeApp> {
  late bool signedIn = widget.signedIn;
  bool started = false;

  void _start() {
    if (started) return;
    started = true;
    sync.start();
    downloads.check();
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
    return MaterialApp(
      title: 'audiojoe',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: signedIn ? Shell(onSignOut: _signOut) : LoginView(onDone: () => setState(() => signedIn = true)),
    );
  }
}
