"""Tests for Telnyx provision error mapping."""

from telnyx.provision import _parse_error


def test_parse_error_maps_telnyx_10005_to_actionable_message() -> None:
    raw = """
    {"errors":[{"code":"10005","title":"Resource not found",
      "detail":"The requested resource or URL could not be found."}]}
    """
    msg = _parse_error(raw, "configure voice")
    assert "TELNYX_CONNECTION_ID" in msg or "area code" in msg
    assert "could not be found" not in msg.lower() or "Telnyx" in msg
