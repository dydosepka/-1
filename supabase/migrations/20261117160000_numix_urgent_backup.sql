-- Snapshot immediately before the urgent sale and luck fixes.
create table if not exists numix_private.urgent_backup_20261117 (
  id bigint generated always as identity primary key,
  source text not null,
  record jsonb not null,
  captured_at timestamptz not null default clock_timestamp()
);
alter table numix_private.urgent_backup_20261117 enable row level security;
revoke all on numix_private.urgent_backup_20261117 from public,anon,authenticated;
insert into numix_private.urgent_backup_20261117(source,record)
select 'profiles',to_jsonb(t) from public.profiles t
union all select 'user_items',to_jsonb(t) from public.user_items t
union all select 'progression',to_jsonb(t) from numix_private.progression t
union all select 'market_sales',to_jsonb(t) from numix_private.market_sales t
union all select 'skill_levels',to_jsonb(t) from numix_private.skill_levels t
union all select 'luck_weights',to_jsonb(t) from numix_private.luck_weights t
union all select 'save_function',jsonb_build_object('definition',pg_get_functiondef('public.save_numix_progress(bigint,jsonb,jsonb)'::regprocedure))
union all select 'luck_function',jsonb_build_object('definition',pg_get_functiondef('public.numix_luck_roll()'::regprocedure));
