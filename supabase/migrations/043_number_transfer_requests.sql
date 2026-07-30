-- Number transfer evaluation requests (customer intake → ops review → optional port).

CREATE TABLE IF NOT EXISTS public.number_transfer_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  business_id UUID REFERENCES public.businesses(id) ON DELETE SET NULL,
  phone_number_e164 TEXT NOT NULL,
  number_kind TEXT NOT NULL
    CHECK (number_kind IN ('mobile_carrier', 'voip_internet')),
  carrier_or_provider TEXT NOT NULL,
  customer_note TEXT,
  status TEXT NOT NULL DEFAULT 'pending_review'
    CHECK (status IN ('pending_review', 'porting', 'completed', 'rejected', 'cancelled')),
  ops_note TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS number_transfer_requests_user_id_idx
  ON public.number_transfer_requests(user_id);

CREATE INDEX IF NOT EXISTS number_transfer_requests_business_id_idx
  ON public.number_transfer_requests(business_id)
  WHERE business_id IS NOT NULL;

-- At most one open request per user
CREATE UNIQUE INDEX IF NOT EXISTS number_transfer_requests_one_open_per_user
  ON public.number_transfer_requests(user_id)
  WHERE status IN ('pending_review', 'porting');

COMMENT ON TABLE public.number_transfer_requests IS
  'Customer requests to evaluate/transfer an existing phone number (cell or VoIP) into EchoDesk.';

ALTER TABLE public.number_transfer_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users read own number_transfer_requests" ON public.number_transfer_requests;
CREATE POLICY "Users read own number_transfer_requests" ON public.number_transfer_requests
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users insert own number_transfer_requests" ON public.number_transfer_requests;
CREATE POLICY "Users insert own number_transfer_requests" ON public.number_transfer_requests
  FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Service role full number_transfer_requests" ON public.number_transfer_requests;
CREATE POLICY "Service role full number_transfer_requests" ON public.number_transfer_requests
  FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');
