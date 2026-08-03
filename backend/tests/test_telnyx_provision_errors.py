"""Tests for Telnyx provision error mapping and orphan reuse helpers."""

from telnyx.provision import (
    _parse_error,
    acquire_phone_number,
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
    assert normalize_e164("+1 (217) 613-7764") == "+12176137764"
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


def test_find_orphaned_skips_number_used_by_another_account(monkeypatch) -> None:
    monkeypatch.setattr(
        "telnyx.provision.list_owned_phone_numbers",
        lambda: [
            {"id": "used", "phone_number": "+12176137764", "status": "active"},
            {"id": "free", "phone_number": "+12105847719", "status": "active"},
        ],
    )
    found = find_orphaned_number(
        used_ids={"used"},
        used_e164={"+12176137764"},
        preferred_area_code="217",
    )
    # Must not steal +12176137764 even if area matches preference.
    assert found == ("free", "+12105847719")


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


def test_acquire_fails_closed_without_inventory(monkeypatch) -> None:
    called = {"buy": False}

    def _buy(_area: str):
        called["buy"] = True
        return ("new-id", "+15551212")

    monkeypatch.setattr("telnyx.provision.provision_number", _buy)
    monkeypatch.setattr(
        "telnyx.provision.find_orphaned_number",
        lambda **kwargs: (_ for _ in ()).throw(AssertionError("must not reuse")),
    )
    tid, e164, purchased = acquire_phone_number("212", allow_orphan_reuse=True)
    assert purchased is True
    assert called["buy"] is True
    assert tid == "new-id"
