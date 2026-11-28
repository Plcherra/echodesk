"""Verify App Store signed transactions and notifications with Apple's root CAs.

Uses Apple's app-store-server-library. The private key is only needed to call
the App Store Server API. JWS verification uses the public roots in
backend/certs/apple and the certificate chain inside the JWS.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

_AUTO_RENEWABLE = "Auto-Renewable Subscription"


class AppleVerificationError(Exception):
    def __init__(self, message: str, *, status_code: int = 400):
        super().__init__(message)
        self.status_code = status_code


class AppleIapConfigError(AppleVerificationError):
    def __init__(self, message: str):
        super().__init__(message, status_code=503)


def _settings():
    from config import settings

    return settings


def _enum_value(value: Any) -> Any:
    if value is None:
        return None
    return getattr(value, "value", value)


def _bundle_id() -> str:
    bundle = (_settings().apple_bundle_id or "").strip()
    if not bundle:
        raise AppleIapConfigError("APPLE_BUNDLE_ID is not set.")
    return bundle


def _app_apple_id() -> int | None:
    raw = (_settings().apple_app_apple_id or "").strip()
    if not raw:
        return None
    try:
        return int(raw)
    except ValueError as exc:
        raise AppleIapConfigError("APPLE_APP_APPLE_ID must be the numeric App Store app id.") from exc


def load_root_certificates() -> list[bytes]:
    override = (_settings().apple_root_ca_path or "").strip()
    directory = Path(override) if override else Path(__file__).resolve().parent.parent / "certs" / "apple"
    certs = [path.read_bytes() for path in sorted(directory.glob("*.cer")) if path.is_file()]
    if not certs:
        raise AppleIapConfigError(f"No Apple root certificates (.cer) in {directory}.")
    return certs


def _environment_enum(name: str):
    from appstoreserverlibrary.models.Environment import Environment

    key = (name or "").strip().lower()
    if key in {"production", "prod"}:
        return Environment.PRODUCTION
    if key == "xcode":
        return Environment.XCODE
    return Environment.SANDBOX


def _candidate_environments():
    from appstoreserverlibrary.models.Environment import Environment

    primary = _environment_enum(_settings().apple_iap_environment)
    ordered = [primary]
    for env in (Environment.SANDBOX, Environment.PRODUCTION):
        if env not in ordered:
            ordered.append(env)
    return ordered


def _verifier_for(environment):
    from appstoreserverlibrary.models.Environment import Environment
    from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier

    app_apple_id = _app_apple_id()
    if environment == Environment.PRODUCTION and app_apple_id is None:
        return None
    return SignedDataVerifier(
        load_root_certificates(),
        bool(_settings().apple_iap_online_checks),
        environment,
        _bundle_id(),
        app_apple_id,
    )


def _xcode_verifier():
    from appstoreserverlibrary.models.Environment import Environment
    from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier

    return SignedDataVerifier(
        load_root_certificates(),
        False,
        Environment.XCODE,
        _bundle_id(),
        _app_apple_id(),
    )


def _unverified_environment(signed: str) -> str | None:
    import jwt

    try:
        payload = jwt.decode(signed, options={"verify_signature": False})
    except Exception:
        return None
    if not isinstance(payload, dict):
        return None
    data = payload.get("data") if isinstance(payload.get("data"), dict) else {}
    raw = payload.get("environment") or data.get("environment")
    return str(raw) if raw else None


def _verify_with_candidates(verify):
    from appstoreserverlibrary.models.Environment import Environment
    from appstoreserverlibrary.signed_data_verifier import VerificationException, VerificationStatus

    mismatched = False
    missing_production_app_id = False
    last_error: Exception | None = None
    for environment in _candidate_environments():
        verifier = _verifier_for(environment)
        if verifier is None:
            if environment == Environment.PRODUCTION:
                missing_production_app_id = True
            continue
        try:
            return verify(verifier)
        except VerificationException as exc:
            last_error = exc
            if exc.status == VerificationStatus.INVALID_ENVIRONMENT:
                mismatched = True
                continue
            raise AppleVerificationError(f"Apple signature verification failed ({exc.status.name}).") from exc
        except AppleVerificationError:
            raise
        except Exception as exc:
            last_error = exc
            raise AppleVerificationError("Apple signature verification failed.") from exc

    if mismatched and missing_production_app_id:
        raise AppleIapConfigError(
            "APPLE_APP_APPLE_ID is required to verify Production App Store transactions."
        )
    raise AppleVerificationError("Apple signature verification failed.") from last_error


def _maybe_xcode(signed: str, verify):
    claimed = (_unverified_environment(signed) or "").strip().lower()
    if claimed != "xcode" or not bool(_settings().apple_iap_allow_xcode):
        return None
    try:
        return verify(_xcode_verifier())
    except Exception as exc:
        raise AppleVerificationError("Xcode StoreKit transaction could not be decoded.") from exc


def transaction_to_dict(transaction: Any) -> dict[str, Any]:
    """Normalize a library payload or a test dict into the fields the sync layer uses."""
    if isinstance(transaction, dict):
        return transaction
    return {
        "original_transaction_id": transaction.originalTransactionId,
        "transaction_id": transaction.transactionId,
        "product_id": transaction.productId,
        "bundle_id": transaction.bundleId,
        "app_account_token": None if transaction.appAccountToken is None else str(transaction.appAccountToken),
        "expires_date_ms": transaction.expiresDate,
        "purchase_date_ms": transaction.purchaseDate,
        "revocation_date_ms": transaction.revocationDate,
        "signed_date_ms": transaction.signedDate,
        "environment": _enum_value(transaction.environment),
        "type": _enum_value(transaction.type) or _AUTO_RENEWABLE,
        "offer_type": _enum_value(getattr(transaction, "offerType", None)),
        "subscription_group_identifier": transaction.subscriptionGroupIdentifier,
    }


def notification_to_dict(notification: Any) -> dict[str, Any]:
    if isinstance(notification, dict):
        return notification
    data = notification.data
    return {
        "notification_type": _enum_value(notification.notificationType),
        "subtype": _enum_value(notification.subtype),
        "notification_uuid": notification.notificationUUID,
        "signed_date_ms": notification.signedDate,
        "bundle_id": None if data is None else data.bundleId,
        "environment": None if data is None else _enum_value(data.environment),
        "apple_status": None if data is None else _enum_value(data.status),
        "signed_transaction_info": None if data is None else data.signedTransactionInfo,
        "signed_renewal_info": None if data is None else data.signedRenewalInfo,
    }


def renewal_to_dict(renewal: Any) -> dict[str, Any]:
    if isinstance(renewal, dict):
        return renewal
    return {
        "auto_renew_status": _enum_value(renewal.autoRenewStatus),
        "auto_renew_product_id": renewal.autoRenewProductId,
        "product_id": renewal.productId,
        "grace_period_expires_date_ms": renewal.gracePeriodExpiresDate,
        "original_transaction_id": renewal.originalTransactionId,
    }


def verify_signed_transaction(signed_transaction: str) -> dict[str, Any]:
    signed = (signed_transaction or "").strip()
    if not signed:
        raise AppleVerificationError("signed_transaction is required.")

    def _run(verifier):
        return transaction_to_dict(verifier.verify_and_decode_signed_transaction(signed))

    xcode = _maybe_xcode(signed, _run)
    if xcode is not None:
        return xcode
    return _verify_with_candidates(_run)


def verify_signed_notification(signed_payload: str) -> dict[str, Any]:
    signed = (signed_payload or "").strip()
    if not signed:
        raise AppleVerificationError("signedPayload is required.")

    def _run(verifier):
        return notification_to_dict(verifier.verify_and_decode_notification(signed))

    xcode = _maybe_xcode(signed, _run)
    if xcode is not None:
        return xcode
    return _verify_with_candidates(_run)


def verify_signed_renewal(signed_renewal_info: str) -> dict[str, Any]:
    signed = (signed_renewal_info or "").strip()
    if not signed:
        raise AppleVerificationError("signedRenewalInfo is required.")

    def _run(verifier):
        return renewal_to_dict(verifier.verify_and_decode_renewal_info(signed))

    xcode = _maybe_xcode(signed, _run)
    if xcode is not None:
        return xcode
    return _verify_with_candidates(_run)


def _load_private_key() -> bytes:
    settings = _settings()
    path = (settings.apple_private_key_path or "").strip()
    if path:
        key_path = Path(path)
        if not key_path.is_file():
            raise AppleIapConfigError("APPLE_PRIVATE_KEY_PATH does not point at a readable file.")
        return key_path.read_bytes()
    raw = (settings.apple_private_key or "").replace("\\n", "\n").strip()
    if not raw:
        raise AppleIapConfigError("APPLE_PRIVATE_KEY or APPLE_PRIVATE_KEY_PATH is not set.")
    return raw.encode("utf-8")


def fetch_signed_transaction(transaction_id: str) -> str:
    """Call the App Store Server API and return the signed transaction JWS."""
    from appstoreserverlibrary.api_client import AppStoreServerAPIClient

    settings = _settings()
    issuer = (settings.apple_issuer_id or "").strip()
    key_id = (settings.apple_key_id or "").strip()
    if not issuer or not key_id:
        raise AppleIapConfigError("APPLE_ISSUER_ID and APPLE_KEY_ID are required to look up a transaction id.")
    transaction_id = (transaction_id or "").strip()
    if not transaction_id:
        raise AppleVerificationError("transaction_id is required.")

    from appstoreserverlibrary.models.Environment import Environment

    primary = _environment_enum(settings.apple_iap_environment)
    environments = [primary]
    for env in (Environment.SANDBOX, Environment.PRODUCTION):
        if env not in environments:
            environments.append(env)

    last_error: Exception | None = None
    key = _load_private_key()
    bundle = _bundle_id()
    for environment in environments:
        client = AppStoreServerAPIClient(key, key_id, issuer, bundle, environment)
        try:
            response = client.get_transaction_info(transaction_id)
        except Exception as exc:
            last_error = exc
            logger.info("[apple] get_transaction_info failed environment=%s", _enum_value(environment))
            continue
        signed = getattr(response, "signedTransactionInfo", None)
        if signed:
            return str(signed)
    raise AppleVerificationError("App Store did not return that transaction.") from last_error
