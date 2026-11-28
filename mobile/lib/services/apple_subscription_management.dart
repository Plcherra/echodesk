import 'package:url_launcher/url_launcher.dart';

import '../config/apple_plans.dart';

/// Opens Apple's subscription management. EchoDesk cannot cancel an App Store
/// subscription itself.
Future<bool> openAppleSubscriptionManagement() async {
  final uri = Uri.parse(appleManageSubscriptionsUrl);
  if (!await canLaunchUrl(uri)) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
