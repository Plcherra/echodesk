"""Held-number cron detaches from the customer and never Telnyx-deletes."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from cron.release_held_numbers import release_expired_held_numbers


class _FakeQuery:
    def __init__(self, rows):
        self._rows = rows

    def select(self, *_args, **_kwargs):
        return self

    def execute(self):
        return type("Res", (), {"data": self._rows})()


class _FakeSupabase:
    def table(self, name: str):
        if name == "businesses":
            return _FakeQuery([{"owner_user_id": "user-1"}])
        return _FakeQuery([])


def test_release_expired_held_detaches_and_does_not_call_telnyx(monkeypatch):
    now = datetime(2026, 9, 4, 20, 0, tzinfo=timezone.utc)
    inventory = [
        {
            "e164": "+16175550100",
            "telnyx_id": "num_1",
            "live": False,
            "held_at": now - timedelta(hours=49),
            "owner_user_id": "user-1",
        }
    ]
    detached: list[tuple[str | None, str | None]] = []
    emailed: list[str] = []

    monkeypatch.setattr(
        "cron.release_held_numbers.collect_account_phone_inventory",
        lambda _sb, _uid: inventory,
    )
    monkeypatch.setattr(
        "cron.release_held_numbers.expired_held_numbers",
        lambda items, hold_hours=48: [i for i in items if not i.get("live")],
    )

    def fake_detach(_sb, **kwargs):
        detached.append((kwargs.get("phone_number"), kwargs.get("telnyx_phone_number_id")))
        return {"matched": True, "owner_email": "owner@example.com"}

    def fake_email(*, owner_email, phone_number):
        emailed.append(f"{owner_email}:{phone_number}")
        return True

    monkeypatch.setattr("cron.release_held_numbers.mark_held_number_released", fake_detach)
    monkeypatch.setattr("cron.release_held_numbers.notify_customer_number_released", fake_email)

    import cron.release_held_numbers as mod

    out = release_expired_held_numbers(_FakeSupabase(), hold_hours=48)
    assert out["released"] == ["+16175550100"]
    assert detached == [("+16175550100", "num_1")]
    assert emailed == ["owner@example.com:+16175550100"]
    assert not hasattr(mod, "telnyx_provision")
