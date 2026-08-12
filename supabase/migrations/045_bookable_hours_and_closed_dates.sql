-- Structured weekly bookable hours + one-off closed days (holidays / special closures).
-- Weekly hours drive slot search; closed_dates override a specific calendar day as unavailable.

ALTER TABLE receptionists
  ADD COLUMN IF NOT EXISTS bookable_hours JSONB;

COMMENT ON COLUMN receptionists.bookable_hours IS
  'Weekly bookable windows: {"weekly":{"mon":{"open":true,"start":"09:00","end":"17:00"},...}}. '
  'Times are 24h HH:MM local. If end <= start while open, the window spans midnight.';

CREATE TABLE IF NOT EXISTS receptionist_closed_dates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  receptionist_id UUID NOT NULL REFERENCES receptionists(id) ON DELETE CASCADE,
  closed_on DATE NOT NULL,
  reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (receptionist_id, closed_on)
);

CREATE INDEX IF NOT EXISTS receptionist_closed_dates_receptionist_id_idx
  ON receptionist_closed_dates (receptionist_id);

CREATE INDEX IF NOT EXISTS receptionist_closed_dates_closed_on_idx
  ON receptionist_closed_dates (receptionist_id, closed_on);

ALTER TABLE receptionist_closed_dates ENABLE ROW LEVEL SECURITY;

-- Service role / backend uses service key; owners can manage via authenticated policies later.
DROP POLICY IF EXISTS receptionist_closed_dates_owner_all ON receptionist_closed_dates;
CREATE POLICY receptionist_closed_dates_owner_all
  ON receptionist_closed_dates
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM receptionists r
      WHERE r.id = receptionist_closed_dates.receptionist_id
        AND r.user_id = auth.uid()
        AND r.deleted_at IS NULL
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM receptionists r
      WHERE r.id = receptionist_closed_dates.receptionist_id
        AND r.user_id = auth.uid()
        AND r.deleted_at IS NULL
    )
  );
