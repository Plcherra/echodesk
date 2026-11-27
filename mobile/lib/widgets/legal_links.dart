import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// In-app links to the public privacy policy and terms.
class LegalLinks extends StatelessWidget {
  const LegalLinks({super.key, this.alignStart = false});

  /// Left-aligned rows for Settings. Centered buttons on auth screens.
  final bool alignStart;

  static const privacyPolicyUrl = 'https://echodesk.us/privacy.html';
  static const termsUrl = 'https://echodesk.us/terms.html';

  @override
  Widget build(BuildContext context) {
    if (alignStart) {
      return Column(
        children: [
          ListTile(
            title: const Text('Privacy Policy'),
            contentPadding: EdgeInsets.zero,
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => openLegalUrl(privacyPolicyUrl),
          ),
          ListTile(
            title: const Text('Terms'),
            contentPadding: EdgeInsets.zero,
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => openLegalUrl(termsUrl),
          ),
        ],
      );
    }

    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton(
          onPressed: () => openLegalUrl(privacyPolicyUrl),
          child: const Text('Privacy Policy'),
        ),
        TextButton(
          onPressed: () => openLegalUrl(termsUrl),
          child: const Text('Terms'),
        ),
      ],
    );
  }
}

Future<void> openLegalUrl(String url) async {
  final uri = Uri.parse(url);
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
