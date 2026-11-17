-- Private, read-only recovery snapshot taken before changing the reward RPC.
create table if not exists numix_private.quest_reward_backup_20261117 (
  source text not null,
  record jsonb not null,
  captured_at timestamptz not null default clock_timestamp()
);
alter table numix_private.quest_reward_backup_20261117 enable row level security;
revoke all on numix_private.quest_reward_backup_20261117 from public, anon, authenticated;

insert into numix_private.quest_reward_backup_20261117(source,record)
select 'profiles',to_jsonb(p) from public.profiles p
union all select 'progression',to_jsonb(p) from numix_private.progression p
union all select 'daily_quest_claims',to_jsonb(c) from numix_private.daily_quest_claims c
union all select 'daily_quest_events',to_jsonb(e) from numix_private.progress_events e where e.kind='daily_quest'
union all select 'claim_function',jsonb_build_object('definition',pg_get_functiondef('public.numix_claim_daily_quest(text,bigint)'::regprocedure))
union all select 'skill_function',jsonb_build_object('definition',pg_get_functiondef('public.numix_buy_skill(text,uuid,bigint)'::regprocedure));
