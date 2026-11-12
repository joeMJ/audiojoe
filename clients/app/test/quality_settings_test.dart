// Settings → Quality on the desktop (0.3.0): "Now playing" with source and libmpv output; on Linux the
// USB DAC from /proc/asound and the switch "Bit-perfect over USB" (user 2026-11-10 „185“, „187“).
import 'dart:io';

import 'package:audiojoe/models.dart';
import 'package:audiojoe/quality.dart';
import 'package:audiojoe/ui/common.dart';
import 'package:audiojoe/ui/quality_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// File reads of the page run on the real event loop; each step needs a real turn and a pump.
Future<void> settleIo(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
}

Future<void> show(WidgetTester tester, Widget child, {Size size = const Size(800, 900)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.dark), home: Scaffold(body: child)));
  await tester.pump();
}

/// /proc/asound as on a machine with a Scarlett Solo 4th Gen (stream0 as read there on 2026-11-10).
Directory fakeAsound({bool scarlett = true}) {
  final d = Directory.systemTemp.createTempSync('asound');
  File('${d.path}/cards').writeAsStringSync([
    ' 0 [PCH            ]: HDA-Intel - HDA Intel PCH',
    '                      HDA Intel PCH at 0xf7f10000 irq 33',
    if (scarlett) ...[
      ' 1 [Gen            ]: USB-Audio - Scarlett Solo 4th Gen',
      '                      Focusrite Scarlett Solo 4th Gen at usb-0000:00:14.0-5.1.4.1, high speed',
    ],
  ].join('\n'));
  if (scarlett) {
    Directory('${d.path}/card1').createSync();
    File('${d.path}/card1/stream0').writeAsStringSync('''
Focusrite Scarlett Solo 4th Gen at usb-0000:00:14.0-5.1.4.1, high speed : USB Audio

Playback:
  Status: Stop
  Interface 1
    Altset 1
    Format: S32_LE
    Channels: 2
    Endpoint: 0x01 (1 OUT) (SYNC)
    Rates: 44100, 48000, 88200, 96000, 176400, 192000
    Data packet interval: 125 us
    Bits: 24
    Channel map: FL FR

Capture:
  Status: Stop
  Interface 2
    Altset 1
    Format: S32_LE
    Channels: 4
    Rates: 44100, 48000, 88200, 96000, 176400, 192000
    Bits: 24
''');
  }
  return d;
}

void main() {
  tearDown(() {
    asoundRoot = '/proc/asound';
    qualityPrefs.bitPerfect = false;
    qualityPrefs.desktopDac = null;
  });

  test('ALSA: the USB DAC with its playback formats', () async {
    asoundRoot = fakeAsound().path;
    final cards = await alsaUsbCards();
    expect(cards, hasLength(1));
    expect(cards.first.id, 'Gen');
    expect(cards.first.name, 'Scarlett Solo 4th Gen');
    expect(cards.first.rates, [44100, 48000, 88200, 96000, 176400, 192000]);
    expect(cards.first.bits, 24);
    expect(cards.first.channels, 2);
    expect(cards.first.device, 'alsa/hw:CARD=Gen,DEV=0');
    asoundRoot = fakeAsound(scarlett: false).path;
    expect(await alsaUsbCards(), isEmpty);
  });

  test('Linux: music at a rate of the DAC goes to the DAC, other titles and rates through the mixer', () async {
    if (!Platform.isLinux) return;
    asoundRoot = fakeAsound().path;
    QualityPrefs.retries = 0;
    QualityPrefs.retryEvery = Duration.zero;
    Item music(int rate) => Item(key: 'track:1', kind: 'track', title: 'T', subtitle: 'A',
        quality: Quality(codec: 'flac', sampleRate: rate, bitDepth: 16));
    qualityPrefs.bitPerfect = true;
    await qualityPrefs.apply(music(44100));
    expect(qualityPrefs.desktopDac?.device, 'alsa/hw:CARD=Gen,DEV=0');
    await qualityPrefs.apply(music(384000));
    expect(qualityPrefs.desktopDac, isNull);
    await qualityPrefs.apply(const Item(key: 'episode:1', kind: 'episode', title: 'E', subtitle: 'P'));
    expect(qualityPrefs.desktopDac, isNull);
    qualityPrefs.bitPerfect = false;
    await qualityPrefs.apply(music(44100));
    expect(qualityPrefs.desktopDac, isNull);
  });

  testWidgets('desktop: Now playing with Source and Output', (tester) async {
    await show(tester, const SingleChildScrollView(child: QualitySettings()));
    await tester.pump();
    expect(find.text('Now playing'), findsOneWidget);
    expect(find.text('Source'), findsOneWidget);
    expect(find.text('Output'), findsOneWidget);
    expect(find.text('Handed to Android'), findsNothing);
  });

  testWidgets('Linux with Scarlett: DAC, formats, switch usable, volume note when switching on', (tester) async {
    if (!Platform.isLinux) return;
    final dir = await tester.runAsync(() async => fakeAsound().path);
    asoundRoot = dir!;
    await show(tester, const SingleChildScrollView(child: QualitySettings()));
    await settleIo(tester);
    expect(find.text('Scarlett Solo 4th Gen'), findsOneWidget);
    expect(find.text('24 bit · 44.1–192 kHz'), findsOneWidget);
    expect(find.text('Offered'), findsOneWidget);
    expect(find.textContaining('Music goes unchanged to the USB DAC. Podcasts and audiobooks keep the normal path. '),
        findsOneWidget);
    expect(find.textContaining('higher resolution than 24 bit / 48 kHz'), findsOneWidget);
    expect(find.text('Lower volume before bit-perfect playback'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('bit-perfect')));
    await tester.pumpAndSettle();
    // 0.3.2: the full-screen red warning (bit_perfect_warning_test.dart has the details).
    expect(find.text('Danger to hearing and headphones'), findsOneWidget);
    expect(find.text('Full volume can start immediately or with the next music title.'), findsOneWidget);
    expect(find.text('While audiojoe plays this way, other programs cannot use the DAC.'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('bit-perfect-cancel')));
    await tester.tap(find.byKey(const ValueKey('bit-perfect-cancel')));
    await tester.pumpAndSettle();
    expect(qualityPrefs.bitPerfect, isFalse);
  });

  testWidgets('Linux without a USB DAC: switch grey with the reason', (tester) async {
    if (!Platform.isLinux) return;
    final dir = await tester.runAsync(() async => fakeAsound(scarlett: false).path);
    asoundRoot = dir!;
    await show(tester, const SingleChildScrollView(child: QualitySettings()));
    await settleIo(tester);
    expect(find.text('None connected'), findsOneWidget);
    expect(find.text('Needs a USB DAC.'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('bit-perfect'))).onChanged, isNull);
  });

  test('Windows: WASAPI devices of USB sound devices', () {
    final dacs = matchWasapi(['Scarlett Solo 4th Gen'], [
      {'name': 'auto', 'description': 'Autoselect device'},
      {'name': 'wasapi/{0.0.0.00000000}.{aaa}', 'description': 'Lautsprecher (Realtek(R) Audio)'},
      {'name': 'wasapi/{0.0.0.00000000}.{bbb}', 'description': 'Lautsprecher (Scarlett Solo 4th Gen)'},
    ]);
    expect(dacs, hasLength(1));
    expect(dacs.first.name, 'Scarlett Solo 4th Gen');
    expect(dacs.first.device, 'wasapi/{0.0.0.00000000}.{bbb}');
    expect(dacs.first.exclusive, isTrue);
    expect(matchWasapi(const [], const [{'name': 'wasapi/x', 'description': 'Speakers (USB DAC)'}]), isEmpty);
  });

  test('Windows: USB names and playback endpoints from one PowerShell call', () {
    final (names, endpoints) = parsePnp('N\tScarlett Solo 4th Gen\r\n'
        'E\tLautsprecher (High Definition Audio Device)\tSWD\\MMDEVAPI\\{0.0.0.00000000}.{AAAA}\r\n'
        'E\tLautsprecher (Scarlett Solo 4th Gen)\tSWD\\MMDEVAPI\\{0.0.0.00000000}.{1334EE5D-24C5-4AC6-9187-B877D48B3581}\r\n');
    expect(names, ['Scarlett Solo 4th Gen']);
    expect(endpoints, hasLength(2));
    final dacs = matchWasapi(names, endpoints);
    expect(dacs.single.device, 'wasapi/{0.0.0.00000000}.{1334ee5d-24c5-4ac6-9187-b877d48b3581}');
  });

  test('texts of the diagnostics', () {
    expect(formatText({'encoding': 'float', 'rate': 96000, 'channels': 2}), '32-bit float · 96 kHz · 2 ch');
    expect(formatText({'encoding': '24', 'rate': 44100, 'channels': 2}), '24 bit · 44.1 kHz · 2 ch');
    expect(formatText(null), '–');
    final offered = [
      {'encoding': '24', 'rate': 44100, 'channels': 2, 'bitPerfect': false},
      {'encoding': '32', 'rate': 192000, 'channels': 2, 'bitPerfect': true},
    ];
    expect(offeredText(offered), '24 bit, 32 bit · 44.1–192 kHz');
    expect(offersBitPerfect(offered), isTrue);
    expect(offersBitPerfect(offered.take(1).toList()), isFalse);
  });
}
