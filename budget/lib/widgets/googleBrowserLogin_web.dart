import 'dart:async';

import 'package:budget/widgets/accountAndBackup.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_web/web_only.dart' as web;

class GoogleBrowserLogin extends StatefulWidget {
  const GoogleBrowserLogin({super.key, required this.onSignedIn});

  final VoidCallback onSignedIn;

  @override
  State<GoogleBrowserLogin> createState() => _GoogleBrowserLoginState();
}

class _GoogleBrowserLoginState extends State<GoogleBrowserLogin> {
  StreamSubscription<GoogleSignInAuthenticationEvent>? _events;
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    setState(() {
      _ready = false;
      _failed = false;
    });
    await _events?.cancel();
    try {
      final google = await initializeGoogleBrowserLogin()
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      _events = google.authenticationEvents.listen((event) async {
        if (event is GoogleSignInAuthenticationEventSignIn) {
          try {
            await rememberGoogleBrowserAccount(event.user);
          } catch (_) {
            if (mounted) setState(() => _failed = true);
          }
          if (mounted) widget.onSignedIn();
        }
      }, onError: (Object _) {
        if (mounted) setState(() => _failed = true);
      });
      setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final arabic = Localizations.localeOf(context).languageCode == 'ar';
    if (_failed) {
      return TextButton(
        onPressed: _initialize,
        child: Text(arabic
            ? 'أعد محاولة تسجيل الدخول إلى Google'
            : 'Retry Google sign-in'),
      );
    }
    if (!_ready) return const CircularProgressIndicator();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: web.renderButton(
          configuration: web.GSIButtonConfiguration(
        size: web.GSIButtonSize.large,
        text: web.GSIButtonText.signinWith,
        locale: arabic ? 'ar' : 'en',
      )),
    );
  }
}
