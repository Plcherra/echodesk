"""Internal operator notifications (email via Resend)."""

from __future__ import annotations

import logging
from typing import Any

import httpx

from config import settings

logger = logging.getLogger(__name__)


def _support_email() -> str:
    return (settings.support_email or "echodesk2@gmail.com").strip()


def _from_address() -> str:
    return (settings.email_from or "EchoDesk <noreply@echodesk.us>").strip()


def notify_phone_number_release_needed(
    *,
    receptionist_id: str,
    receptionist_name: str | None,
    phone_number: str | None,
    telnyx_phone_number_id: str | None,
    owner_user_id: str,
    owner_email: str | None,
    business_id: str | None,
) -> bool:
    """
    Email operators that a business number needs manual Telnyx release.
    Always logs a conspicuous ops alert. Returns True if email was sent.
    """
    to_addr = _support_email()
    name = (receptionist_name or "").strip() or "(unnamed)"
    phone = (phone_number or "").strip() or "(unknown)"
    telnyx_id = (telnyx_phone_number_id or "").strip() or "(none)"
    owner_em = (owner_email or "").strip() or "(unknown)"

    subject = f"[EchoDesk] Release phone number: {phone}"
    body = (
        "A customer deleted a receptionist. Manual number release is required "
        "(do not auto-release yet — ops handles within 24–48 hours).\n\n"
        f"Phone number: {phone}\n"
        f"Telnyx phone number ID: {telnyx_id}\n"
        f"Receptionist: {name} ({receptionist_id})\n"
        f"Owner user ID: {owner_user_id}\n"
        f"Owner email: {owner_em}\n"
        f"Business ID: {business_id or '(none)'}\n"
    )

    logger.warning(
        "[ops] MANUAL_PHONE_RELEASE_NEEDED phone=%s telnyx_id=%s "
        "receptionist_id=%s owner_user_id=%s owner_email=%s business_id=%s",
        phone,
        telnyx_id,
        receptionist_id,
        owner_user_id,
        owner_em,
        business_id or "",
    )

    api_key = (settings.resend_api_key or "").strip()
    if not api_key:
        logger.warning(
            "[ops] RESEND_API_KEY not set; release notify email not sent "
            "(check logs above). to=%s",
            to_addr,
        )
        return False

    payload: dict[str, Any] = {
        "from": _from_address(),
        "to": [to_addr],
        "subject": subject,
        "text": body,
    }
    try:
        with httpx.Client(timeout=15.0) as client:
            r = client.post(
                "https://api.resend.com/emails",
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                },
                json=payload,
            )
        if r.status_code >= 200 and r.status_code < 300:
            logger.info(
                "[ops] Release notify email sent to=%s phone=%s",
                to_addr,
                phone,
            )
            return True
        logger.warning(
            "[ops] Release notify email failed status=%s body=%s",
            r.status_code,
            (r.text or "")[:300],
        )
        return False
    except Exception as ex:
        logger.warning("[ops] Release notify email error: %s", ex)
        return False
