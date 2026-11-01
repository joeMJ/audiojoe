// Settings → Maintenance: "Check for updates" asks the server to check now, waits for the new
// status and then offers "Install now" (server behind) and the newer app.

import 'dart:convert';

import 'package:audiojoe/api.dart';
import 'package:audiojoe/ui/common.dart';
import 'package:audiojoe/ui/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// A server with the update script: [latest] as the newest release, checked at [checked].
Map<String, dynamic> maintenance({required String latest, required String checked, String? request, String result = 'ok'}) => {
      'version': '0.1.0',
      'mode': 'notify',
      'managed': true,
      'requested': request != null,
      'request': request,
      'apps': {'latest': latest, 'linux': {'name': 'audiojoe_${latest}_amd64.deb'}, 'windows': {'name': 'audiojoe-$latest-windows-x86_64.msi'}},
      'status': {'installed': '0.1.0', 'latest': latest, 'result': result, 'checked_at': checked, 'debian': {}, 'backups': []},
    };

void main() {
  late List<String> calls;
  late Map<String, dynamic> Function() state;

  setUp(() {
    PackageInfo.setMockInitialValues(appName: 'audiojoe', packageName: 'audiojoe', version: '0.1.0', buildNumber: '1', buildSignature: '');
    MaintenanceSettings.checkEvery = const Duration(seconds: 2);
    MaintenanceSettings.checkWait = const Duration(seconds: 90);
    calls = [];
    api.client = MockClient((req) async {
      calls.add('${req.method} ${req.url.path}');
      final body = req.url.path == '/api/v1/maintenance/check' ? {'requested': true, 'request': 'check'} : state();
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    });
  });

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: const Scaffold(body: MaintenanceSettings())));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('up to date: check, then a newer server and app are offered', (tester) async {
    var checked = false;
    state = () => checked
        ? maintenance(latest: '0.2.0', checked: '2026-11-01T18:00:00Z', result: 'available')
        : maintenance(latest: '0.1.0', checked: '2026-11-01T03:00:00Z');
    await show(tester);
    expect(find.text('Check for updates'), findsOneWidget);
    expect(find.text('Install now'), findsNothing);
    expect(find.textContaining('Download version'), findsNothing);

    await tester.tap(find.text('Check for updates'));
    await tester.pump();
    expect(find.text('Checking …'), findsOneWidget);
    expect(calls, contains('POST /api/v1/maintenance/check'));

    checked = true; // the script has answered
    await tester.pump(const Duration(seconds: 3));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Checking …'), findsNothing);
    expect(find.text('Install now'), findsOneWidget);
    expect(find.text('Download version 0.2.0'), findsOneWidget);

    await tester.tap(find.text('Install now'));
    await tester.pump();
    expect(calls, contains('POST /api/v1/maintenance/update'));
  });

  testWidgets('nothing newer: back to "Check for updates", no install', (tester) async {
    state = () => maintenance(latest: '0.1.0', checked: calls.contains('POST /api/v1/maintenance/check') ? '2026-11-01T18:00:00Z' : '2026-11-01T03:00:00Z');
    await show(tester);
    await tester.tap(find.text('Check for updates'));
    await tester.pump(const Duration(seconds: 3));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Check for updates'), findsOneWidget);
    expect(find.text('Install now'), findsNothing);
    expect(find.text('Up to date.'), findsWidgets);
  });

  testWidgets('no answer in time: message, button back', (tester) async {
    MaintenanceSettings.checkWait = Duration.zero;
    state = () => maintenance(latest: '0.1.0', checked: '2026-11-01T03:00:00Z');
    await show(tester);
    await tester.tap(find.text('Check for updates'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('The check takes longer; the result appears here later.'), findsOneWidget);
    expect(find.text('Check for updates'), findsOneWidget);
  });

  testWidgets('install requested: disabled, also from an older server (requested only)', (tester) async {
    state = () => maintenance(latest: '0.2.0', checked: '2026-11-01T03:00:00Z', request: 'now', result: 'available');
    await show(tester);
    expect(find.text('Update requested'), findsOneWidget);
    expect(find.text('Install now'), findsNothing);

    state = () => maintenance(latest: '0.2.0', checked: '2026-11-01T03:00:00Z', result: 'available')
      ..['requested'] = true
      ..remove('request');
    await tester.pumpWidget(const SizedBox());
    await show(tester);
    expect(find.text('Update requested'), findsOneWidget);
  });

  testWidgets('a check still running on the server shows "Checking …"', (tester) async {
    state = () => maintenance(latest: '0.1.0', checked: '2026-11-01T03:00:00Z', request: 'check');
    await show(tester);
    expect(find.text('Checking …'), findsOneWidget);
  });
}
