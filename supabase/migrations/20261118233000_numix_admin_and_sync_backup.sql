-- Snapshot all cloud state touched by the client sync path before rollout.
create table if not exists numix_private.sync_repair_backup_20261118 (
  source text not null,
  row_data jsonb not null,
  backed_up_at timestamptz not null default clock_timestamp()
);
alter table numix_private.sync_repair_backup_20261118 enable row level security;
revoke all on numix_private.sync_repair_backup_20261118 from public,anon,authenticated;
insert into numix_private.sync_repair_backup_20261118(source,row_data)
select 'profiles',to_jsonb(t) from public.profiles t
union all select 'user_items',to_jsonb(t) from public.user_items t
union all select 'progression',to_jsonb(t) from numix_private.progression t
union all select 'numix_admins',to_jsonb(t) from public.numix_admins t;

-- Admin rights remain keyed to the verified Supabase Auth identity.
do $$
begin
  if not exists (
    select 1 from auth.users
    where lower(email)='ryslansylimov933@gmail.com'
      and email_confirmed_at is not null
  ) then raise exception 'confirmed_admin_account_required'; end if;
end $$;
insert into public.numix_admins(user_id)
select id from auth.users
where lower(email)='ryslansylimov933@gmail.com'
  and email_confirmed_at is not null
on conflict(user_id) do nothing;
