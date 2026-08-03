"""Telnyx phone number provisioning and configuration."""

from __future__ import annotations

import logging
import re
import time
from typing import Any

import httpx

from config import settings

logger = logging.getLogger(__name__)
TELNYX_API = "https://api.telnyx.com/v2"
FALLBACK_AREA_CODES = ["212", "310", "415", "508", "781", "646", "202", "305", "702"]


def _parse_error(raw: str, context: str) -> str:
    if not raw or not raw.strip():
        return f"Telnyx {context} failed. Please try again."
    if raw.strip().startswith("<") or "<!doctype" in raw.lower():
        return "Telnyx failed. Check your API key and Connection ID, then try again."
    try:
        import json

        data = json.loads(raw)
        errors = data.get("errors", [])
        if errors and isinstance(errors[0], dict):
            code = str(errors[0].get("code") or "")
            detail = errors[0].get("detail") or errors[0].get("title")
            if code == "10005" or (
                isinstance(detail, str)
                and "could not be found" in detail.lower()
            ):
                return (
                    "Could not finish setting up the business number with Telnyx "
                    "(resource not found). Check TELNYX_CONNECTION_ID, then try again "
                    "or pick a different area code."
                )
            if detail:
                return str(detail)
    except Exception:
        pass
    cleaned = re.sub(r"<[^>]*>", "", raw).strip()
    return cleaned[:200] + "..." if len(cleaned) > 200 else cleaned or f"Telnyx {context} failed."


def _get_api_key() -> str:
    key = (settings.telnyx_api_key or "").strip()
    if not key:
        raise ValueError("TELNYX_API_KEY must be set")
    return key


def provision_number(area_code: str) -> tuple[str, str]:
    """
    Search for available local numbers and order one.
    Returns (phone_number_id, e164_phone_number).

    The ID is the Telnyx *phone_numbers* resource id (safe for PATCH/DELETE),
    not the temporary number-order line-item id.
    """
    api_key = _get_api_key()
    to_try = [area_code] + [ac for ac in FALLBACK_AREA_CODES if ac != area_code]
    last_error: Exception | None = None

    for ac in to_try:
        try:
            result = _try_provision_in_area(ac, api_key)
            if result:
                return result
        except Exception as e:
            last_error = e
            logger.warning("Provision failed for area %s: %s", ac, e)

    if last_error and "could not be found" not in str(last_error).lower():
        # Prefer the last concrete Telnyx error when search/order failed for every area.
        if "No available" not in str(last_error):
            raise ValueError(str(last_error)) from last_error

    raise ValueError(
        f"No available phone numbers in area code {area_code} or common fallbacks. "
        "Try a different area code, or submit a number transfer from the phone step."
    )


def _auth_headers(api_key: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}


def _resolve_phone_number_id(
    client: httpx.Client,
    api_key: str,
    e164: str,
    *,
    attempts: int = 8,
    delay_s: float = 1.0,
) -> str | None:
    """Look up the owned phone_numbers resource id after a number order completes."""
    for attempt in range(attempts):
        r = client.get(
            f"{TELNYX_API}/phone_numbers",
            params={
                "filter[phone_number]": e164,
                "page[size]": 1,
            },
            headers={"Authorization": f"Bearer {api_key}"},
        )
        if r.is_success:
            rows = (r.json() or {}).get("data") or []
            if rows:
                pid = rows[0].get("id")
                if pid:
                    return str(pid)
        else:
            logger.warning(
                "phone_numbers lookup failed attempt=%s status=%s body=%s",
                attempt + 1,
                r.status_code,
                (r.text or "")[:300],
            )
        if attempt + 1 < attempts:
            time.sleep(delay_s)
    return None


def _wait_for_order_success(
    client: httpx.Client,
    api_key: str,
    order_id: str,
    *,
    attempts: int = 10,
    delay_s: float = 1.0,
) -> dict[str, Any] | None:
    """Poll number order until success/failure; return final data payload."""
    for attempt in range(attempts):
        r = client.get(
            f"{TELNYX_API}/number_orders/{order_id}",
            headers={"Authorization": f"Bearer {api_key}"},
        )
        if not r.is_success:
            logger.warning(
                "number_orders poll failed attempt=%s status=%s",
                attempt + 1,
                r.status_code,
            )
        else:
            data = (r.json() or {}).get("data") or {}
            status = str(data.get("status") or "").lower()
            if status == "success":
                return data
            if status == "failure":
                raise ValueError(
                    "Telnyx could not complete the number order. Try another area code."
                )
        if attempt + 1 < attempts:
            time.sleep(delay_s)
    return None


def _try_provision_in_area(area_code: str, api_key: str) -> tuple[str, str] | None:
    with httpx.Client(timeout=45.0) as client:
        r = client.get(
            f"{TELNYX_API}/available_phone_numbers",
            params={
                "filter[country_code]": "US",
                "filter[phone_number_type]": "local",
                "filter[features][]": "voice",
                "filter[national_destination_code]": area_code,
                "page[size]": 1,
            },
            headers={"Authorization": f"Bearer {api_key}"},
        )
        if not r.is_success:
            raise ValueError(_parse_error(r.text, "search"))

        data = r.json()
        numbers = data.get("data") or []
        if not numbers:
            return None
        phone_number = numbers[0].get("phone_number")
        if not phone_number:
            return None

        order_body: dict[str, Any] = {"phone_numbers": [{"phone_number": phone_number}]}
        conn_id = (settings.telnyx_connection_id or "").strip()
        # Prefer ordering with connection so inbound voice is wired immediately.
        # If Telnyx rejects the connection id (often 10005), retry without it and
        # attach connection during configure_voice_url instead.
        order_attempts: list[dict[str, Any]] = [dict(order_body)]
        if conn_id:
            with_conn = dict(order_body)
            with_conn["connection_id"] = conn_id
            order_attempts = [with_conn, order_body]

        r2 = None
        for attempt_body in order_attempts:
            r2 = client.post(
                f"{TELNYX_API}/number_orders",
                json=attempt_body,
                headers=_auth_headers(api_key),
            )
            if r2.is_success:
                break
            logger.warning(
                "number_orders failed status=%s body=%s",
                r2.status_code,
                (r2.text or "")[:400],
            )
        if r2 is None or not r2.is_success:
            raise ValueError(_parse_error((r2.text if r2 is not None else ""), "order"))

        order_payload = (r2.json() or {}).get("data") or {}
        order_id = order_payload.get("id")
        ordered = order_payload.get("phone_numbers") or []
        if not ordered:
            return None
        first = ordered[0]
        e164 = first.get("phone_number") or phone_number
        if not e164:
            return None

        if order_id:
            try:
                _wait_for_order_success(client, api_key, str(order_id))
            except ValueError:
                raise
            except Exception as e:
                logger.warning("number order poll error order=%s: %s", order_id, e)

        phone_id = _resolve_phone_number_id(client, api_key, str(e164))
        if not phone_id:
            # Last resort: some accounts expose a usable id on the order line item
            # only after success — still prefer lookup above.
            fallback_id = first.get("id")
            if fallback_id:
                logger.warning(
                    "Using number-order line id for %s; configure may fail if id is not a phone_numbers resource",
                    e164,
                )
                phone_id = str(fallback_id)
            else:
                return None

        return phone_id, str(e164)


def configure_voice_url(phone_number_id: str, webhook_url: str) -> None:
    """Configure the voice URL for a Telnyx number."""
    api_key = _get_api_key()
    conn_id = (settings.telnyx_connection_id or "").strip()
    body: dict[str, Any] = {"webhook_url": webhook_url}
    if conn_id:
        body["connection_id"] = conn_id

    with httpx.Client(timeout=20.0) as client:
        # Retry briefly — newly ordered numbers can lag before PATCH is accepted.
        last_error = "Telnyx configure voice failed."
        for attempt in range(5):
            r = client.patch(
                f"{TELNYX_API}/phone_numbers/{phone_number_id}",
                json=body,
                headers=_auth_headers(api_key),
            )
            if r.is_success:
                return
            last_error = _parse_error(r.text, "configure voice")
            if r.status_code not in (404, 409, 422, 429):
                break
            time.sleep(1.0 + attempt * 0.5)
        raise ValueError(last_error)


def release_number(phone_number_id: str) -> None:
    """Release (delete) a Telnyx phone number."""
    api_key = _get_api_key()
    with httpx.Client(timeout=15.0) as client:
        r = client.delete(
            f"{TELNYX_API}/phone_numbers/{phone_number_id}",
            headers={"Authorization": f"Bearer {api_key}"},
        )
        if not r.is_success and r.status_code != 404:
            raise ValueError(_parse_error(r.text, "release"))
