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


def _send_resend_email(*, to: str, subject: str, text: str) -> bool:
    api_key = (settings.resend_api_key or "").strip()
    if not api_key:
        logger.warning(
            "[ops] RESEND_API_KEY not set; email not sent to=%s subject=%s",
            to,
            subject[:80],
        )
        return False
    payload: dict[str, Any] = {
        "from": _from_address(),
        "to": [to],
        "subject": subject,
        "text": text,
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
            logger.info("[ops] Email sent to=%s subject=%s", to, subject[:80])
            return True
        logger.warning(
            "[ops] Email failed status=%s body=%s",
            r.status_code,
            (r.text or "")[:300],
        )
        return False
    except Exception as ex:
        logger.warning("[ops] Email error: %s", ex)
        return False


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
        "A customer deleted a receptionist. The number stays on their account.\n"
        "If they recreate and Keep it, nothing to do.\n"
        "If unused for 48 hours, cron detaches it from the customer "
        "(/api/cron/release-held-numbers) and emails them. The DID stays on our Telnyx account.\n\n"
        f"Phone number: {phone}\n"
        f"Telnyx phone number ID: {telnyx_id}\n"
        f"Receptionist: {name} ({receptionist_id})\n"
        f"Owner user ID: {owner_user_id}\n"
        f"Owner email: {owner_em}\n"
        f"Business ID: {business_id or '(none)'}\n\n"
        "No action needed unless cron is down. Manual Telnyx delete (only if you must drop the DID):\n"
        "POST /api/internal/phone-numbers/release\n"
        "Authorization: Bearer $INTERNAL_API_KEY\n"
        '{"phone_number": "' + phone + '", "telnyx_phone_number_id": "' + telnyx_id + '"}\n'
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

    return _send_resend_email(to=to_addr, subject=subject, text=body)


def notify_number_transfer_requested(
    *,
    request_id: str,
    phone_number: str,
    number_kind: str,
    carrier_or_provider: str,
    customer_note: str | None,
    owner_user_id: str,
    owner_email: str | None,
    business_id: str | None,
) -> bool:
    """Email ops that a customer submitted a number transfer evaluation request."""
    to_addr = _support_email()
    phone = (phone_number or "").strip() or "(unknown)"
    kind = (number_kind or "").strip() or "(unknown)"
    carrier = (carrier_or_provider or "").strip() or "(unknown)"
    note = (customer_note or "").strip() or "(none)"
    owner_em = (owner_email or "").strip() or "(unknown)"

    kind_label = {
        "mobile_carrier": "Mobile / carrier phone",
        "voip_internet": "Internet / VoIP",
    }.get(kind, kind)

    subject = f"[EchoDesk] Number transfer review: {phone}"
    body = (
        "A customer requested evaluation to transfer a number into EchoDesk.\n"
        "Review whether porting is possible, then update status via "
        "PATCH /api/internal/number-transfers/{id}.\n\n"
        f"Request ID: {request_id}\n"
        f"Phone number: {phone}\n"
        f"Number type: {kind_label} ({kind})\n"
        f"Carrier / provider: {carrier}\n"
        f"Customer note: {note}\n"
        f"Owner user ID: {owner_user_id}\n"
        f"Owner email: {owner_em}\n"
        f"Business ID: {business_id or '(none yet)'}\n\n"
        "Approve (emails the customer):\n"
        f"PATCH /api/internal/number-transfers/{request_id}\n"
        "Authorization: Bearer $INTERNAL_API_KEY\n"
        '{"status":"completed"}\n\n'
        "Reject (emails the customer; optional reason):\n"
        f"PATCH /api/internal/number-transfers/{request_id}\n"
        "Authorization: Bearer $INTERNAL_API_KEY\n"
        '{"status":"rejected","ops_note":"Carrier cannot port this number"}\n'
    )

    logger.warning(
        "[ops] NUMBER_TRANSFER_REQUESTED request_id=%s phone=%s kind=%s "
        "carrier=%s owner_user_id=%s owner_email=%s",
        request_id,
        phone,
        kind,
        carrier,
        owner_user_id,
        owner_em,
    )

    return _send_resend_email(to=to_addr, subject=subject, text=body)


def notify_customer_number_transfer_status(
    *,
    owner_email: str,
    phone_number: str,
    status: str,
    ops_note: str | None = None,
) -> bool:
    """Email the customer when a transfer request is completed or rejected."""
    email = (owner_email or "").strip()
    if not email or "@" not in email:
        logger.warning("[ops] No customer email for transfer status notify")
        return False

    phone = (phone_number or "").strip() or "your number"
    note = (ops_note or "").strip()

    if status == "completed":
        subject = "EchoDesk: your number transfer is complete"
        text = (
            f"Good news — we've finished moving {phone} to EchoDesk.\n\n"
            "Your EchoDesk business line should now use this number. "
            "If anything looks off in the app, reply to this email or contact support.\n"
        )
    elif status == "rejected":
        subject = "EchoDesk: update on your number transfer request"
        text = (
            f"We reviewed your request to move {phone} to EchoDesk and "
            "we're not able to complete that transfer right now.\n\n"
        )
        if note:
            text += f"Details: {note}\n\n"
        text += (
            "You can keep using your temporary EchoDesk number, or email us "
            f"at {_support_email()} if you have questions.\n"
        )
    else:
        return False

    return _send_resend_email(to=email, subject=subject, text=text)


def notify_customer_number_released(
    *,
    owner_email: str,
    phone_number: str,
) -> bool:
    """Email the customer after a held DID is detached from their account."""
    email = (owner_email or "").strip()
    if not email or "@" not in email:
        logger.warning("[ops] No customer email for number-released notify")
        return False

    phone = (phone_number or "").strip() or "your number"
    subject = "EchoDesk: your business number has been released"
    text = (
        f"We've released {phone} from your EchoDesk account.\n\n"
        "That line is no longer held. If you create a receptionist again, "
        "we'll set up a US business number for you.\n\n"
        f"Questions? Email {_support_email()}.\n"
    )
    return _send_resend_email(to=email, subject=subject, text=text)
