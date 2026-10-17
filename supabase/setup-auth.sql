-- Run this AFTER creating both Tuto accounts in the app's sign-up screen.
-- Replace the two email placeholders before running. Safe to re-run for this one-classroom setup.

-- New sign-ups receive a basic student profile. Teacher role is promoted below by the owner.
create or replace function public.handle_new_tuto_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, role)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), split_part(new.email, '@', 1)),
    'student'::public.classroom_role
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_tuto on auth.users;
create trigger on_auth_user_created_tuto
after insert on auth.users
for each row execute procedure public.handle_new_tuto_user();

-- Backfill profile rows for accounts created before this trigger was added.
insert into public.profiles (id, display_name, role)
select u.id,
       coalesce(nullif(trim(u.raw_user_meta_data ->> 'display_name'), ''), split_part(u.email, '@', 1)),
       'student'::public.classroom_role
from auth.users u
on conflict (id) do nothing;

-- IMPORTANT: Replace both emails with the exact addresses used to sign up.
-- This first update assigns the teacher role; all other newly created accounts default to student.
update public.profiles p
set role = 'teacher'::public.classroom_role
where p.id = (select u.id from auth.users u where lower(u.email) = lower('emaanzehra127@gmail.com'));

update public.profiles p
set role = 'student'::public.classroom_role
where p.id = (select u.id from auth.users u where lower(u.email) = lower('18106dxbp@gmail.com'));

-- Create one classroom for the teacher if it does not already exist.
insert into public.classrooms (teacher_id, name, subject)
select p.id, 'Our Classroom', 'Mathematics'
from public.profiles p
join auth.users u on u.id = p.id
where lower(u.email) = lower('emaanzehra127@gmail.com')
  and p.role = 'teacher'
  and not exists (select 1 from public.classrooms c where c.teacher_id = p.id);

-- Link the student to that teacher's classroom.
insert into public.classroom_students (classroom_id, student_id)
select c.id, student.id
from public.classrooms c
join auth.users teacher_user on teacher_user.id = c.teacher_id
join auth.users student_user on lower(student_user.email) = lower('18106dxbp@gmail.com')
join public.profiles student on student.id = student_user.id and student.role = 'student'
where lower(teacher_user.email) = lower('emaanzehra127@gmail.com')
on conflict (classroom_id, student_id) do nothing;

-- Add default grade weighting for the classroom.
insert into public.grade_weights (classroom_id)
select c.id
from public.classrooms c
join auth.users u on u.id = c.teacher_id
where lower(u.email) = lower('emaanzehra127@gmail.com')
on conflict (classroom_id) do nothing;

-- Create a private bucket for worksheets and student submissions.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'classroom-files',
  'classroom-files',
  false,
  10485760,
  array['application/pdf','image/png','image/jpeg','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document']
)
on conflict (id) do update set public = false, file_size_limit = 10485760;

-- Storage access is scoped to the classroom folder in each object path.
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='Tuto members read classroom files') then
    create policy "Tuto members read classroom files" on storage.objects for select to authenticated
    using (
      bucket_id = 'classroom-files' and (
        public.is_teacher_of((storage.foldername(name))[1]::uuid)
        or (
          public.is_student_of((storage.foldername(name))[1]::uuid)
          and (
            (storage.foldername(name))[2] = 'assignments'
            or ((storage.foldername(name))[2] = 'submissions' and (storage.foldername(name))[3] = auth.uid()::text)
          )
        )
      )
    );
  end if;
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='Tuto members upload classroom files') then
    create policy "Tuto members upload classroom files" on storage.objects for insert to authenticated
    with check (
      bucket_id = 'classroom-files' and (
        (public.is_teacher_of((storage.foldername(name))[1]::uuid) and (storage.foldername(name))[2] = 'assignments')
        or (public.is_student_of((storage.foldername(name))[1]::uuid) and (storage.foldername(name))[2] = 'submissions' and (storage.foldername(name))[3] = auth.uid()::text)
      )
    );
  end if;
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='Tuto members delete own classroom files') then
    create policy "Tuto members delete own classroom files" on storage.objects for delete to authenticated
    using (
      bucket_id = 'classroom-files' and (
        (public.is_teacher_of((storage.foldername(name))[1]::uuid) and (storage.foldername(name))[2] = 'assignments')
        or (public.is_student_of((storage.foldername(name))[1]::uuid) and (storage.foldername(name))[2] = 'submissions' and (storage.foldername(name))[3] = auth.uid()::text)
      )
    );
  end if;
end $$;

-- Quick verification: should return one teacher, one student, and one classroom link.
select p.display_name, p.role, u.email
from public.profiles p
join auth.users u on u.id = p.id
where lower(u.email) in (lower('emaanzehra127@gmail.com'), lower('18106dxbp@gmail.com'));
