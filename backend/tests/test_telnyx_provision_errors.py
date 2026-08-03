"""Tests for Telnyx provision error mapping and orphan reuse helpers."""

from telnyx.provision import (
    _parse_error,
    find_orphaned_number,
    normalize_e164,
    us_area_code_from_e164,
)


def test_parse_error_maps_telnyx_10005_to_actionable_message() -> None:
    raw = """
    {"errors":[{"code":"10005","title":"Resource not found",
      "detail":"The requested resource or URL could not be found."}]}
    """
    msg = _parse_error(raw, "configure voice")
    assert "TELNYX_CONNECTION_ID" in msg or "area code" in msg
    assert "could not be found" not in msg.lower() or "Telnyx" in msg


def test_normalize_and_area_code() -> None:
    assert normalize_e164("210-584-7719") == "+12105847719"
    assert us_area_code_from_e164("+12105847719") == "210"


def test_find_orphaned_prefers_matching_area(monkeypatch) -> None:
    monkeypatch.setattr(
        "telnyx.provision.list_owned_phone_numbers",
        lambda: [
            {"id": "a", "phone_number": "+12175551212", "status": "active"},
            {"id": "b", "phone_number": "+12105847719", "status": "active"},
        ],
    )
    found = find_orphaned_number(
        used_ids=set(),
        used_e164=set(),
        preferred_area_code="210",
    )
    assert found == ("b", "+12105847719")


def test_find_orphaned_skips_used(monkeypatch) -> None:
    monkeypatch.setattr(
        "telnyx.provision.list_owned_phone_numbers",
        lambda: [
            {"id": "b", "phone_number": "+12105847719", "status": "active"},
        ],
    )
    found = find_orphaned_number(
        used_ids=set(),
        used_e164={"+12105847719"},
        preferred_area_code="210",
    )
    assert found is None
