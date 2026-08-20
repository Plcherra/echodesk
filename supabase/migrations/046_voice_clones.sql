-- Pocket TTS voice clones. Bound per receptionist; clone wins over preset when set.

CREATE TABLE IF NOT EXISTS public.voice_clones (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  org_id UUID,
  label TEXT NOT NULL DEFAULT 'My voice',
  embedding_path TEXT NOT NULL,
  consent_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS voice_clones_user_id_idx
  ON public.voice_clones(user_id);

COMMENT ON TABLE public.voice_clones IS
  'Zero-shot Pocket TTS voice embeddings. Owner-only; files live on the VPS sidecar disk.';

ALTER TABLE public.voice_clones ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users read own voice_clones" ON public.voice_clones;
CREATE POLICY "Users read own voice_clones" ON public.voice_clones
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users insert own voice_clones" ON public.voice_clones;
CREATE POLICY "Users insert own voice_clones" ON public.voice_clones
  FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users delete own voice_clones" ON public.voice_clones;
CREATE POLICY "Users delete own voice_clones" ON public.voice_clones
  FOR DELETE USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Service role full voice_clones" ON public.voice_clones;
CREATE POLICY "Service role full voice_clones" ON public.voice_clones
  FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');

ALTER TABLE public.receptionists
  ADD COLUMN IF NOT EXISTS voice_clone_id UUID REFERENCES public.voice_clones(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS receptionists_voice_clone_id_idx
  ON public.receptionists(voice_clone_id)
  WHERE voice_clone_id IS NOT NULL;

COMMENT ON COLUMN public.receptionists.voice_clone_id IS
  'When set, live TTS uses Pocket sidecar for this receptionist. voice_preset_key remains the Google fallback.';
