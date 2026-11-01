// App updates: the app asks its own audiojoe server (never GitHub) whether a newer version is
// published, downloads it through the server and checks it against the release's SHA256SUMS
// before anything is installed. Like tvjoe (crates/tvjoe-gui/src/prefs.rs, offer/confirm_install/
// restart): Linux installs with `pkexec apt-get install -y` and then offers a restart, Windows
// closes, runs the MSI installer and starts again (tvjoe asks to reopen it by hand), Android
// hands the package to the system installer. The
// F-Droid build does nothing here.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'l10n.dart';

/// Build: `github` (default; checks for updates) or `fdroid` (updates come from F-Droid).
/// Set with `--dart-define=AUDIOJOE_DIST=fdroid` next to `--flavor fdroid`.
const appDist = String.fromEnvironment('AUDIOJOE_DIST', defaultValue: 'github');
bool get appUpdatesEnabled => appDist != 'fdroid';

String get appPlatform => Platform.isAndroid ? 'android' : Platform.isWindows ? 'windows' : 'linux';

/// The app's navigator; the update dialogs are shown through it (also from the start banner).
final appNavigator = GlobalKey<NavigatorState>();

class AppUpdate {
  final String latest, name, platform;
  AppUpdate({required this.latest, required this.name, required this.platform});
}

/// A failed update step with a message for the user.
class UpdateError implements Exception {
  final String message;
  UpdateError(this.message);
  @override
  String toString() => message;
}

/// Numeric comparison of versions like "0.0.21" (missing parts count as 0).
int compareVersions(String a, String b) {
  List<int> parts(String v) => v.split('+').first.split('.').map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0).toList();
  final x = parts(a), y = parts(b);
  for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

/// The newer version the server knows for this platform, or null (also when not managed).
Future<AppUpdate?> checkAppUpdate() async {
  if (!appUpdatesEnabled) return null;
  final m = await api.call('GET', '/maintenance') as Map;
  final apps = m['apps'] as Map?;
  final latest = apps?['latest'] as String?;
  final asset = apps?[appPlatform] as Map?;
  if (latest == null || asset == null) return null;
  final info = await PackageInfo.fromPlatform();
  if (compareVersions(latest, info.version) <= 0) return null;
  return AppUpdate(latest: latest, name: asset['name'] as String, platform: appPlatform);
}

/// SHA-256 (lower case) of [name] in a `sha256sum` listing, or null.
String? expectedSum(String sums, String name) {
  for (final line in const LineSplitter().convert(sums)) {
    final m = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$').firstMatch(line);
    if (m != null && m.group(2) == name) return m.group(1)!.toLowerCase();
  }
  return null;
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest d) => value = d;
  @override
  void close() {}
}

/// Downloads the installer through the server and checks it against SHA256SUMS of the same
/// release; a wrong or missing checksum deletes the file. Android: into the app's cache (the
/// installer reads it from there), desktop: into the cache folder `updates`.
Future<File> downloadAppUpdate(AppUpdate u, void Function(int done, int? total) progress) async {
  final sumsRes = await api.client.get(api.uri('/maintenance/sums'), headers: api.authHeaders).timeout(const Duration(seconds: 60));
  if (sumsRes.statusCode == 404) throw UpdateError(t('Release without SHA256SUMS – download refused'));
  if (sumsRes.statusCode != 200) throw ApiError(sumsRes.statusCode, 'SHA256SUMS (${sumsRes.statusCode})');
  final expected = expectedSum(utf8.decode(sumsRes.bodyBytes, allowMalformed: true), u.name);
  if (expected == null) throw UpdateError(t('{name} is missing in SHA256SUMS', {'name': u.name}));

  // With the system's separator: msiexec cannot open a path with "/" (error 1619, VM 2026-11-01).
  final sep = Platform.pathSeparator;
  final dir = Directory('${(Platform.isAndroid ? await getTemporaryDirectory() : await getApplicationCacheDirectory()).path}${sep}updates');
  await dir.create(recursive: true);
  final file = File('${dir.path}$sep${u.name}');
  final req = http.Request('GET', api.uri('/maintenance/app/${u.platform}'))..headers.addAll(api.authHeaders);
  final res = await api.client.send(req).timeout(const Duration(seconds: 60));
  if (res.statusCode != 200) throw ApiError(res.statusCode, 'download failed (${res.statusCode})');
  final sink = file.openWrite();
  final digest = _DigestSink();
  final hasher = sha256.startChunkedConversion(digest);
  var done = 0;
  try {
    await for (final chunk in res.stream) {
      sink.add(chunk);
      hasher.add(chunk);
      done += chunk.length;
      progress(done, res.contentLength);
    }
  } finally {
    await sink.close();
    hasher.close();
  }
  if (res.contentLength != null && done != res.contentLength) {
    await file.delete();
    throw ApiError(0, 'download incomplete');
  }
  final actual = digest.value.toString();
  if (actual != expected) {
    await file.delete();
    throw UpdateError(t('Checksum wrong (expected {expected}, got {actual})', {'expected': expected, 'actual': actual}));
  }
  return file;
}

/// The command that installs a checked package (shown before it runs). Windows: the installer
/// with a progress bar, per user (no administrator rights).
List<String> installCommand(File f) =>
    Platform.isWindows ? ['msiexec', '/i', f.path, '/passive'] : ['pkexec', 'apt-get', 'install', '-y', f.path];

/// Windows: waits until audiojoe has ended, runs the installer and starts audiojoe again when it
/// succeeded (0, or 3010: done, Windows restart pending). PowerShell gets the script encoded
/// (UTF-16LE, Base64), so paths with spaces or quotes need no further quoting.
List<String> windowsInstallAndRestart(File f, String exe, int waitFor) {
  String q(String s) => "'${s.replaceAll("'", "''")}'";
  final script = 'Wait-Process -Id $waitFor -ErrorAction SilentlyContinue; '
      '\$p = Start-Process -FilePath msiexec -ArgumentList ${q('/i "${f.path}" /passive')} -Wait -PassThru; '
      'if (\$p.ExitCode -eq 0 -or \$p.ExitCode -eq 3010) { Start-Process -FilePath ${q(exe)} }';
  final utf16 = <int>[for (final c in script.codeUnits) ...[c & 0xff, c >> 8]];
  return ['powershell', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', base64.encode(utf16)];
}

/// Runs a command and waits; true when it succeeded. Replaceable in tests.
Future<bool> Function(List<String> cmd) runCommand = (cmd) async {
  try {
    return (await Process.run(cmd.first, cmd.sublist(1))).exitCode == 0;
  } on ProcessException {
    return false;
  }
};

/// Starts a command without waiting, then ends the app. Replaceable in tests.
/// Windows: `detached` creates the child with DETACHED_PROCESS, and powershell.exe then does
/// nothing (tested in the VM 2026-11-01); `normal` uses CREATE_NO_WINDOW (Dart SDK
/// runtime/bin/process_win.cc) and the child keeps running after the app has ended.
Future<void> Function(List<String> cmd) startAndQuit = (cmd) async {
  await Process.start(cmd.first, cmd.sublist(1), mode: Platform.isWindows ? ProcessStartMode.normal : ProcessStartMode.detached);
  exit(0);
};

/// After the update (Linux): the same program again as soon as this process has ended.
Future<void> restartApp() {
  final s = Platform.resolvedExecutable;
  // After the package replaced it, Linux reports "… (deleted)".
  final exe = s.endsWith(' (deleted)') ? s.substring(0, s.length - ' (deleted)'.length) : s;
  return startAndQuit(['sh', '-c', r'while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; shift; exec "$@"', 'sh', '$pid', exe]);
}

Future<bool> _ask(String title, String text, String no, String yes) async {
  final ctx = appNavigator.currentContext;
  if (ctx == null) return false;
  return await showDialog<bool>(
        context: ctx,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: SelectableText(text)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(no)),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(yes)),
          ],
        ),
      ) ==
      true;
}

Future<void> _tell(String title, String text) async {
  final ctx = appNavigator.currentContext;
  if (ctx == null) return;
  await showDialog<void>(
    context: ctx,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: SelectableText(text),
      actions: [FilledButton(onPressed: () => Navigator.pop(c), child: Text(t('OK')))],
    ),
  );
}

/// Download, check, install – with the dialogs of tvjoe. Errors are shown, not thrown.
/// [download] replaces the download in tests.
Future<void> runAppUpdate(AppUpdate u, void Function(String) say, {Future<File> Function(AppUpdate)? download}) async {
  final File f;
  try {
    say(t('Downloading version {v} …', {'v': u.latest}));
    f = await (download ?? (u) => downloadAppUpdate(u, (_, _) {}))(u);
  } catch (e) {
    return _tell(t('Download failed'), '$e');
  }
  if (Platform.isAndroid) {
    try {
      await const MethodChannel('io.github.joemj.audiojoe/install').invokeMethod('apk', f.path);
    } catch (e) {
      say('${t('Update failed')}: $e');
    }
    return;
  }
  final cmd = installCommand(f);
  // Windows: end audiojoe so the installer can replace the files; it starts again afterwards.
  if (Platform.isWindows) {
    if (!await _ask(
        t('Installer checked'),
        '${t('The checksum (SHA-256) matches. audiojoe closes and installs with:')}\n\n${cmd.join(' ')}\n\n${t('Then audiojoe starts again.')}',
        t('Cancel'),
        t('Install'))) {
      return;
    }
    try {
      await startAndQuit(windowsInstallAndRestart(f, Platform.resolvedExecutable, pid));
    } catch (e) {
      await _tell(t('Installation not started'), '$e');
    }
    return;
  }
  if (!await _ask(t('Package checked'),
      '${t('The checksum (SHA-256) matches. Install with:')}\n\n${cmd.join(' ')}\n\n${t('Then restart audiojoe.')}', t('Cancel'), t('Install'))) {
    return;
  }
  if (!await runCommand(cmd)) {
    return _tell(t('Installation not completed'), t('Cancelled or failed.'));
  }
  if (await _ask(t('Installed'), t('Restart audiojoe now so the new version runs?'), t('Later'), t('Restart'))) {
    try {
      await restartApp();
    } catch (e) {
      await _tell(t('Restart not possible'), '$e');
    }
  }
}
