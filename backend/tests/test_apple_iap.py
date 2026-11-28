"""Apple IAP entitlement, sync, quota, and notification tests.

Apple's network is not called. Signed-transaction tests use the real
app-store-server-library only to prove an untrusted JWS is rejected.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace

import jwt
import pytest

from api import apple_routes
from billing.apple_entitlement import decide_apple_entitlement
from billing.apple_plans import apple_product_catalog
from billing.apple_sync import apply_apple_subscription
from billing.apple_verifier import AppleVerificationError, transaction_to_dict, verify_signed_transaction
from billing.launch_trial import maybe_activate_launch_trial
from billing.subscriptions import get_billing_access_state, should_preserve_user_access
from cron.usage_billing import invoice_overage_for_fixed_plans
from quota import check_inbound_quota, check_outbound_quota

# Fixed clock far enough ahead that route tests, which use the real clock,
# still see an unexpired subscription.
NOW_MS = 2_100_000_000_000
FUTURE_MS = NOW_MS + 30 * 24 * 60 * 60 * 1000
PAST_MS = NOW_MS - 60_000
STARTER = "com.echodesk.sub.starter.monthly"


@pytest.fixture(autouse=True)
def _default_apple_product_ids(monkeypatch):
    from config import settings

    monkeypatch.setattr(settings, "apple_iap_product_starter", STARTER, raising=False)
    monkeypatch.setattr(settings, "apple_iap_product_growth", "com.echodesk.sub.growth.monthly", raising=False)
    monkeypatch.setattr(settings, "apple_iap_product_business", "com.echodesk.sub.business.monthly", raising=False)
    monkeypatch.setattr(settings, "apple_bundle_id", "com.echodesk.echodeskMobile", raising=False)
    monkeypatch.setattr(settings, "apple_iap_environment", "sandbox", raising=False)
    monkeypatch.setattr(settings, "apple_iap_allow_xcode", False, raising=False)
    monkeypatch.setattr(settings, "apple_app_apple_id", "", raising=False)


class _Result:
    def __init__(self, data):
        self.data = data


class _Not:
    def __init__(self, query):
        self.query = query

    def is_(self, column, value):
        self.query.filters.append(("not_is", column, value))
        return self.query


class _Query:
    def __init__(self, db, table):
        self.db = db
        self.table = table
        self.filters = []
        self.limit_n = None
        self.op = "select"
        self.payload = None
        self.on_conflict = None

    def select(self, *_args, **_kwargs):
        self.op = "select"
        return self

    def eq(self, column, value):
        self.filters.append(("eq", column, value))
        return self

    def in_(self, column, values):
        self.filters.append(("in", column, set(values)))
        return self

    def limit(self, count):
        self.limit_n = count
        return self

    @property
    def not_(self):
        return _Not(self)

    def insert(self, row):
        self.op = "insert"
        self.payload = row
        return self

    def update(self, row):
        self.op = "update"
        self.payload = row
        return self

    def upsert(self, row, on_conflict=None):
        self.op = "upsert"
        self.payload = row
        self.on_conflict = on_conflict
        return self

    def delete(self):
        self.op = "delete"
        return self

    def _match(self, row):
        for kind, column, value in self.filters:
            if kind == "eq" and row.get(column) != value:
                return False
            if kind == "in" and row.get(column) not in value:
                return False
            if kind == "not_is" and value == "null" and row.get(column) is None:
                return False
        return True

    def execute(self):
        rows = self.db.tables.setdefault(self.table, [])
        if self.op == "select":
            matched = [dict(row) for row in rows if self._match(row)]
            if self.limit_n is not None:
                matched = matched[: self.limit_n]
            return _Result(matched)
        if self.op == "insert":
            row = dict(self.payload)
            row.setdefault("id", f"{self.table}-{len(rows) + 1}")
            rows.append(row)
            return _Result([dict(row)])
        if self.op == "update":
            updated = []
            for row in rows:
                if self._match(row):
                    row.update(self.payload)
                    updated.append(dict(row))
            return _Result(updated)
        if self.op == "upsert":
            keys = [key.strip() for key in (self.on_conflict or "id").split(",")]
            for row in rows:
                if all(row.get(key) == self.payload.get(key) for key in keys):
                    row.update(self.payload)
                    return _Result([dict(row)])
            row = dict(self.payload)
            row.setdefault("id", f"{self.table}-{len(rows) + 1}")
            rows.append(row)
            return _Result([dict(row)])
        if self.op == "delete":
            kept = []
            deleted = []
            for row in rows:
                if self._match(row):
                    deleted.append(dict(row))
                else:
                    kept.append(row)
            self.db.tables[self.table] = kept
            return _Result(deleted)
        raise AssertionError(self.op)


class FakeDB:
    def __init__(self):
        self.tables = {
            "users": [{"id": "user-1", "subscription_status": "inactive", "billing_plan_metadata": {}}],
            "plans": [
                {"id": "plan-starter", "code": "starter", "is_active": True},
                {"id": "plan-growth", "code": "growth", "is_active": False},
                {"id": "plan-business", "code": "business", "is_active": True},
            ],
            "subscriptions": [],
            "user_plans": [],
            "billing_invoices": [],
        }

    def table(self, name):
        return _Query(self, name)


def _tx(**overrides):
    payload = {
        "original_transaction_id": "orig-1",
        "transaction_id": "tx-1",
        "product_id": STARTER,
        "bundle_id": "com.echodesk.echodeskMobile",
        "app_account_token": "user-1",
        "expires_date_ms": FUTURE_MS,
        "purchase_date_ms": NOW_MS - 1000,
        "revocation_date_ms": None,
        "signed_date_ms": NOW_MS,
        "environment": "Sandbox",
        "type": "Auto-Renewable Subscription",
    }
    payload.update(overrides)
    return payload


def _user(db: FakeDB) -> dict:
    return db.tables["users"][0]


def _sub(db: FakeDB) -> dict:
    return db.tables["subscriptions"][0]


def test_catalog_is_three_monthly_plans_without_dev_test():
    catalog = apple_product_catalog()
    assert set(catalog) == {
        "com.echodesk.sub.starter.monthly",
        "com.echodesk.sub.growth.monthly",
        "com.echodesk.sub.business.monthly",
    }
    assert catalog[STARTER]["included_minutes"] == 250
    assert catalog["com.echodesk.sub.growth.monthly"]["included_minutes"] == 750
    assert catalog["com.echodesk.sub.business.monthly"]["included_minutes"] == 1500
    assert "dev_test" not in {row["plan_id"] for row in catalog.values()}


def test_active_purchase_sets_apple_minutes_and_account_token():
    db = FakeDB()
    result = apply_apple_subscription(
        db,
        _tx(),
        user_id="user-1",
        require_account_token=True,
        now_ms=NOW_MS,
    )
    assert result["ok"] is True
    assert result["entitled"] is True
    assert result["status"] == "active"
    assert _sub(db)["billing_source"] == "apple"
    assert _sub(db)["apple_original_transaction_id"] == "orig-1"
    assert _sub(db)["apple_product_id"] == STARTER
    assert _sub(db)["apple_app_account_token"] == "user-1"
    assert _sub(db)["expires_at"]
    assert _user(db)["subscription_status"] == "active"
    assert _user(db)["billing_plan_metadata"]["included_minutes"] == 250
    assert _user(db)["billing_plan_metadata"]["billing_source"] == "apple"
    assert _user(db)["billing_plan_metadata"]["overage_allowed"] is False
    plan = db.tables["user_plans"][0]
    assert plan["allocated_inbound_minutes"] + plan["allocated_outbound_minutes"] == 250
    assert plan["overage_rate_cents"] == 0
    assert _sub(db)["plan_id"] == "plan-starter"


def test_growth_links_inactive_catalog_row_with_apple_minutes():
    db = FakeDB()
    result = apply_apple_subscription(
        db,
        _tx(product_id="com.echodesk.sub.growth.monthly"),
        user_id="user-1",
        require_account_token=True,
        now_ms=NOW_MS,
    )
    assert result["entitled"] is True
    assert _user(db)["billing_plan_metadata"]["included_minutes"] == 750
    assert _sub(db)["plan_id"] == "plan-growth"
    assert db.tables["user_plans"][0]["allocated_inbound_minutes"] + db.tables["user_plans"][0]["allocated_outbound_minutes"] == 750


def test_client_verify_rejects_mismatched_or_missing_account_token():
    db = FakeDB()
    missing = apply_apple_subscription(
        db, _tx(app_account_token=None), user_id="user-1", require_account_token=True, now_ms=NOW_MS
    )
    assert missing["status_code"] == 400
    other = apply_apple_subscription(
        db,
        _tx(app_account_token="user-2"),
        user_id="user-1",
        require_account_token=True,
        now_ms=NOW_MS,
    )
    assert other["status_code"] == 403
    assert db.tables["subscriptions"] == []


def test_original_transaction_cannot_move_to_another_account():
    db = FakeDB()
    apply_apple_subscription(db, _tx(), user_id="user-1", require_account_token=True, now_ms=NOW_MS)
    db.tables["users"].append({"id": "user-2", "subscription_status": "inactive"})
    moved = apply_apple_subscription(
        db,
        _tx(app_account_token="user-2", signed_date_ms=NOW_MS + 10),
        user_id="user-2",
        require_account_token=True,
        now_ms=NOW_MS,
    )
    assert moved["status_code"] == 409
    assert _sub(db)["user_id"] == "user-1"


def test_renewal_extends_and_stale_notification_is_ignored():
    db = FakeDB()
    apply_apple_subscription(db, _tx(), user_id="user-1", require_account_token=True, now_ms=NOW_MS)
    renewed_expiry = FUTURE_MS + 30 * 24 * 60 * 60 * 1000
    renewed = apply_apple_subscription(
        db,
        _tx(transaction_id="tx-2", expires_date_ms=renewed_expiry, signed_date_ms=NOW_MS + 100),
        notification_type="DID_RENEW",
        notification_uuid="note-2",
        now_ms=NOW_MS + 100,
    )
    assert renewed["status"] == "active"
    assert _sub(db)["apple_transaction_id"] == "tx-2"
    assert _sub(db)["apple_last_notification_type"] == "DID_RENEW"
    stale = apply_apple_subscription(
        db,
        _tx(transaction_id="tx-old", signed_date_ms=NOW_MS + 50),
        notification_type="EXPIRED",
        now_ms=NOW_MS + 50,
    )
    assert stale["ignored"] is True
    assert stale["reason"] == "stale_notification"
    assert _sub(db)["apple_transaction_id"] == "tx-2"
    assert _user(db)["subscription_status"] == "active"


@pytest.mark.parametrize(
    ("notification", "subtype", "status", "extra"),
    [
        ("REFUND", None, "canceled", {"revocation_date_ms": NOW_MS}),
        ("REVOKE", None, "canceled", {"revocation_date_ms": NOW_MS}),
        ("EXPIRED", "VOLUNTARY", "canceled", {"expires_date_ms": PAST_MS}),
        ("GRACE_PERIOD_EXPIRED", None, "canceled", {}),
        ("DID_FAIL_TO_RENEW", "BILLING_RETRY", "past_due", {}),
    ],
)
def test_loss_of_entitlement_removes_minutes(notification, subtype, status, extra):
    db = FakeDB()
    apply_apple_subscription(db, _tx(), user_id="user-1", require_account_token=True, now_ms=NOW_MS)
    result = apply_apple_subscription(
        db,
        _tx(signed_date_ms=NOW_MS + 5, **extra),
        notification_type=notification,
        subtype=subtype,
        now_ms=NOW_MS + 5,
    )
    assert result["entitled"] is False
    assert result["status"] == status
    assert _user(db)["subscription_status"] == status
    assert db.tables["user_plans"][0]["allocated_inbound_minutes"] == 0
    assert db.tables["user_plans"][0]["allocated_outbound_minutes"] == 0


def test_grace_period_keeps_access():
    db = FakeDB()
    result = apply_apple_subscription(
        db,
        _tx(expires_date_ms=PAST_MS),
        notification_type="DID_FAIL_TO_RENEW",
        subtype="GRACE_PERIOD",
        apple_status=4,
        user_id="user-1",
        require_account_token=True,
        now_ms=NOW_MS,
    )
    assert result["entitled"] is True
    assert result["status"] == "grace_period"
    assert _sub(db)["apple_billing_grace"] is True
    assert _user(db)["subscription_status"] == "grace_period"
    assert db.tables["user_plans"][0]["allocated_inbound_minutes"] > 0


def test_auto_renew_disabled_stays_active_until_period_end():
    decision = decide_apple_entitlement(
        _tx(),
        notification_type="DID_CHANGE_RENEWAL_STATUS",
        subtype="AUTO_RENEW_DISABLED",
        auto_renew_status=0,
        now_ms=NOW_MS,
    )
    assert decision["entitled"] is True
    assert decision["status"] == "active"
    assert decision["cancel_at_period_end"] is True


def test_unknown_product_does_not_grant_minutes():
    db = FakeDB()
    result = apply_apple_subscription(
        db,
        _tx(product_id="com.echodesk.sub.dev_test.monthly"),
        user_id="user-1",
        require_account_token=True,
        now_ms=NOW_MS,
    )
    assert result["entitled"] is False
    assert result["reason"] == "unknown_product"
    assert db.tables["user_plans"][0]["allocated_inbound_minutes"] == 0


def test_apple_expiration_does_not_remove_an_active_stripe_subscription():
    db = FakeDB()
    db.tables["subscriptions"].append(
        {
            "id": "stripe-row",
            "user_id": "user-1",
            "status": "active",
            "billing_source": "stripe",
            "billing_provider_subscription_id": "sub_123",
        }
    )
    _user(db)["subscription_status"] = "active"
    _user(db)["billing_plan"] = "subscription_growth"
    result = apply_apple_subscription(
        db,
        _tx(expires_date_ms=PAST_MS),
        notification_type="EXPIRED",
        now_ms=NOW_MS,
    )
    assert result["preserved_other_billing"] is True
    assert _user(db)["subscription_status"] == "active"
    assert _user(db)["billing_plan"] == "subscription_growth"
    apple = next(row for row in db.tables["subscriptions"] if row.get("billing_source") == "apple")
    assert apple["status"] == "canceled"


def test_notification_without_account_is_ignored():
    db = FakeDB()
    result = apply_apple_subscription(db, _tx(app_account_token=None), notification_type="SUBSCRIBED", now_ms=NOW_MS)
    assert result["ignored"] is True
    assert result["reason"] == "no_account_token"
    assert db.tables["subscriptions"] == []


def test_notification_links_app_account_token_to_existing_user():
    db = FakeDB()
    result = apply_apple_subscription(
        db,
        _tx(),
        notification_type="SUBSCRIBED",
        subtype="INITIAL_BUY",
        now_ms=NOW_MS,
    )
    assert result["entitled"] is True
    assert result["user_id"] == "user-1"


def test_comp_row_is_not_an_apple_subscription_and_still_grants_access():
    db = FakeDB()
    db.tables["subscriptions"].append(
        {
            "id": "comp",
            "user_id": "user-1",
            "status": "active",
            "billing_source": None,
            "comp_source": "manual_comp_no_stripe",
            "updated_at": "2026-01-01T00:00:00Z",
        }
    )
    state = get_billing_access_state(db, "user-1")
    assert state["has_active_subscription"] is True
    assert state["subscription"]["comp_source"] == "manual_comp_no_stripe"
    assert state["subscription"].get("billing_source") is None


def test_newer_canceled_stripe_row_does_not_hide_apple():
    db = FakeDB()
    db.tables["subscriptions"] = [
        {
            "id": "apple",
            "user_id": "user-1",
            "status": "active",
            "billing_source": "apple",
            "updated_at": "2026-05-01T00:00:00Z",
        },
        {
            "id": "stripe",
            "user_id": "user-1",
            "status": "canceled",
            "billing_source": "stripe",
            "updated_at": "2026-06-01T00:00:00Z",
        },
    ]
    state = get_billing_access_state(db, "user-1")
    assert state["has_active_subscription"] is True
    assert state["subscription"]["id"] == "apple"


def test_same_source_still_uses_the_newest_row():
    db = FakeDB()
    db.tables["subscriptions"] = [
        {
            "id": "old",
            "user_id": "user-1",
            "status": "active",
            "billing_source": "stripe",
            "updated_at": "2026-05-01T00:00:00Z",
        },
        {
            "id": "new",
            "user_id": "user-1",
            "status": "past_due",
            "billing_source": "stripe",
            "updated_at": "2026-06-01T00:00:00Z",
        },
    ]
    state = get_billing_access_state(db, "user-1")
    assert state["has_active_subscription"] is False
    assert state["subscription"]["id"] == "new"


def test_preserve_access_skips_the_stripe_subscription_being_deleted():
    db = FakeDB()
    db.tables["subscriptions"] = [
        {
            "user_id": "user-1",
            "status": "active",
            "billing_source": "apple",
            "apple_original_transaction_id": "orig-1",
        },
        {
            "user_id": "user-1",
            "status": "active",
            "billing_source": "stripe",
            "billing_provider_subscription_id": "sub_123",
        },
    ]
    assert should_preserve_user_access(db, "user-1", except_provider_subscription_id="sub_123") is True
    assert should_preserve_user_access(db, "user-1", except_apple_original_transaction_id="orig-1") is True
    assert (
        should_preserve_user_access(
            db,
            "user-1",
            except_provider_subscription_id="sub_123",
            except_apple_original_transaction_id="orig-1",
        )
        is False
    )


def test_apple_quota_caps_combined_minutes_and_stripe_keeps_direction_split():
    db = FakeDB()
    db.tables["user_plans"] = [
        {
            "user_id": "user-1",
            "billing_plan": "subscription_starter",
            "allocated_inbound_minutes": 200,
            "allocated_outbound_minutes": 50,
            "used_inbound_minutes": 200,
            "used_outbound_minutes": 0,
        }
    ]
    db.tables["subscriptions"] = [
        {
            "user_id": "user-1",
            "status": "active",
            "billing_source": "apple",
            "created_at": "2026-01-01T00:00:00Z",
        }
    ]
    allowed = check_inbound_quota(db, "user-1")
    assert allowed["allowed"] is True
    assert allowed["remainingMinutes"] == 50
    db.tables["user_plans"][0]["used_outbound_minutes"] = 50
    blocked = check_outbound_quota(db, "user-1")
    assert blocked["allowed"] is False
    assert "Upgrade" in blocked["reason"]

    db.tables["subscriptions"][0]["billing_source"] = "stripe"
    db.tables["user_plans"][0]["used_outbound_minutes"] = 0
    stripe_inbound = check_inbound_quota(db, "user-1")
    assert stripe_inbound["allowed"] is False
    assert "Upgrade" not in (stripe_inbound["reason"] or "")


def test_overage_invoice_skips_apple_and_still_bills_stripe(monkeypatch):
    created = []

    class _Invoice:
        @staticmethod
        def create(**kwargs):
            created.append(kwargs)
            return SimpleNamespace(id="in_1")

        @staticmethod
        def finalize_invoice(_invoice_id):
            return None

    class _InvoiceItem:
        @staticmethod
        def create(**_kwargs):
            return None

    stripe_mod = SimpleNamespace(Invoice=_Invoice, InvoiceItem=_InvoiceItem)
    db = FakeDB()
    db.tables["user_plans"] = [
        {
            "user_id": "user-1",
            "allocated_inbound_minutes": 100,
            "allocated_outbound_minutes": 0,
            "used_inbound_minutes": 150,
            "used_outbound_minutes": 0,
            "overage_rate_cents": 20,
        }
    ]
    _user(db)["stripe_customer_id"] = "cus_1"
    _user(db)["billing_plan_metadata"] = {"billing_source": "apple", "included_minutes": 250}
    assert invoice_overage_for_fixed_plans(db, stripe_mod)["skipped"] >= 1
    assert created == []

    _user(db)["billing_plan_metadata"] = {"billing_source": "stripe", "included_minutes": 400, "overage_rate_cents": 20}
    db.tables["subscriptions"] = [
        {
            "user_id": "user-1",
            "status": "active",
            "billing_source": "stripe",
            "created_at": "2026-01-01T00:00:00Z",
        }
    ]
    result = invoice_overage_for_fixed_plans(db, stripe_mod)
    assert result["invoiced"] == 1
    assert created and created[0]["customer"] == "cus_1"


def test_ios_client_does_not_receive_the_launch_trial():
    profile = {"id": "user-1", "subscription_status": "inactive"}
    returned = maybe_activate_launch_trial(
        None,
        "user-1",
        profile,
        sync_user_plan=lambda *_args, **_kwargs: None,
        allow_trial=False,
    )
    assert returned is profile
    assert profile["subscription_status"] == "inactive"


def test_verifier_rejects_untrusted_jws():
    forged = jwt.encode(
        {
            "bundleId": "com.echodesk.echodeskMobile",
            "environment": "Sandbox",
            "productId": STARTER,
            "originalTransactionId": "orig-1",
        },
        "not-apple",
        algorithm="HS256",
    )
    with pytest.raises(AppleVerificationError):
        verify_signed_transaction(forged)


def test_transaction_normalizer_reads_library_fields():
    payload = transaction_to_dict(
        SimpleNamespace(
            originalTransactionId="orig-1",
            transactionId="tx-1",
            productId=STARTER,
            bundleId="com.echodesk.echodeskMobile",
            appAccountToken="user-1",
            expiresDate=FUTURE_MS,
            purchaseDate=NOW_MS,
            revocationDate=None,
            signedDate=NOW_MS,
            environment=SimpleNamespace(value="Sandbox"),
            type=SimpleNamespace(value="Auto-Renewable Subscription"),
            subscriptionGroupIdentifier="group",
        )
    )
    decision = decide_apple_entitlement(payload, notification_type="SUBSCRIBED", now_ms=NOW_MS)
    assert decision["entitled"] is True
    assert decision["plan"]["included_minutes"] == 250


def test_verify_route_activates_mocked_transaction(monkeypatch):
    db = FakeDB()
    monkeypatch.setattr(apple_routes, "get_user_from_request", lambda _request: ({"id": "user-1"}, db))
    monkeypatch.setattr(apple_routes, "verify_signed_transaction", lambda _signed: _tx())
    monkeypatch.setattr(apple_routes, "create_service_role_client", lambda: db)

    class _Request:
        async def json(self):
            return {"signed_transaction": "signed-by-test"}

    response = asyncio.run(apple_routes.verify_apple_purchase(_Request()))
    assert response["status"] == "active"
    assert _user(db)["billing_plan_metadata"]["billing_source"] == "apple"


def test_verify_route_rejects_a_bad_signature(monkeypatch):
    monkeypatch.setattr(apple_routes, "get_user_from_request", lambda _request: ({"id": "user-1"}, None))

    class _Request:
        async def json(self):
            return {"signed_transaction": "not-a-jws"}

    response = asyncio.run(apple_routes.verify_apple_purchase(_Request()))
    assert response.status_code == 400


def test_notification_route_applies_refund(monkeypatch):
    db = FakeDB()
    apply_apple_subscription(db, _tx(), user_id="user-1", require_account_token=True, now_ms=NOW_MS)
    monkeypatch.setattr(
        apple_routes,
        "verify_signed_notification",
        lambda _payload: {
            "notification_type": "REFUND",
            "subtype": None,
            "notification_uuid": "note-refund",
            "signed_date_ms": NOW_MS + 20,
            "apple_status": 5,
            "signed_transaction_info": "signed-tx",
            "signed_renewal_info": None,
        },
    )
    monkeypatch.setattr(
        apple_routes,
        "verify_signed_transaction",
        lambda _signed: _tx(revocation_date_ms=NOW_MS + 20, signed_date_ms=NOW_MS + 20),
    )
    monkeypatch.setattr(apple_routes, "create_service_role_client", lambda: db)

    class _Request:
        async def json(self):
            return {"signedPayload": "signed-note"}

    response = asyncio.run(apple_routes.apple_server_notifications(_Request()))
    assert response["status"] == "canceled"
    assert _user(db)["subscription_status"] == "canceled"


def test_expired_launch_trial_does_not_restore_access_after_stripe_cancellation():
    db = FakeDB()
    db.tables["subscriptions"] = [
        {
            "id": "trial",
            "user_id": "user-1",
            "status": "trialing",
            "billing_source": None,
            "current_period_end": "2020-01-15T00:00:00Z",
            "updated_at": "2020-01-01T00:00:00Z",
        },
        {
            "id": "stripe",
            "user_id": "user-1",
            "status": "canceled",
            "billing_source": "stripe",
            "billing_provider_subscription_id": "sub_123",
            "updated_at": "2026-06-01T00:00:00Z",
        },
    ]
    state = get_billing_access_state(db, "user-1")
    assert state["has_active_subscription"] is False
    assert state["subscription"]["id"] == "stripe"
    assert should_preserve_user_access(db, "user-1", except_provider_subscription_id="sub_123") is False


def test_refund_of_an_older_renewal_keeps_the_current_period():
    db = FakeDB()
    apply_apple_subscription(
        db,
        _tx(transaction_id="tx-current", expires_date_ms=FUTURE_MS, signed_date_ms=NOW_MS),
        user_id="user-1",
        require_account_token=True,
        now_ms=NOW_MS,
    )
    result = apply_apple_subscription(
        db,
        _tx(
            transaction_id="tx-old",
            expires_date_ms=PAST_MS,
            revocation_date_ms=NOW_MS + 20,
            signed_date_ms=NOW_MS + 20,
        ),
        notification_type="REFUND",
        apple_status=1,
        now_ms=NOW_MS + 20,
    )
    assert result["ignored"] is True
    assert result["reason"] == "refunded_prior_transaction"
    assert _sub(db)["apple_transaction_id"] == "tx-current"
    assert _sub(db)["status"] == "active"
    assert _user(db)["subscription_status"] == "active"
    assert db.tables["user_plans"][0]["allocated_inbound_minutes"] > 0


def test_apple_expiry_restores_the_still_active_stripe_plan():
    db = FakeDB()
    db.tables["subscriptions"].append(
        {
            "id": "stripe-row",
            "user_id": "user-1",
            "status": "active",
            "billing_source": "stripe",
            "billing_provider_subscription_id": "sub_123",
            "plan_id": "plan-growth",
        }
    )
    apply_apple_subscription(
        db,
        _tx(),
        user_id="user-1",
        require_account_token=True,
        now_ms=NOW_MS,
    )
    assert _user(db)["billing_plan_metadata"]["billing_source"] == "apple"
    assert _user(db)["billing_plan_metadata"]["included_minutes"] == 250

    result = apply_apple_subscription(
        db,
        _tx(expires_date_ms=PAST_MS, signed_date_ms=NOW_MS + 30),
        notification_type="EXPIRED",
        now_ms=NOW_MS + 30,
    )
    assert result["preserved_other_billing"] is True
    assert _user(db)["subscription_status"] == "active"
    assert _user(db)["billing_plan"] == "subscription_growth"
    assert _user(db)["billing_plan_metadata"]["billing_source"] == "stripe"
    assert _user(db)["billing_plan_metadata"]["included_minutes"] == 750
    assert _user(db)["billing_plan_metadata"]["overage_allowed"] is True
    plan = db.tables["user_plans"][0]
    assert plan["billing_plan"] == "subscription_growth"
    assert plan["allocated_inbound_minutes"] + plan["allocated_outbound_minutes"] == 750
    assert plan["overage_rate_cents"] == 20


def test_apple_introductory_trial_is_capped_at_50_minutes():
    db = FakeDB()
    result = apply_apple_subscription(
        db,
        _tx(offer_type=1),
        user_id="user-1",
        notification_type="SUBSCRIBED",
        subtype="INITIAL_BUY",
        require_account_token=True,
        now_ms=NOW_MS,
    )
    assert result["status"] == "trialing"
    assert result["entitled"] is True
    assert _user(db)["subscription_status"] == "trialing"
    assert _user(db)["billing_plan_metadata"]["included_minutes"] == 50
    assert db.tables["user_plans"][0]["allocated_inbound_minutes"] + db.tables["user_plans"][0]["allocated_outbound_minutes"] == 50

    renewed = apply_apple_subscription(
        db,
        _tx(transaction_id="tx-paid", offer_type=None, signed_date_ms=NOW_MS + 10),
        notification_type="DID_RENEW",
        now_ms=NOW_MS + 10,
    )
    assert renewed["status"] == "active"
    assert _user(db)["billing_plan_metadata"]["included_minutes"] == 250


def test_stripe_trial_caps_included_minutes(monkeypatch):
    from stripe_plans import minutes_for_subscription, plan_from_subscription

    class _Price:
        id = "price_starter"
        metadata = {}

    class _Item:
        price = _Price()

    class _Items:
        data = [_Item()]

    class _Sub:
        items = _Items()

    monkeypatch.setenv("STRIPE_PRICE_STARTER", "price_starter")
    plan = plan_from_subscription(_Sub())
    assert plan is not None
    assert plan["billing_plan_metadata"]["included_minutes"] == 250
    assert plan["billing_plan_metadata"]["overage_rate_cents"] == 25
    trial = minutes_for_subscription(plan, "trialing")
    assert trial["billing_plan_metadata"]["included_minutes"] == 50
    assert trial["billing_plan_metadata"]["paid_included_minutes"] == 250
    paid = minutes_for_subscription(plan, "active")
    assert paid["billing_plan_metadata"]["included_minutes"] == 250


def test_notification_route_acks_test_notifications(monkeypatch):
    monkeypatch.setattr(
        apple_routes,
        "verify_signed_notification",
        lambda _payload: {"notification_type": "TEST"},
    )

    class _Request:
        async def json(self):
            return {"signedPayload": "signed-test"}

    response = asyncio.run(apple_routes.apple_server_notifications(_Request()))
    assert response["ignored"] is True
    assert response["reason"] == "test_notification"
