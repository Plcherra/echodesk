"""Subscription access gating tests."""

from __future__ import annotations

from billing.subscriptions import get_active_subscription, get_billing_access_state
from billing.stripe_sync import stripe_subscription_status_to_db_status


class _Result:
    def __init__(self, data):
        self.data = data


class _TableQuery:
    def __init__(self, rows):
        self._rows = list(rows)

    def select(self, *_args, **_kwargs):
        return self

    def eq(self, column, value):
        self._rows = [r for r in self._rows if r.get(column) == value]
        return self

    def in_(self, column, values):
        accepted = set(values)
        self._rows = [r for r in self._rows if r.get(column) in accepted]
        return self

    def execute(self):
        return _Result(self._rows)


class _Supabase:
    def __init__(self, rows):
        self._rows = rows

    def table(self, name):
        assert name == "subscriptions"
        return _TableQuery(self._rows)


def test_get_active_subscription_excludes_past_due() -> None:
    supabase = _Supabase(
        [
            {"id": "sub_past_due", "user_id": "u1", "status": "past_due"},
            {"id": "sub_canceled", "user_id": "u1", "status": "canceled"},
        ]
    )

    assert get_active_subscription(supabase, "u1") is None


def test_billing_access_state_blocks_latest_past_due_subscription() -> None:
    supabase = _Supabase(
        [
            {
                "id": "sub_active_old",
                "user_id": "u1",
                "status": "active",
                "updated_at": "2026-05-01T00:00:00Z",
            },
            {
                "id": "sub_past_due_new",
                "user_id": "u1",
                "status": "past_due",
                "updated_at": "2026-05-15T00:00:00Z",
            },
        ]
    )

    state = get_billing_access_state(supabase, "u1")

    assert state["has_active_subscription"] is False
    assert state["status"] == "past_due"
    assert state["source"] == "subscriptions"


def test_billing_access_state_falls_back_to_profile_trialing() -> None:
    supabase = _Supabase([])

    state = get_billing_access_state(
        supabase,
        "u1",
        profile={"subscription_status": "trialing"},
    )

    assert state["has_active_subscription"] is True
    assert state["status"] == "trialing"
    assert state["source"] == "users"


def test_stripe_status_mapping_never_defaults_to_active() -> None:
    assert stripe_subscription_status_to_db_status("active") == "active"
    assert stripe_subscription_status_to_db_status("trialing") == "trialing"
    assert stripe_subscription_status_to_db_status("incomplete") == "past_due"
    assert stripe_subscription_status_to_db_status("unpaid") == "past_due"
    assert stripe_subscription_status_to_db_status("unexpected") == "past_due"
