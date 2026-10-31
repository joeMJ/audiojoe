// Sign-in: server address, user name, password, TOTP code, device name.

import 'dart:io';

import 'package:flutter/material.dart';

import '../api.dart';
import '../l10n.dart';
import 'common.dart';

class LoginView extends StatefulWidget {
  final VoidCallback onDone;
  const LoginView({super.key, required this.onDone});
  @override
  State<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<LoginView> {
  final server = TextEditingController(text: api.base);
  final user = TextEditingController(), pass = TextEditingController(), code = TextEditingController();
  late final device = TextEditingController(
      text: Platform.isAndroid ? 'Android' : '${Platform.operatingSystem[0].toUpperCase()}${Platform.operatingSystem.substring(1)} · ${Platform.localHostname}');
  String error = '';
  bool busy = false;

  Future<void> _submit() async {
    setState(() => (busy = true, error = ''));
    try {
      await api.login(server.text, user.text, pass.text, code.text, device.text);
      widget.onDone();
    } on ApiError catch (e) {
      setState(() => (
            busy = false,
            error = e.status == 429
                ? t('Too many attempts. Please wait 15 minutes.')
                : e.status == 0
                    ? t('Server not reachable.')
                    : t('Sign-in failed. Check name, password and code.')
          ));
    }
  }

  @override
  Widget build(BuildContext context) {
    InputDecoration d(String l, [String? hint]) => InputDecoration(labelText: l, hintText: hint);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: AutofillGroup(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('audiojoe', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
                const SizedBox(height: 20),
                TextField(controller: server, keyboardType: TextInputType.url, decoration: d(t('Server'), 'https://audio.example.org')),
                const SizedBox(height: 12),
                TextField(controller: user, autofillHints: const [AutofillHints.username], decoration: d(t('User name'))),
                const SizedBox(height: 12),
                TextField(controller: pass, obscureText: true, autofillHints: const [AutofillHints.password], decoration: d(t('Password'))),
                const SizedBox(height: 12),
                TextField(controller: code, keyboardType: TextInputType.number, maxLength: 6,
                    autofillHints: const [AutofillHints.oneTimeCode], decoration: d(t('Code from the authenticator app')), onSubmitted: (_) => _submit()),
                TextField(controller: device, decoration: d(t('Device name'))),
                const SizedBox(height: 20),
                FilledButton(onPressed: busy ? null : _submit, child: Text(t('Sign in'))),
                if (error.isNotEmpty)
                  Padding(padding: const EdgeInsets.only(top: 12), child: Text(error, style: TextStyle(color: context.tok.bad, fontWeight: FontWeight.w700))),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
