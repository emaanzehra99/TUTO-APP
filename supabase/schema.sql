-- Tuto production database starter. Review and test policies before storing real student data.
create extension if not exists pgcrypto;

create type public.classroom_role as enum ('teacher', 'student');
create type public.assignment_status as enum ('published', 'submitted', 'graded');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 100),
  role public.classroom_role not null,
  created_at timestamptz not null default now()
);

create table public.classrooms (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references public.profiles(id) on delete cascade,
  name text not null default 'My classroom',
  subject text not null default 'Learning',
  created_at timestamptz not null default now()
);

create table public.classroom_students (
  classroom_id uuid not null references public.classrooms(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (classroom_id, student_id)
);

create table public.assignments (
  id uuid primary key default gen_random_uuid(),
  classroom_id uuid not null references public.classrooms(id) on delete cascade,
  created_by uuid not null references public.profiles(id),
  title text not null check (char_length(title) between 1 and 150),
  subject text not null default 'General',
  assignment_type text not null check (assignment_type in ('Homework','Quiz','Test','Exam')),
  instructions text not null default '',
  due_at timestamptz,
  max_points numeric(7,2) not null check (max_points > 0),
  attachment_path text,
  published_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.submissions (
  id uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references public.assignments(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  file_path text,
  student_note text not null default '',
  submitted_at timestamptz not null default now(),
  grade numeric(7,2) check (grade >= 0),
  feedback text not null default '',
  graded_by uuid references public.profiles(id),
  graded_at timestamptz,
  released_at timestamptz,
  unique (assignment_id, student_id)
);

create table public.lessons (
  id uuid primary key default gen_random_uuid(),
  classroom_id uuid not null references public.classrooms(id) on delete cascade,
  title text not null,
  starts_at timestamptz not null,
  notes text not null default '',
  created_at timestamptz not null default now()
);

create table public.grade_weights (
  classroom_id uuid primary key references public.classrooms(id) on delete cascade,
  homework numeric(5,2) not null default 20 check (homework between 0 and 100),
  quiz numeric(5,2) not null default 20 check (quiz between 0 and 100),
  test numeric(5,2) not null default 35 check (test between 0 and 100),
  exam numeric(5,2) not null default 25 check (exam between 0 and 100),
  updated_at timestamptz not null default now(),
  check (homework + quiz + test + exam = 100)
);

create table public.notification_preferences (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  push_enabled boolean not null default false,
  provider_subscription_id text,
  updated_at timestamptz not null default now()
);

-- Security helpers avoid trusting a client-supplied role or classroom id.
create or replace function public.is_teacher_of(target_classroom uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.classrooms c where c.id = target_classroom and c.teacher_id = auth.uid());
$$;
create or replace function public.is_student_of(target_classroom uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.classroom_students cs where cs.classroom_id = target_classroom and cs.student_id = auth.uid());
$$;

alter table public.profiles enable row level security;
alter table public.classrooms enable row level security;
alter table public.classroom_students enable row level security;
alter table public.assignments enable row level security;
alter table public.submissions enable row level security;
alter table public.lessons enable row level security;
alter table public.grade_weights enable row level security;
alter table public.notification_preferences enable row level security;

-- Profiles: users can read their own profile; teachers can read linked students only.
create policy "read own profile" on public.profiles for select to authenticated using (id = auth.uid());
create policy "teacher reads linked student profile" on public.profiles for select to authenticated using (
  exists (select 1 from public.classroom_students cs join public.classrooms c on c.id = cs.classroom_id where cs.student_id = profiles.id and c.teacher_id = auth.uid())
);
create policy "user updates own display name" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy "teacher manages own classrooms" on public.classrooms for all to authenticated using (teacher_id = auth.uid()) with check (teacher_id = auth.uid());
create policy "students read linked classrooms" on public.classrooms for select to authenticated using (public.is_student_of(id));
create policy "teacher manages classroom links" on public.classroom_students for all to authenticated using (public.is_teacher_of(classroom_id)) with check (public.is_teacher_of(classroom_id));
create policy "student reads own classroom link" on public.classroom_students for select to authenticated using (student_id = auth.uid());

create policy "teacher manages assignments" on public.assignments for all to authenticated using (public.is_teacher_of(classroom_id)) with check (public.is_teacher_of(classroom_id) and created_by = auth.uid());
create policy "students read published assignments" on public.assignments for select to authenticated using (published_at is not null and public.is_student_of(classroom_id));

create policy "student reads own submissions" on public.submissions for select to authenticated using (student_id = auth.uid());
create policy "teacher reads classroom submissions" on public.submissions for select to authenticated using (exists (select 1 from public.assignments a where a.id = assignment_id and public.is_teacher_of(a.classroom_id)));
create policy "student submits own work" on public.submissions for insert to authenticated with check (student_id = auth.uid() and grade is null and graded_by is null and exists (select 1 from public.assignments a where a.id = assignment_id and a.published_at is not null and public.is_student_of(a.classroom_id)));
create policy "student updates own ungraded submission" on public.submissions for update to authenticated using (student_id = auth.uid() and grade is null) with check (student_id = auth.uid() and grade is null and graded_by is null);
create policy "teacher grades classroom submissions" on public.submissions for update to authenticated using (exists (select 1 from public.assignments a where a.id = assignment_id and public.is_teacher_of(a.classroom_id))) with check (exists (select 1 from public.assignments a where a.id = assignment_id and public.is_teacher_of(a.classroom_id)) and (grade is null or grade <= (select max_points from public.assignments where id = assignment_id)));

create policy "teacher manages lessons" on public.lessons for all to authenticated using (public.is_teacher_of(classroom_id)) with check (public.is_teacher_of(classroom_id));
create policy "students read linked lessons" on public.lessons for select to authenticated using (public.is_student_of(classroom_id));
create policy "teacher manages grade weights" on public.grade_weights for all to authenticated using (public.is_teacher_of(classroom_id)) with check (public.is_teacher_of(classroom_id));
create policy "students read grade weights" on public.grade_weights for select to authenticated using (public.is_student_of(classroom_id));
create policy "users manage own notification preferences" on public.notification_preferences for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Create a private Storage bucket named `classroom-files` in the Supabase dashboard.
-- Storage object policies must scope paths to the authenticated user/classroom. Do not make student files public.
-- Push delivery must run server-side (e.g. Edge Function); never expose provider secrets in VITE_ variables.
