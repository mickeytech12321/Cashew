import 'package:flutter/widgets.dart';

class GoogleBrowserLogin extends StatelessWidget {
  const GoogleBrowserLogin({super.key, required this.onSignedIn});
  final VoidCallback onSignedIn;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
