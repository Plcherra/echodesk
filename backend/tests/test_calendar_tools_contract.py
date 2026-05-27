from __future__ import annotations

from datetime import datetime, timezone

import pytest

from calendar_api import calendar_handler


class _FreebusyQuery:
    def __init__(self, result: dict):
        self._result = result

    def execute(self) -> dict:
        return self._result


class _Freebusy:
    def __init__(self, result: dict, capture: dict | None = None):
        self._result = result
        self._capture = capture

    def query(self, body: dict) -> _FreebusyQuery:
        if self._capture is not None:
            self._capture.setdefault("freebusy_queries", []).append(body)
        return _FreebusyQuery(self._result)


class _EventsInsert:
    def __init__(self, event: dict, capture: dict | None = None, body: dict | None = None):
        self._event = event
        if isinstance(capture, dict) and isinstance(body, dict):
            capture["last_insert_body"] = body

    def execute(self) -> dict:
        return self._event


class _Events:
    def __init__(self, event: dict, capture: dict | None = None):
        self._event = event
        self._capture = capture

    def insert(self, calendarId: str, body: dict, sendUpdates: str = "none") -> _EventsInsert:
        # Capture body so tests can assert computed end time.
        return _EventsInsert(self._event, capture=self._capture, body=body)


class _Service:
    def __init__(self, freebusy_result: dict, event: dict | None = None, capture: dict | None = None):
        self._freebusy_result = freebusy_result
        self._event = event or {}
        self._capture = capture

    def freebusy(self) -> _Freebusy:
        return _Freebusy(self._freebusy_result, capture=self._capture)

    def events(self) -> _Events:
        return _Events(self._event, capture=self._capture)


class _SBServicesQuery:
    def __init__(self, services: list[dict]):
        self._services = services
        self._filters: dict[str, tuple[str, str]] = {}
        self._limit = None

    def select(self, _fields: str):
        return self

    def eq(self, key: str, value: str):
        self._filters[key] = ("eq", value)
        return self

    def ilike(self, key: str, value: str):
        self._filters[key] = ("ilike", value)
        return self

    def limit(self, n: int):
        self._limit = n
        return self

    def execute(self):
        def _match(row: dict) -> bool:
            for k, (op, v) in self._filters.items():
                rv = row.get(k)
                if op == "eq":
                    if rv != v:
                        return False
                elif op == "ilike":
                    if str(rv or "").lower() != str(v or "").lower():
                        return False
            return True

        out = [r for r in self._services if _match(r)]
        if self._limit is not None:
            out = out[: self._limit]
        return type("R", (), {"data": out})()


class _SBAppointmentsTable:
    def __init__(self, capture: dict):
        self._capture = capture

    def insert(self, row: dict):
        self._capture["last_appt_row"] = row
        return self

    def execute(self):
        return type("R", (), {"data": []})()


class _SB:
    def __init__(self, *, services: list[dict], capture: dict):
        self._services = services
        self._capture = capture

    def table(self, name: str):
        if name == "services":
            return _SBServicesQuery(self._services)
        if name == "receptionists":
            # Best-effort: allow tests to supply receptionist-level config via capture.
            tmpl = self._capture.get("generic_followup_message_template")
            users = self._capture.get("receptionist_users")
            if users is None and self._capture.get("account_business_name"):
                users = {"business_name": self._capture.get("account_business_name")}
            row = {
                "id": "rec-1",
                "name": self._capture.get("receptionist_name", "Test Receptionist"),
                "users": users,
                "generic_followup_message_template": tmpl,
                "telnyx_phone_number": self._capture.get("telnyx_phone_number"),
                "inbound_phone_number": self._capture.get("inbound_phone_number"),
            }
            return _SBServicesQuery([row])
        if name == "appointments":
            return _SBAppointmentsTable(self._capture)
        raise AssertionError(f"unexpected table: {name}")


def test_check_availability_requires_date():
    service = _Service(freebusy_result={})
    out = calendar_handler._handle_check_availability(service, "primary", params={})
    assert out["success"] is False
    assert out["error"] == "date_missing"


def test_check_availability_range_defaults_to_60_minutes():
    freebusy = {"calendars": {"primary": {"busy": []}}}
    service = _Service(freebusy_result=freebusy)
    out = calendar_handler._handle_check_availability(
        service,
        "primary",
        # Use a deterministic date-only input so parsing is stable in tests.
        params={"date_text": "2026-03-18", "timezone": "America/New_York"},
    )
    assert out["success"] is True
    assert out["slot_duration_minutes"] == calendar_handler.DEFAULT_AVAILABILITY_SLOT_MINUTES
    assert len(out.get("suggested_slots") or []) <= calendar_handler.SUGGESTED_SLOTS_MAX
    assert len(out.get("exact_slots") or []) > len(out.get("suggested_slots") or [])
    assert any("09:00:00" in s for s in out.get("exact_slots") or [])


def test_check_availability_exact_time_unavailable_returns_alternatives():
    freebusy = {
        "calendars": {
            "primary": {
                "busy": [
                    {
                        "start": "2026-03-18T14:00:00-04:00",
                        "end": "2026-03-18T15:00:00-04:00",
                    }
                ]
            }
        }
    }
    service = _Service(freebusy_result=freebusy)
    out = calendar_handler._handle_check_availability(
        service,
        "primary",
        params={"date_text": "2026-03-18T14:00:00-04:00", "timezone": "America/New_York"},
    )
    assert out["success"] is True
    assert out["slot_available"] is False
    assert any("15:00:00" in s for s in out.get("suggested_slots") or [])
    assert any("15:00:00" in s for s in out.get("exact_slots") or [])


def test_create_appointment_missing_date_returns_date_missing():
    service = _Service(freebusy_result={})
    out = calendar_handler._handle_create_appointment(
        service,
        "primary",
        params={"summary": "Test"},
        receptionist_id="rec-1",
        supabase=None,
    )
    assert out["success"] is False
    assert out["error"] == "date_missing"


def test_create_appointment_busy_slot_returns_slot_unavailable_and_suggestions(monkeypatch):
    # First freebusy check (slot check) returns busy, then day freebusy returns empty.
    class _ServiceBusyThenDay(_Service):
        def __init__(self):
            super().__init__(freebusy_result={})
            self._calls = 0

        def freebusy(self) -> _Freebusy:
            self._calls += 1
            if self._calls == 1:
                return _Freebusy({"calendars": {"primary": {"busy": [{"start": "2026-03-17T10:00:00+00:00", "end": "2026-03-17T10:30:00+00:00"}]}}})
            return _Freebusy({"calendars": {"primary": {"busy": []}}})

    service = _ServiceBusyThenDay()

    # Avoid appointment persistence side effects.
    class _SB:
        def table(self, name: str):
            raise AssertionError("should not persist on slot_unavailable")

    out = calendar_handler._handle_create_appointment(
        service,
        "primary",
        params={
            "summary": "Test",
            "start_time": "2026-03-17T10:00:00+00:00",
            "duration_minutes": 30,
        },
        receptionist_id="rec-1",
        supabase=_SB(),
    )
    assert out["success"] is False
    assert out["error"] == "slot_unavailable"
    assert isinstance(out.get("suggested_slots"), list)
    assert len(out.get("suggested_slots") or []) <= 5


def test_create_appointment_success_returns_event_fields(monkeypatch):
    freebusy = {"calendars": {"primary": {"busy": []}}}
    event = {
        "id": "evt-123",
        "htmlLink": "https://example.com/event",
        "start": {"dateTime": "2026-03-17T10:00:00+00:00"},
        "end": {"dateTime": "2026-03-17T10:30:00+00:00"},
        "summary": "Test",
    }
    service = _Service(freebusy_result=freebusy, event=event)

    class _Tbl:
        def insert(self, row: dict):
            return self

        def execute(self):
            return type("R", (), {"data": []})()

    class _SB:
        def table(self, name: str):
            assert name == "appointments"
            return _Tbl()

    out = calendar_handler._handle_create_appointment(
        service,
        "primary",
        params={
            "summary": "Test",
            "start_time": "2026-03-17T10:00:00+00:00",
            "duration_minutes": 30,
        },
        receptionist_id="rec-1",
        supabase=_SB(),
    )
    assert out["success"] is True
    assert out["event_id"] == "evt-123"
    assert out["summary"] == "Test"


def test_create_appointment_naive_iso_freebusy_includes_tz_offset():
    """Naive slot ISO from the voice fast path must use an offset for Google freeBusy (RFC3339)."""
    capture: dict = {}
    freebusy = {"calendars": {"primary": {"busy": []}}}
    event = {"id": "evt-naive", "summary": "Appt"}
    service = _Service(freebusy_result=freebusy, event=event, capture=capture)

    class _Tbl:
        def insert(self, row: dict):
            return self

        def execute(self):
            return type("R", (), {"data": []})()

    class _SB:
        def table(self, name: str):
            assert name == "appointments"
            return _Tbl()

    out = calendar_handler._handle_create_appointment(
        service,
        "primary",
        params={
            "summary": "Test",
            "start_time": "2026-04-11T14:00:00",
            "duration_minutes": 30,
            "timezone": "America/New_York",
        },
        receptionist_id="rec-1",
        supabase=_SB(),
    )
    assert out["success"] is True
    queries = capture.get("freebusy_queries") or []
    assert len(queries) >= 1
    time_min = queries[0]["timeMin"]
    assert time_min != "2026-04-11T14:00:00"
    assert datetime.fromisoformat(time_min.replace("Z", "+00:00")).tzinfo is not None

    insert_body = capture.get("last_insert_body") or {}
    start_raw = (insert_body.get("start") or {}).get("dateTime") or ""
    assert start_raw
    assert start_raw != "2026-04-11T14:00:00"
    assert datetime.fromisoformat(start_raw.replace("Z", "+00:00")).tzinfo is not None


def test_create_appointment_service_duration_overrides_tool_duration_and_persists(monkeypatch):
    freebusy = {"calendars": {"primary": {"busy": []}}}
    capture: dict = {}
    service = _Service(freebusy_result=freebusy, event={"id": "evt-1", "summary": "Svc"}, capture=capture)
    sb = _SB(
        services=[
            {
                "id": "svc-1",
                "receptionist_id": "rec-1",
                "name": "Business consulting",
                "duration_minutes": 60,
                "price_cents": 10000,
                "requires_location": False,
                "default_location_type": "video_meeting",
                "followup_mode": "send_payment_link",
                "followup_message_template": "We’ll text you the payment link shortly.",
                "payment_link": "https://pay.example/link",
                "meeting_instructions": "Use the link in your confirmation text.",
                "owner_selected_platform": "Google Meet",
                "internal_followup_notes": "VIP client",
            }
        ],
        capture=capture,
    )

    out = calendar_handler._handle_create_appointment(
        service,
        "primary",
        params={
            "summary": "Test",
            "start_time": "2026-03-17T10:00:00+00:00",
            "duration_minutes": 30,  # should be ignored for service-based booking
            "service_id": "svc-1",
            "service_name": "Business consulting",
            "location_type": "custom",  # should be overridden by default_location_type
            "price_cents": 1,  # should be overridden by stored price when set
        },
        receptionist_id="rec-1",
        supabase=sb,
    )

    assert out["success"] is True
    assert capture["last_appt_row"]["duration_minutes"] == 60
    assert capture["last_appt_row"]["price_cents"] == 10000
    assert capture["last_appt_row"]["location_type"] == "video_meeting"
    assert capture["last_appt_row"]["service_id"] == "svc-1"
    assert capture["last_appt_row"]["service_name"] == "Business consulting"
    assert capture["last_appt_row"]["booking_mode"] == "service_based"
    assert capture["last_appt_row"]["followup_mode"] == "send_payment_link"
    assert capture["last_appt_row"]["followup_message_resolved"] == "We’ll text you the payment link shortly."
    assert capture["last_appt_row"]["payment_link"] == "https://pay.example/link"
    assert capture["last_appt_row"]["owner_selected_platform"] == "Google Meet"
    assert capture["last_appt_row"]["meeting_instructions"] == "Use the link in your confirmation text."
    assert capture["last_appt_row"]["internal_followup_notes"] == "VIP client"
    # Verify Google Calendar event end time reflects 60 minutes, not 30.
    assert capture["last_insert_body"]["end"]["dateTime"].startswith("2026-03-17T11:00:00")


def test_create_appointment_service_location_type_overrides_to_phone_call(monkeypatch):
    freebusy = {"calendars": {"primary": {"busy": []}}}
    capture: dict = {}
    service = _Service(freebusy_result=freebusy, event={"id": "evt-2", "summary": "Svc2"}, capture=capture)
    sb = _SB(
        services=[
            {
                "id": "svc-2",
                "receptionist_id": "rec-1",
                "name": "Phone intake",
                "duration_minutes": 45,
                "price_cents": None,
                "requires_location": True,
                "default_location_type": "phone_call",
                # No followup fields -> backend defaults to under_review
            }
        ],
        capture=capture,
    )

    out = calendar_handler._handle_create_appointment(
        service,
        "primary",
        params={
            "summary": "Test",
            "start_time": "2026-03-17T10:00:00+00:00",
            "duration_minutes": 30,
            "service_name": "Phone intake",
            "location_type": "video_meeting",  # should be overridden
            # location_text not required for phone_call
        },
        receptionist_id="rec-1",
        supabase=sb,
    )
    assert out["success"] is True
    assert capture["last_appt_row"]["duration_minutes"] == 45
    assert capture["last_appt_row"]["location_type"] == "phone_call"
    assert capture["last_appt_row"]["booking_mode"] == "service_based"
    assert capture["last_appt_row"]["followup_mode"] == "under_review"
    assert capture["last_appt_row"]["followup_message_resolved"]


def test_create_appointment_generic_booking_sets_under_review_followup(monkeypatch):
    freebusy = {"calendars": {"primary": {"busy": []}}}
    capture: dict = {"generic_followup_message_template": "Custom generic under review message."}
    service = _Service(freebusy_result=freebusy, event={"id": "evt-g", "summary": "Gen"}, capture=capture)
    sb = _SB(services=[], capture=capture)

    out = calendar_handler._handle_create_appointment(
        service,
        "primary",
        params={
            "summary": "Test",
            "start_time": "2026-03-17T10:00:00+00:00",
            "duration_minutes": 30,
            # No service_id/service_name -> generic
        },
        receptionist_id="rec-1",
        supabase=sb,
    )
    assert out["success"] is True
    assert capture["last_appt_row"]["booking_mode"] == "generic"
    assert capture["last_appt_row"]["followup_mode"] == "under_review"
    assert capture["last_appt_row"]["followup_message_resolved"] == "Custom generic under review message."


def test_create_appointment_success_sends_sms_when_caller_phone_present(monkeypatch):
    from telnyx import sms as sms_mod

    calls: list[dict] = []

    def _fake_send_sms(*, to_number: str, from_number: str, text: str) -> dict:
        calls.append({"to": to_number, "from": from_number, "text": text})
        return {"success": True, "telnyx_message_id": "msg-1"}

    monkeypatch.setattr(sms_mod, "send_sms", _fake_send_sms)

    freebusy = {"calendars": {"primary": {"busy": []}}}
    capture: dict = {
        "telnyx_phone_number": "+15550001111",
        "generic_followup_message_template": "Under review.",
    }
    service = _Service(freebusy_result=freebusy, event={"id": "evt-sms", "summary": "Gen"}, capture=capture)
    sb = _SB(services=[], capture=capture)

    out = calendar_handler._handle_create_appointment(
        service,
        "primary",
        params={
            "summary": "Test",
            "start_time": "2026-03-17T10:00:00+00:00",
            "duration_minutes": 30,
            "caller_phone": "+15551234567",
        },
        receptionist_id="rec-1",
        supabase=sb,
    )
    assert out["success"] is True
    assert len(calls) == 1
    assert calls[0]["to"] == "+15551234567"
    assert calls[0]["from"] == "+15550001111"
    assert "Under review." in calls[0]["text"]
    assert "Reply STOP to opt out." in calls[0]["text"]


def test_create_appointment_failure_does_not_send_sms(monkeypatch):
    from telnyx import sms as sms_mod

    calls: list[dict] = []

    def _fake_send_sms(*, to_number: str, from_number: str, text: str) -> dict:
        calls.append({"to": to_number, "from": from_number, "text": text})
        return {"success": True}

    monkeypatch.setattr(sms_mod, "send_sms", _fake_send_sms)

    service = _Service(freebusy_result={})
    out = calendar_handler._handle_create_appointment(
        service,
        "primary",
        params={"summary": "Test", "caller_phone": "+15551234567"},
        receptionist_id="rec-1",
        supabase=None,
    )
    assert out["success"] is False
    assert calls == []


def test_create_appointment_invalid_caller_phone_skips_sms(monkeypatch):
    from telnyx import sms as sms_mod

    calls: list[dict] = []

    def _fake_send_sms(*, to_number: str, from_number: str, text: str) -> dict:
        calls.append({"to": to_number, "from": from_number, "text": text})
        return {"success": True}

    monkeypatch.setattr(sms_mod, "send_sms", _fake_send_sms)

    freebusy = {"calendars": {"primary": {"busy": []}}}
    capture: dict = {
        "telnyx_phone_number": "+15550001111",
        "generic_followup_message_template": "Under review.",
    }
    service = _Service(freebusy_result=freebusy, event={"id": "evt-sms2", "summary": "Gen"}, capture=capture)
    sb = _SB(services=[], capture=capture)

    out = calendar_handler._handle_create_appointment(
        service,
        "primary",
        params={
            "summary": "Test",
            "start_time": "2026-03-17T10:00:00+00:00",
            "duration_minutes": 30,
            "caller_phone": "private",  # invalid E.164
        },
        receptionist_id="rec-1",
        supabase=sb,
    )
    assert out["success"] is True
    assert calls == []
