// Settings → Maintenance: "Check for updates" asks the server to check now, waits for the new
// status and then offers "Update server now to …" (server behind) and the newer app. Both
// buttons are always there on a server with the update script, also before its first check.

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
    MaintenanceSettings.updateWait = const Duration(minutes: 5);
    MaintenanceSettings.updatingReload = const Duration(seconds: 5);
    calls = [];
    api.client = MockClient((req) async {
      calls.add('${req.method} ${req.url.path}');
      final body = req.url.path == '/api/v1/maintenance/check' ? {'requested': true, 'request': 'check'} : state();
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    });
  });

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: const Scaffold(body: SingleChildScrollView(child: MaintenanceSettings()))));
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
    expect(find.text('Update server now to 0.2.0'), findsNothing);
    expect(find.text('Download version 0.2.0'), findsNothing);

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
    expect(find.text('Update server now to 0.2.0'), findsOneWidget);
    expect(find.text('Download version 0.2.0'), findsOneWidget);

    await tester.tap(find.text('Update server now to 0.2.0'));
    await tester.pump();
    expect(calls, contains('POST /api/v1/maintenance/update'));
    // The app waits for the result (user 2026-11-08): "Updating to …", then a message.
    expect(find.text('Updating to 0.2.0 …'), findsOneWidget);
    state = () => maintenance(latest: '0.2.0', checked: '2026-11-01T18:05:00Z', result: 'updated')..['version'] = '0.2.0';
    await tester.pump(const Duration(seconds: 3));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('The server now runs 0.2.0.'), findsOneWidget);
    expect(find.text('Updating to 0.2.0 …'), findsNothing);
  });

  testWidgets('update: the server reports "updating", then fails – message and "Last attempt"', (tester) async {
    final now = DateTime.now().toUtc();
    state = () => maintenance(latest: '0.2.0', checked: now.subtract(const Duration(minutes: 1)).toIso8601String(), result: 'available');
    await show(tester);
    await tester.tap(find.text('Update server now to 0.2.0'));
    await tester.pump();
    state = () => maintenance(latest: '0.2.0', checked: now.toIso8601String(), result: 'updating');
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Updating to 0.2.0 …'), findsOneWidget);

    const why = 'package 0.2.0 could not be downloaded or its checksum is wrong (HTTP 503, 3 attempts)';
    state = () => maintenance(latest: '0.2.0', checked: now.add(const Duration(minutes: 1)).toIso8601String(), result: 'failed')
      ..['status']['message'] = why
      ..['status']['last_update'] = {'from': '0.0.9', 'to': '0.1.0', 'at': '2026-11-01T02:00:00Z', 'result': 'updated'}
      ..['status']['last_attempt'] = {'from': '0.1.0', 'to': '0.2.0', 'at': now.toIso8601String(), 'result': 'failed', 'message': why};
    await tester.pump(const Duration(seconds: 3));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Update failed: $why'), findsOneWidget);
    expect(find.text('Last attempt'), findsOneWidget);
    expect(find.textContaining('0.1.0 → 0.2.0 on '), findsOneWidget);
    expect(find.textContaining('· failed: $why'), findsOneWidget);
    expect(find.text('Update server now to 0.2.0'), findsOneWidget); // can be tried again
  });

  testWidgets('update: no result in time – message, button back', (tester) async {
    MaintenanceSettings.updateWait = Duration.zero;
    state = () => maintenance(latest: '0.2.0', checked: '2026-11-01T18:00:00Z', result: 'available');
    await show(tester);
    await tester.tap(find.text('Update server now to 0.2.0'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('The update takes longer; the result appears here later.'), findsOneWidget);
    expect(find.text('Update server now to 0.2.0'), findsOneWidget);
  });

  testWidgets('opened while the server updates: "Updating to …", page reloads until done', (tester) async {
    MaintenanceSettings.updatingReload = const Duration(seconds: 1);
    state = () => maintenance(latest: '0.2.0', checked: DateTime.now().toUtc().toIso8601String(), result: 'updating');
    await show(tester);
    expect(find.text('Updating to 0.2.0 …'), findsOneWidget);
    state = () => maintenance(latest: '0.2.0', checked: DateTime.now().toUtc().toIso8601String(), result: 'updated')..['version'] = '0.2.0';
    await tester.pump(const Duration(seconds: 2));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Updating to 0.2.0 …'), findsNothing);
    // An old "updating" (a killed run) does not count.
    state = () => maintenance(latest: '0.2.0', checked: '2026-11-01T03:00:00Z', result: 'updating');
    await tester.pumpWidget(const SizedBox());
    await show(tester);
    expect(find.textContaining('Updating to'), findsNothing);
  });

  test('"Last attempt" only when newer than the last update', () {
    Map st(String attempt, String? done) => {
          'last_attempt': {'from': '0.1.0', 'to': '0.2.0', 'at': attempt, 'result': 'failed', 'message': 'x'},
          'last_update': done == null ? null : {'from': '0.0.9', 'to': '0.1.0', 'at': done, 'result': 'updated'},
        };
    expect(MaintenanceSettings.lastAttempt(st('2026-11-08T12:00:00Z', '2026-11-07T21:00:00Z')), isNotNull);
    expect(MaintenanceSettings.lastAttempt(st('2026-11-07T20:00:00Z', '2026-11-07T21:00:00Z')), isNull);
    expect(MaintenanceSettings.lastAttempt(st('2026-11-08T12:00:00Z', null)), isNotNull);
    expect(MaintenanceSettings.lastAttempt({'last_attempt': null}), isNull);
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
    expect(find.text('Update server now'), findsOneWidget); // there, but disabled
    expect(tester.widget<OutlinedButton>(find.ancestor(of: find.text('Update server now'), matching: find.byWidgetPredicate((w) => w is OutlinedButton))).onPressed, isNull);
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
    expect(find.text('Update server now to 0.2.0'), findsNothing);

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

  testWidgets('never checked (fresh server, no status yet): both buttons, unknown values', (tester) async {
    state = () => {'version': '0.1.3', 'mode': 'auto', 'managed': true, 'requested': false, 'request': null, 'apps': null, 'status': null};
    await show(tester);
    expect(find.text('Check for updates'), findsOneWidget);
    expect(find.text('Update server now'), findsOneWidget);
    expect(find.text('0.1.3'), findsOneWidget);
    expect(find.text('unknown – not checked yet'), findsOneWidget);
    expect(find.text('never'), findsOneWidget);
    expect(find.text('Updates last installed'), findsOneWidget);
    expect(find.text('Last cleaned up'), findsOneWidget);
    expect(find.text('not yet'), findsNWidgets(2));
    MaintenanceSettings.checkWait = Duration.zero;
    await tester.tap(find.text('Check for updates'));
    await tester.pump();
    expect(calls, contains('POST /api/v1/maintenance/check'));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Debian: last installed and last cleaned up with packages; failure in red', (tester) async {
    state = () => maintenance(latest: '0.1.0', checked: '2026-11-01T03:00:00Z', result: 'failed')
      ..['status']['message'] = 'release list not reachable'
      ..['status']['debian'] = {
        'last_upgrade': {'at': '2026-11-02T06:14:00Z', 'packages': ['openssl', 'tzdata']},
        'last_removal': {'at': '2026-11-02T06:15:00Z', 'packages': ['linux-image-6.12.1']},
        'pending': 0,
        'automatic': true,
      };
    await show(tester);
    expect(find.textContaining('2 packages (openssl, tzdata)'), findsOneWidget);
    expect(find.textContaining('1 package removed (linux-image-6.12.1)'), findsOneWidget);
    expect(find.text('install and clean up daily'), findsOneWidget);
    expect(find.text('Last check or update failed: release list not reachable'), findsOneWidget);
  });

  testWidgets('server without the update script: version and note, no buttons', (tester) async {
    state = () => {'version': '0.1.3', 'mode': 'auto', 'managed': false, 'requested': false, 'request': null, 'apps': null, 'status': null};
    await show(tester);
    expect(find.text('0.1.3'), findsOneWidget);
    expect(find.textContaining('Updates are not managed here'), findsOneWidget);
    expect(find.text('Check for updates'), findsNothing);
  });

  testWidgets('older server without status (before 0.1.3): "Update server now" only', (tester) async {
    PackageInfo.setMockInitialValues(appName: 'audiojoe', packageName: 'audiojoe', version: '0.1.3', buildNumber: '1', buildSignature: '');
    var requested = false;
    api.client = MockClient((req) async {
      calls.add('${req.method} ${req.url.path}');
      if (req.url.path == '/api/v1/maintenance/update') requested = true;
      return http.Response(jsonEncode({'version': '0.1.2', 'mode': 'auto', 'managed': false, 'requested': requested, 'request': requested ? 'now' : null, 'apps': null, 'status': null}), 200,
          headers: {'content-type': 'application/json'});
    });
    await show(tester);
    expect(find.text('Update server now'), findsOneWidget);
    expect(find.text('Check for updates'), findsNothing);
    expect(find.textContaining('Updates are not managed here'), findsNothing);
    await tester.tap(find.text('Update server now'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(calls, contains('POST /api/v1/maintenance/update'));
    expect(find.text('Update requested'), findsOneWidget);
  });
}
