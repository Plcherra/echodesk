from __future__ import annotations

from types import SimpleNamespace

import pytest

from api.mobile import account


class _AuthAdmin:
    def __init__(self) -> None:
        self.deleted: list[str] = []

    def delete_user(self, user_id: str) -> None:
        self.deleted.append(user_id)


class _FakeQuery:
    def __init__(self, store: dict, table: str):
        self._store = store
        self._table = table

    def select(self, *_args, **_kwargs):
        return self

    def update(self, payload):
        self._store.setdefault("updates", []).append((self._table, payload))
        return self

    def delete(self):
        self._store.setdefault("deletes", []).append(self._table)
        return self

    def eq(self, *_args, **_kwargs):
        return self

    def limit(self, *_args, **_kwargs):
        return self

    def execute(self):
        if self._table == "users" and "deletes" not in str(self._store.get("deletes")):
            return SimpleNamespace(
                data=[{"id": "user-1", "email": "a@b.co", "stripe_customer_id": "cus_1"}]
            )
        return SimpleNamespace(data=[{"id": "user-1", "email": "a@b.co", "stripe_customer_id": "cus_1"}])


class _FakeSupabase:
    def __init__(self) -> None:
        self.store: dict = {"updates": [], "deletes": []}
        self.auth = SimpleNamespace(admin=_AuthAdmin())

    def table(self, name: str) -> _FakeQuery:
        return _FakeQuery(self.store, name)


def test_delete_account_releases_numbers_cancels_billing_and_removes_user(monkeypatch):
    sb = _FakeSupabase()
    released_ids: list[str] = []

    monkeypatch.setattr(
        account,
        "collect_account_phone_inventory",
        lambda _sb, _uid: [{"e164": "+16175550100", "telnyx_id": "num_1", "live": True}],
    )

    def fake_release(tid: str) -> None:
        released_ids.append(tid)

    monkeypatch.setattr(account.telnyx_provision, "release_number", fake_release)
    monkeypatch.setattr(account, "mark_held_number_released", lambda **_kwargs: {"matched": True})

    canceled: list[str] = []

    class _Sub:
        id = "sub_1"
        status = "active"

    class _StripeSub:
        @staticmethod
        def list(**_kwargs):
            return SimpleNamespace(data=[_Sub()])

        @staticmethod
        def delete(sub_id: str):
            canceled.append(sub_id)

    class _StripeCust:
        @staticmethod
        def delete(cid: str):
            canceled.append(cid)

    monkeypatch.setattr(account.settings, "stripe_secret_key", "sk_test")
    monkeypatch.setattr(account.stripe, "Subscription", _StripeSub)
    monkeypatch.setattr(account.stripe, "Customer", _StripeCust)

    out = account.delete_account_for_user(sb, "user-1")
    assert out["deleted"] is True
    assert out["released_numbers"] == ["+16175550100"]
    assert released_ids == ["num_1"]
    assert "sub_1" in canceled
    assert "cus_1" in canceled
    assert "users" in sb.store["deletes"]
    assert sb.auth.admin.deleted == ["user-1"]


@pytest.mark.asyncio
async def test_delete_account_route_requires_auth(monkeypatch):
    monkeypatch.setattr(account, "get_user_from_request", lambda _req: (None, None))
    res = await account.delete_account(SimpleNamespace())
    assert res.status_code == 401
