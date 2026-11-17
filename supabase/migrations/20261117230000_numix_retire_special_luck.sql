-- Archive every row and both callable definitions before retiring special luck.
-- Existing progression, skill levels, costs, and historical rolls stay intact.
create table if not exists numix_private.luck_retirement_backup_20261117 (
  source text not null,
  row_data jsonb not null,
  backed_up_at timestamptz not null default clock_timestamp()
);
alter table numix_private.luck_retirement_backup_20261117 enable row level security;
revoke all on numix_private.luck_retirement_backup_20261117 from public, anon, authenticated;

insert into numix_private.luck_retirement_backup_20261117(source,row_data)
select 'progression',to_jsonb(t) from numix_private.progression t
union all select 'skill_levels',to_jsonb(t) from numix_private.skill_levels t
union all select 'skill_config',to_jsonb(t) from numix_private.skill_config t
union all select 'luck_weights',to_jsonb(t) from numix_private.luck_weights t
union all select 'luck_rolls',to_jsonb(t) from numix_private.luck_rolls t
union all select 'luck_function',jsonb_build_object('definition',pg_get_functiondef('public.numix_luck_roll()'::regprocedure))
union all select 'auto_luck_function',jsonb_build_object('definition',pg_get_functiondef('public.numix_luck_roll_auto(text)'::regprocedure));

revoke execute on function public.numix_luck_roll() from public, anon, authenticated;
revoke execute on function public.numix_luck_roll_auto(text) from public, anon, authenticated;
