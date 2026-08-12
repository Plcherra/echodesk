/// User-facing error and feedback messages.
/// Use these instead of raw exception strings for SnackBars and dialogs.
class AppStrings {
  AppStrings._();

  // Billing & payments
  static const couldNotOpenBilling =
      "Couldn't open billing portal. Please try again.";
  static const billingError = "Billing error. Please try again later.";

  // Calendar
  static const couldNotConnectCalendar =
      "Couldn't connect calendar. Please try again.";

  // General
  static const somethingWentWrong = "Something went wrong. Please try again.";
  static const couldNotComplete = "Couldn't complete. Please try again.";
  static const sessionExpired = "Session expired. Please sign in again.";
  static const couldNotLoadBusiness = "Couldn't load business details. Please try again.";

  // Settings - per-action errors
  static const billingPortalNoAccount =
      "No billing account. Complete a subscription first.";
  static const billingPortalStripeNotConfigured =
      "Billing is not configured. Please try again later.";
  static const calendarAuthUrlMissing =
      "Couldn't get calendar auth URL. Please try again.";
  static const calendarCannotOpenUrl =
      "Couldn't open browser for calendar. Please try again.";

  // Receptionist
  static const receptionistDeletionRequested =
      'Assistant deleted. Your number is held so you can attach it to a new assistant. '
      'If unused, we release it within 24–48 hours.';
  static const receptionistDeleteConfirmBody =
      'Calls will stop for this assistant. Your business number stays with your account '
      'so you can attach it when you create a new assistant. If you don’t reuse it, '
      'we’ll release it within 24–48 hours.';
  static const couldNotDeleteReceptionist =
      "Couldn't delete receptionist. Please try again.";
  static const pendingReleaseTitle = 'Number held';
  static const pendingReleaseSubtitle =
      'Release pending — create a new assistant to keep this number.';
  static const pendingReleaseCta = 'Create assistant';
  static const couldNotSaveSettings = "Couldn't save. Please try again.";
  static const callInitiated = "Call initiated";
  static const couldNotStartCall = "Couldn't start call. Please try again.";
  static const couldNotFetchWebsite = "Couldn't fetch website. Please try again.";

  // Number transfer
  static const transferUnderReview =
      'Transfer under review. Get a temporary business number below to continue setup.';
  static const transferSubmitted =
      'Submitted for review. Get a temporary business number to continue.';
  static const couldNotSubmitTransfer =
      "Couldn't submit transfer request. Please try again.";
  static const transferMustUseNewNumber =
      'While your transfer is under review, choose “Get a new business number” to continue.';
  static const transferSelectNewToContinue =
      'Submit a transfer for review, or choose “Get a new business number” to continue.';
}
