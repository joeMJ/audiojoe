// App updates: the app asks its own audiojoe server (never GitHub) whether a newer version is
// published, downloads it through the server and hands it to the system – Android opens the
// package installer, desktop opens the saved file. The F-Droid build does nothing here.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';

/// Build: `github` (default; checks for updates) or `fdroid` (updates come from F-Droid).
/// Set with `--dart-define=AUDIOJOE_DIST=fdroid` next to `--flavor fdroid`.
const appDist = String.fromEnvironment('AUDIOJOE_DIST', defaultValue: 'github');
bool get appUpdatesEnabled => appDist != 'fdroid';

String get appPlatform => Platform.isAndroid ? 'android' : Platform.isWindows ? 'windows' : 'linux';

class AppUpdate {
  final String latest, name, platform;
  AppUpdate({required this.latest, required this.name, required this.platform});
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

/// Downloads the installer through the server: Android into the app's cache (the installer
/// reads it from there), desktop into the Downloads folder.
Future<File> downloadAppUpdate(AppUpdate u, void Function(int done, int? total) progress) async {
  final dir = Platform.isAndroid
      ? Directory('${(await getTemporaryDirectory()).path}/updates')
      : (await getDownloadsDirectory() ?? await getApplicationSupportDirectory());
  await dir.create(recursive: true);
  final file = File('${dir.path}/${u.name}');
  final req = http.Request('GET', api.uri('/maintenance/app/${u.platform}'))..headers.addAll(api.authHeaders);
  final res = await api.client.send(req).timeout(const Duration(seconds: 60));
  if (res.statusCode != 200) throw ApiError(res.statusCode, 'download failed (${res.statusCode})');
  final sink = file.openWrite();
  var done = 0;
  try {
    await for (final chunk in res.stream) {
      sink.add(chunk);
      done += chunk.length;
      progress(done, res.contentLength);
    }
  } finally {
    await sink.close();
  }
  if (res.contentLength != null && done != res.contentLength) {
    await file.delete();
    throw ApiError(0, 'download incomplete');
  }
  return file;
}

/// Hands the downloaded file to the system: Android's package installer (asks the user), on
/// desktop the file opens with the installer of the system (MSI, .deb).
Future<void> installAppUpdate(File f) async {
  if (Platform.isAndroid) {
    await const MethodChannel('io.github.joemj.audiojoe/install').invokeMethod('apk', f.path);
  } else {
    await launchUrl(Uri.file(f.path));
  }
}

/// Download and hand over, with messages for the user; errors are reported, not thrown.
Future<void> runAppUpdate(AppUpdate u, void Function(String) say, String Function(String, [Map<String, Object>]) t) async {
  try {
    say(t('Downloading version {v} …', {'v': u.latest}));
    final f = await downloadAppUpdate(u, (_, _) {});
    if (Platform.isAndroid) {
      await installAppUpdate(f);
    } else {
      say(t('Saved as {file}. Opening the installer …', {'file': f.path}));
      await installAppUpdate(f);
    }
  } catch (e) {
    say('${t('Update failed')}: $e');
  }
}
