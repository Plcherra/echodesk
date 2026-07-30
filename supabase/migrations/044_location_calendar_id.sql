-- Per-store Google calendar under the owner's connected Google account.

ALTER TABLE public.locations
  ADD COLUMN IF NOT EXISTS calendar_id TEXT;

COMMENT ON COLUMN public.locations.calendar_id IS
  'Google Calendar id for this store (under users.calendar_refresh_token). Null = use receptionist.calendar_id.';
