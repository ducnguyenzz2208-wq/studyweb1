-- ============================================================
-- TUTOR HUB — Full schema + RLS
-- Run this in Supabase SQL Editor (Dashboard → SQL Editor → New Query)
-- ============================================================

-- ── PROFILES ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS profiles (
  id           UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
  email        TEXT NOT NULL,
  name         TEXT,
  role         TEXT NOT NULL DEFAULT 'Pending'
                 CHECK (role IN ('Admin','Teacher','Parent','Student','Pending')),
  avatar       TEXT,
  subject      TEXT,
  language     TEXT NOT NULL DEFAULT 'en',
  linked_student_id UUID,    -- for Parent role: points to students.id
  class_name   TEXT,         -- for Student role
  created_at   TIMESTAMPTZ DEFAULT NOW(),
  updated_at   TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users read own profile"
  ON profiles FOR SELECT USING (auth.uid() = id);

CREATE POLICY "Users update own profile"
  ON profiles FOR UPDATE USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

CREATE POLICY "Users insert own profile"
  ON profiles FOR INSERT WITH CHECK (auth.uid() = id);

-- ── AUTO-CREATE PROFILE ON SIGNUP ───────────────────────────
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _role TEXT;
  _name TEXT;
  _avatar TEXT;
BEGIN
  -- worldatwarduc@gmail.com is always Admin
  _role := CASE WHEN NEW.email = 'worldatwarduc@gmail.com' THEN 'Admin'
                ELSE 'Pending'          -- all new signups start as Pending until admin approves
           END;
  _name := COALESCE(
    NEW.raw_user_meta_data->>'full_name',
    split_part(NEW.email, '@', 1)
  );
  _avatar := UPPER(LEFT(REGEXP_REPLACE(_name, '\s+', ' '), 2));

  INSERT INTO profiles (id, email, name, role, avatar, language)
  VALUES (NEW.id, NEW.email, _name, _role, _avatar, 'en')
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ── ENFORCE ADMIN EMAIL ON EVERY PROFILE WRITE ──────────────
CREATE OR REPLACE FUNCTION public.enforce_admin_email()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF (SELECT email FROM auth.users WHERE id = NEW.id) = 'worldatwarduc@gmail.com' THEN
    NEW.role := 'Admin';
  END IF;
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_admin_on_profile ON profiles;
CREATE TRIGGER enforce_admin_on_profile
  BEFORE INSERT OR UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION public.enforce_admin_email();

-- ── SUBJECTS ─────────────────────────────────────────────────
-- Each tutor/admin manages their own subject list. The app ships
-- default subjects; admins can add/remove via the Subjects panel.
CREATE TABLE IF NOT EXISTS subjects (
  id         UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  owner_id   UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  name       TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(owner_id, name)
);

ALTER TABLE subjects ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users manage own subjects"
  ON subjects FOR ALL USING (auth.uid() = owner_id)
  WITH CHECK (auth.uid() = owner_id);

CREATE POLICY "Teacher/Student read all subjects"
  ON subjects FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role IN ('Admin','Teacher','Student','Parent')
    )
  );

-- ── MATERIALS ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS materials (
  id         UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  owner_id   UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  title      TEXT NOT NULL,
  subject    TEXT,
  type       TEXT,
  content    TEXT,
  url        TEXT,
  pinned     BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE materials ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users manage own materials"
  ON materials FOR ALL USING (auth.uid() = owner_id)
  WITH CHECK (auth.uid() = owner_id);

-- Admins and Teachers can read all materials
CREATE POLICY "Admin/Teacher read all materials"
  ON materials FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role IN ('Admin','Teacher')
    )
  );

-- ── FLASHCARD DECKS ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS flashcard_decks (
  id          UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  owner_id    UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  name        TEXT NOT NULL,
  subject     TEXT,
  description TEXT,
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE flashcard_decks ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users manage own decks"
  ON flashcard_decks FOR ALL USING (auth.uid() = owner_id)
  WITH CHECK (auth.uid() = owner_id);

-- ── FLASHCARDS ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS flashcards (
  id          UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  deck_id     UUID REFERENCES flashcard_decks(id) ON DELETE CASCADE NOT NULL,
  owner_id    UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  front       TEXT NOT NULL,
  back        TEXT NOT NULL,
  difficulty  TEXT DEFAULT 'medium',
  is_favorite BOOLEAN DEFAULT FALSE,
  rating      INT DEFAULT 0,
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE flashcards ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users manage own flashcards"
  ON flashcards FOR ALL USING (auth.uid() = owner_id)
  WITH CHECK (auth.uid() = owner_id);

-- ── CLASSES ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS classes (
  id           UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  owner_id     UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  name         TEXT NOT NULL,
  subject      TEXT,
  schedule     TEXT,
  room         TEXT,
  max_students INT,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE classes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Teacher/Admin manage classes"
  ON classes FOR ALL
  USING (auth.uid() = owner_id)
  WITH CHECK (auth.uid() = owner_id);

CREATE POLICY "Students/Parents read classes"
  ON classes FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role IN ('Student','Parent')
    )
  );

-- ── STUDENTS ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS students (
  id           UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  owner_id     UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  name         TEXT NOT NULL,
  email        TEXT,
  class_name   TEXT,
  grade        TEXT,
  math_score   INT DEFAULT 0,
  eng_score    INT DEFAULT 0,
  attendance   INT DEFAULT 0,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE students ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Teacher/Admin manage students"
  ON students FOR ALL
  USING (auth.uid() = owner_id)
  WITH CHECK (auth.uid() = owner_id);

CREATE POLICY "Students read own record"
  ON students FOR SELECT
  USING (
    email = (SELECT email FROM auth.users WHERE id = auth.uid())
  );

CREATE POLICY "Parents read linked student"
  ON students FOR SELECT
  USING (
    id = (SELECT linked_student_id FROM profiles WHERE id = auth.uid())
  );

-- ── HOMEWORK ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS homework (
  id         UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  owner_id   UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  title      TEXT NOT NULL,
  subject    TEXT,
  class_name TEXT,
  due_date   DATE,
  status     TEXT DEFAULT 'pending',
  submitted  INT DEFAULT 0,
  total      INT DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE homework ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Teacher/Admin manage homework"
  ON homework FOR ALL
  USING (auth.uid() = owner_id)
  WITH CHECK (auth.uid() = owner_id);

CREATE POLICY "Students/Parents read homework"
  ON homework FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role IN ('Student','Parent')
    )
  );

-- ── SCHEDULE EVENTS ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS schedule_events (
  id         UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  owner_id   UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  title      TEXT NOT NULL,
  subject    TEXT,
  date       DATE,
  time       TEXT,
  duration   TEXT,
  type       TEXT,
  notes      TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE schedule_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users manage own schedule"
  ON schedule_events FOR ALL
  USING (auth.uid() = owner_id)
  WITH CHECK (auth.uid() = owner_id);

-- ── TEACHER COMMENTS ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS teacher_comments (
  id           UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  teacher_id   UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  student_id   UUID,
  student_name TEXT,
  comment      TEXT NOT NULL,
  type         TEXT DEFAULT 'general',
  date         DATE DEFAULT CURRENT_DATE,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE teacher_comments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Teachers manage own comments"
  ON teacher_comments FOR ALL
  USING (auth.uid() = teacher_id)
  WITH CHECK (auth.uid() = teacher_id);

CREATE POLICY "Students read comments about them"
  ON teacher_comments FOR SELECT
  USING (
    student_id = (SELECT linked_student_id FROM profiles WHERE id = auth.uid())
    OR
    student_id::TEXT = (
      SELECT id::TEXT FROM students
      WHERE email = (SELECT email FROM auth.users WHERE id = auth.uid())
      LIMIT 1
    )
  );

-- ── ACTIVITY LOGS ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS activity_logs (
  id         UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id    UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  action     TEXT NOT NULL,
  details    TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE activity_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users manage own logs"
  ON activity_logs FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- ── UPDATED_AT HELPER ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;

DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['profiles','materials','flashcard_decks','flashcards'] LOOP
    EXECUTE format(
      'DROP TRIGGER IF EXISTS set_updated_at ON %I;
       CREATE TRIGGER set_updated_at BEFORE UPDATE ON %I
       FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();', t, t);
  END LOOP;
END;
$$;

-- ── ASSIGNMENTS ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS assignments (
  id          UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  owner_id    UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  title       TEXT NOT NULL,
  subject     TEXT,
  class_name  TEXT,
  due_date    DATE,
  description TEXT,
  status      TEXT DEFAULT 'open' CHECK (status IN ('open','closed')),
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE assignments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Teacher/Admin manage own assignments"
  ON assignments FOR ALL
  USING (auth.uid() = owner_id)
  WITH CHECK (auth.uid() = owner_id);

CREATE POLICY "Students/Parents read assignments"
  ON assignments FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role IN ('Student','Parent')
    )
  );

-- ── ASSIGNMENT SUBMISSIONS ────────────────────────────────────
CREATE TABLE IF NOT EXISTS assignment_submissions (
  id            UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  assignment_id UUID REFERENCES assignments(id) ON DELETE CASCADE NOT NULL,
  student_id    UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  student_name  TEXT,
  type          TEXT DEFAULT 'text' CHECK (type IN ('text','file')),
  content       TEXT,
  file_url      TEXT,
  grade         NUMERIC(4,1),
  feedback      TEXT,
  submitted_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(assignment_id, student_id)
);

ALTER TABLE assignment_submissions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Students manage own submissions"
  ON assignment_submissions FOR ALL
  USING (auth.uid() = student_id)
  WITH CHECK (auth.uid() = student_id);

CREATE POLICY "Teacher/Admin read/grade all submissions"
  ON assignment_submissions FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role IN ('Admin','Teacher')
    )
  );

-- ── ATTENDANCE RECORDS ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS attendance_records (
  id           UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  teacher_id   UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  student_ref  TEXT NOT NULL,     -- student ID (string, may reference local or DB ID)
  student_name TEXT,
  class_name   TEXT,
  session_date DATE NOT NULL,
  status       TEXT NOT NULL CHECK (status IN ('present','absent','late')),
  created_at   TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(teacher_id, student_ref, session_date)
);

ALTER TABLE attendance_records ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Teacher/Admin manage attendance"
  ON attendance_records FOR ALL
  USING (auth.uid() = teacher_id)
  WITH CHECK (auth.uid() = teacher_id);

CREATE POLICY "Students/Parents read own attendance"
  ON attendance_records FOR SELECT
  USING (
    student_name = (SELECT name FROM profiles WHERE id = auth.uid())
  );

-- ── SUPABASE STORAGE BUCKET ───────────────────────────────────
-- Run this separately in Supabase dashboard → Storage, or via SQL:
INSERT INTO storage.buckets (id, name, public)
VALUES ('tutor-hub', 'tutor-hub', false)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "Authenticated users upload submissions"
  ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'tutor-hub' AND auth.role() = 'authenticated');

CREATE POLICY "Owner reads own files"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'tutor-hub' AND auth.uid()::TEXT = (storage.foldername(name))[1]);

CREATE POLICY "Teacher/Admin read all submission files"
  ON storage.objects FOR SELECT
  USING (
    bucket_id = 'tutor-hub' AND
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role IN ('Admin','Teacher')
    )
  );

-- ── SCHEMA ADDENDUM v2 ────────────────────────────────────────
-- Run in Supabase SQL Editor when upgrading an existing DB.

-- New columns on assignments
ALTER TABLE assignments
  ADD COLUMN IF NOT EXISTS grades_published BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS attachment_url   TEXT;

-- Admin can read ALL profiles (required for user-management panel)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='profiles' AND policyname='Admin reads all profiles') THEN
    CREATE POLICY "Admin reads all profiles"
      ON profiles FOR SELECT
      USING ('Admin' = (SELECT role FROM profiles p WHERE p.id = auth.uid() LIMIT 1));
  END IF;
END $$;

-- Admin can update ANY profile (role promotion / demotion)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='profiles' AND policyname='Admin updates any profile') THEN
    CREATE POLICY "Admin updates any profile"
      ON profiles FOR UPDATE
      USING ('Admin' = (SELECT role FROM profiles p WHERE p.id = auth.uid() LIMIT 1))
      WITH CHECK ('Admin' = (SELECT role FROM profiles p WHERE p.id = auth.uid() LIMIT 1));
  END IF;
END $$;

-- Assignment comments / discussion
CREATE TABLE IF NOT EXISTS assignment_comments (
  id            UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  assignment_id UUID REFERENCES assignments(id) ON DELETE CASCADE NOT NULL,
  user_id       UUID REFERENCES auth.users(id)  ON DELETE CASCADE NOT NULL,
  user_name     TEXT NOT NULL,
  content       TEXT NOT NULL,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE assignment_comments ENABLE ROW LEVEL SECURITY;

-- Any authenticated user who can see the assignment can read its comments
CREATE POLICY "Users read assignment comments"
  ON assignment_comments FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE profiles.id = auth.uid()
        AND profiles.role IN ('Admin','Teacher','Student','Parent')
    )
  );

-- Users insert their own comments
CREATE POLICY "Users insert own comments"
  ON assignment_comments FOR INSERT
  WITH CHECK (user_id = auth.uid());

-- Users delete their own comments; admin can delete any
CREATE POLICY "Users delete own comments"
  ON assignment_comments FOR DELETE
  USING (
    user_id = auth.uid()
    OR 'Admin' = (SELECT role FROM profiles p WHERE p.id = auth.uid() LIMIT 1)
  );
