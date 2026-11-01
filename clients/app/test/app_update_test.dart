// App update like tvjoe: the download is checked against SHA256SUMS before anything is
// installed; Linux installs with pkexec apt-get and then offers a restart.

import 'dart:convert';
import 'dart:io';

import 'package:audiojoe/api.dart';
import 'package:audiojoe/ui/common.dart';
import 'package:audiojoe/updates.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final pkg = utf8.encode('the new package');
  final good = sha256.convert(pkg).toString();
  final u = AppUpdate(latest: '0.2.0', name: 'audiojoe_0.2.0_amd64.deb', platform: 'linux');
  late Directory tmp;
  late String sums;
  late int sumsStatus;
  late List<List<String>> ran, started;
  late bool installOk;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('aj-update-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (call) async => tmp.path);
    sums = '$good  ${u.name}\n0000000000000000000000000000000000000000000000000000000000000000  other.apk\n';
    sumsStatus = 200;
    ran = [];
    started = [];
    installOk = true;
    runCommand = (cmd) async {
      ran.add(cmd);
      return installOk;
    };
    startAndQuit = (cmd) async => started.add(cmd);
    api.client = MockClient((req) async => switch (req.url.path) {
          '/api/v1/maintenance/sums' => http.Response(sums, sumsStatus),
          '/api/v1/maintenance/app/linux' => http.Response.bytes(pkg, 200),
          _ => http.Response('{}', 404),
        });
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('expectedSum reads sha256sum lines (also binary mode, upper case)', () {
    expect(expectedSum('$good  a.deb\n', 'a.deb'), good);
    expect(expectedSum('${good.toUpperCase()} *a.deb\n', 'a.deb'), good);
    expect(expectedSum('$good  a.deb\n', 'b.deb'), isNull);
    expect(expectedSum('not a sum  a.deb\n', 'a.deb'), isNull);
  });

  test('download with the right checksum is kept', () async {
    final f = await downloadAppUpdate(u, (_, _) {});
    expect(f.readAsBytesSync(), pkg);
    expect(f.path, endsWith('/updates/${u.name}'));
  });

  test('wrong checksum: refused, file deleted', () async {
    sums = '${'1' * 64}  ${u.name}\n';
    await expectLater(downloadAppUpdate(u, (_, _) {}), throwsA(isA<UpdateError>().having((e) => e.message, 'message', contains('Checksum wrong'))));
    expect(File('${tmp.path}/updates/${u.name}').existsSync(), isFalse);
  });

  test('no SHA256SUMS or no line for the package: refused before the download', () async {
    sumsStatus = 404;
    await expectLater(downloadAppUpdate(u, (_, _) {}), throwsA(isA<UpdateError>()));
    sumsStatus = 200;
    sums = '$good  other.deb\n';
    await expectLater(downloadAppUpdate(u, (_, _) {}), throwsA(isA<UpdateError>().having((e) => e.message, 'message', contains('missing'))));
    expect(File('${tmp.path}/updates/${u.name}').existsSync(), isFalse);
  });

  test('Windows: encoded PowerShell waits, installs, starts again only on success', () {
    final cmd = windowsInstallAndRestart(File(r"C:\Users\Jo O'Neil\AppData\Local\updates\audiojoe.msi"),
        r'C:\Program Files\audiojoe\audiojoe.exe', 4242);
    expect(cmd.sublist(0, cmd.length - 1), ['powershell', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand']);
    final b = base64.decode(cmd.last);
    final script = String.fromCharCodes([for (var i = 0; i < b.length; i += 2) b[i] | b[i + 1] << 8]);
    expect(script, startsWith('Wait-Process -Id 4242 -ErrorAction SilentlyContinue; '));
    expect(script, contains(r"""-ArgumentList '/i "C:\Users\Jo O''Neil\AppData\Local\updates\audiojoe.msi" /passive' -Wait -PassThru"""));
    expect(script, endsWith(r"""if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) { Start-Process -FilePath 'C:\Program Files\audiojoe\audiojoe.exe' }"""));
  });

  Future<void> show(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(navigatorKey: appNavigator, theme: buildTheme(Brightness.light), home: const Scaffold(body: SizedBox())));

  // The dialogs without real I/O: the checked file is given, the commands are recorded.
  File checked() => File('${tmp.path}/updates/${u.name}');
  Future<File> ok(AppUpdate _) async => checked();
  Future<File> wrong(AppUpdate _) async => throw UpdateError('Checksum wrong (expected a, got b)');

  testWidgets('Linux: checked → install with pkexec apt-get → restart offered', (tester) async {
    await show(tester);
    final said = <String>[];
    runAppUpdate(u, said.add, download: ok);
    await tester.pumpAndSettle();
    expect(said.single, 'Downloading version 0.2.0 …');
    expect(find.text('Package checked'), findsOneWidget);
    expect(find.textContaining('pkexec apt-get install -y ${checked().path}'), findsOneWidget);
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(ran.single, ['pkexec', 'apt-get', 'install', '-y', checked().path]);
    expect(find.text('Installed'), findsOneWidget);
    expect(find.text('Restart audiojoe now so the new version runs?'), findsOneWidget);
    await tester.tap(find.text('Restart'));
    await tester.pumpAndSettle();
    expect(started.single.first, 'sh');
    expect(started.single, contains('$pid'));
    expect(started.single.last, Platform.resolvedExecutable);
  });

  testWidgets('Linux: "Later" after the install does not restart', (tester) async {
    await show(tester);
    runAppUpdate(u, (_) {}, download: ok);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(ran, hasLength(1));
    expect(started, isEmpty);
  });

  testWidgets('install cancelled or failed: message, no restart', (tester) async {
    installOk = false;
    await show(tester);
    runAppUpdate(u, (_) {}, download: ok);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(find.text('Installation not completed'), findsOneWidget);
    expect(find.text('Installed'), findsNothing);
    expect(started, isEmpty);
  });

  testWidgets('"Cancel" in the check dialog installs nothing', (tester) async {
    await show(tester);
    runAppUpdate(u, (_) {}, download: ok);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(ran, isEmpty);
    expect(find.text('Package checked'), findsNothing);
  });

  testWidgets('wrong checksum: "Download failed", nothing installed', (tester) async {
    await show(tester);
    runAppUpdate(u, (_) {}, download: wrong);
    await tester.pumpAndSettle();
    expect(find.text('Download failed'), findsOneWidget);
    expect(find.textContaining('Checksum wrong'), findsOneWidget);
    expect(find.text('Package checked'), findsNothing);
    expect(ran, isEmpty);
  });
}
