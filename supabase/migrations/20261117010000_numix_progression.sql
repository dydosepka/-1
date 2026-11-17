create schema if not exists numix_backup_20261117_progression;
create table if not exists numix_backup_20261117_progression.profiles as table public.profiles;
create table if not exists numix_backup_20261117_progression.user_items as table public.user_items;
revoke all on schema numix_backup_20261117_progression from public,anon,authenticated;
revoke all on numix_backup_20261117_progression.profiles,numix_backup_20261117_progression.user_items
  from public,anon,authenticated;
create table if not exists numix_private.progression (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  total_xp bigint not null default 0 check (total_xp >= 0),
  level integer not null default 1 check (level >= 1),
  spins bigint not null default 0 check (spins >= 0),
  auto_spins bigint not null default 0 check (auto_spins >= 0),
  last_luck_spin bigint not null default 0,
  updated_at timestamptz not null default now()
);
create table if not exists numix_private.progress_events (
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null,
  source_id text not null,
  rarity_key text,
  xp_awarded integer not null,
  created_at timestamptz not null default now(),
  primary key (user_id,kind,source_id)
);
create index if not exists numix_progress_events_rate_idx on numix_private.progress_events(user_id,kind,created_at desc);
create table if not exists numix_private.skill_levels (
  user_id uuid not null references public.profiles(id) on delete cascade,
  skill text not null check (skill in ('luck','trade','speed','collector','greater_luck')),
  level integer not null check (level between 1 and 5),
  updated_at timestamptz not null default now(),
  primary key (user_id,skill)
);
create table if not exists numix_private.skill_purchases (
  request_id uuid primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  skill text not null,
  level integer not null,
  cost numeric not null,
  ton_after numeric not null,
  revision bigint not null,
  created_at timestamptz not null default now()
);
create index if not exists numix_skill_purchases_user_idx on numix_private.skill_purchases(user_id,created_at desc);
create table if not exists numix_private.level_history (
  user_id uuid not null references public.profiles(id) on delete cascade,
  level integer not null,
  reached_at timestamptz not null default now(),
  primary key (user_id,level)
);
create table if not exists numix_private.progress_config (
  key text primary key,
  xp integer not null check (xp >= 0)
);
insert into numix_private.progress_config(key,xp) values
  ('spin_manual',1),('spin_auto_ten',5),('rare_epic',15),
  ('rare_legendary',35),('rare_mythic',75),('sale',5),('quest',20)
on conflict (key) do nothing;
create table if not exists numix_private.skill_config (
  skill text primary key,
  unlock_level integer not null,
  costs integer[] not null,
  effects integer[] not null
);
insert into numix_private.skill_config(skill,unlock_level,costs,effects) values
  ('luck',5,array[200,350,550,850,1300],array[80,70,60,50,40]),
  ('trade',10,array[200,350,550,850,1300],array[1,2,3,4,5]),
  ('speed',15,array[200,350,550,850,1300],array[5,10,15,20,25]),
  ('collector',20,array[200,350,550,850,1300],array[100,200,300,400,500]),
  ('greater_luck',25,array[200,350,550,850,1300],array[5,10,15,20,25])
on conflict (skill) do nothing;
create table if not exists numix_private.luck_weights (
  rarity_key text primary key,
  base_weight numeric not null check (base_weight >= 0),
  boostable boolean not null default false,
  max_weight numeric not null check (max_weight >= 0)
);
insert into numix_private.luck_weights(rarity_key,base_weight,boostable,max_weight) values
  ('common',80,false,80),('uncommon',15,false,15),('rare',4.6,false,4.6),
  ('epic',0.35,true,0.70),('legendary',0.045,true,0.09),('mythic',0.005,true,0.01)
on conflict (rarity_key) do nothing;
revoke all on numix_private.progression,numix_private.progress_events,numix_private.skill_levels,
  numix_private.skill_purchases,numix_private.level_history,numix_private.progress_config,
  numix_private.skill_config,numix_private.luck_weights from public,anon,authenticated;
alter table numix_private.progression enable row level security;
alter table numix_private.progress_events enable row level security;
alter table numix_private.skill_levels enable row level security;
alter table numix_private.skill_purchases enable row level security;
alter table numix_private.level_history enable row level security;
alter table numix_private.progress_config enable row level security;
alter table numix_private.skill_config enable row level security;
alter table numix_private.luck_weights enable row level security;

create or replace function public.numix_xp_for_level(p_level integer)
returns integer language sql immutable set search_path=pg_catalog as $$
  select greatest(100,(
    round((100 + 25.0 * (greatest(p_level,1)-1) * (greatest(p_level,1)+2) / 2)
      / (1 + 0.035 * greatest(p_level-5,0)) / 25) * 25
  )::integer)
$$;
revoke all on function public.numix_xp_for_level(integer) from public,anon;
grant execute on function public.numix_xp_for_level(integer) to authenticated;

create or replace function public.numix_progress_state()
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_progress numix_private.progression%rowtype;
  v_skills jsonb; v_config jsonb; v_xp_into bigint; v_level_start bigint:=0; v_i integer;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  insert into numix_private.progression(user_id) values(v_user) on conflict do nothing;
  select * into v_progress from numix_private.progression where user_id=v_user;
  for v_i in 1..(v_progress.level-1) loop v_level_start:=v_level_start+public.numix_xp_for_level(v_i); end loop;
  v_xp_into:=v_progress.total_xp-v_level_start;
  select coalesce(jsonb_object_agg(skill,level),'{}'::jsonb) into v_skills
    from numix_private.skill_levels where user_id=v_user;
  select coalesce(jsonb_object_agg(skill,jsonb_build_object('unlock',unlock_level,'costs',costs,'effects',effects)),'{}'::jsonb)
    into v_config from numix_private.skill_config;
  return jsonb_build_object('level',v_progress.level,'total_xp',v_progress.total_xp,
    'xp_into_level',v_xp_into,'xp_needed',public.numix_xp_for_level(v_progress.level),
    'spins',v_progress.spins,'auto_spins',v_progress.auto_spins,'last_luck_spin',v_progress.last_luck_spin,
    'skills',v_skills,'config',v_config);
end;
$$;
revoke all on function public.numix_progress_state() from public,anon;
grant execute on function public.numix_progress_state() to authenticated;

create or replace function public.numix_record_progress_event(
  p_kind text,p_source_id text,p_rarity text default null
) returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_progress numix_private.progression%rowtype;
  v_xp integer:=0; v_rare integer:=0; v_new_auto bigint; v_old_level integer;
  v_rate integer; v_threshold bigint;
  v_quest jsonb; v_item_exists boolean;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  if p_kind not in ('spin_manual','spin_auto','sale','quest') or length(coalesce(p_source_id,'')) not between 1 and 128
    then raise exception 'invalid_progress_event'; end if;
  insert into numix_private.progression(user_id) values(v_user) on conflict do nothing;
  select * into v_progress from numix_private.progression where user_id=v_user for update;
  if exists(select 1 from numix_private.progress_events where user_id=v_user and kind=p_kind and source_id=p_source_id) then
    return jsonb_build_object('duplicate',true,'level',v_progress.level,'total_xp',v_progress.total_xp,'spins',v_progress.spins);
  end if;
  if p_kind in ('spin_manual','spin_auto') then
    if p_source_id !~ '^num_[a-zA-Z0-9_]+$' then raise exception 'invalid_spin_id'; end if;
    if exists(select 1 from numix_private.progress_events where user_id=v_user and kind in ('spin_manual','spin_auto') and source_id=p_source_id)
      then raise exception 'duplicate_spin'; end if;
    select count(*) into v_rate from numix_private.progress_events where user_id=v_user and kind=p_kind
      and created_at>clock_timestamp()-interval '1 minute';
    if v_rate >= (case when p_kind='spin_auto' then 1200 else 120 end) then raise exception 'spin_rate_limit'; end if;
    if p_kind='spin_manual' then select xp into v_xp from numix_private.progress_config where key='spin_manual';
    else
      v_new_auto:=v_progress.auto_spins+1;
      if v_new_auto % 10 = 0 then select xp into v_xp from numix_private.progress_config where key='spin_auto_ten'; end if;
    end if;
    if p_rarity in ('epic','legendary','mythic') then
      select xp into v_rare from numix_private.progress_config where key='rare_'||p_rarity;
      v_xp:=coalesce(v_xp,0)+coalesce(v_rare,0);
    end if;
  elsif p_kind='sale' then
    select exists(select 1 from public.user_items where user_id=v_user and id=p_source_id)
      or exists(select 1 from numix_private.progress_events where user_id=v_user and kind in ('spin_manual','spin_auto') and source_id=p_source_id)
      into v_item_exists;
    if not v_item_exists then raise exception 'item_not_owned'; end if;
    select xp into v_xp from numix_private.progress_config where key='sale';
  else
    select data #> '{state,quests}' into v_quest from public.profiles where id=v_user;
    if coalesce(v_quest->>'dailyGiftClaimed','false') <> 'true'
      or p_source_id <> coalesce(v_quest->>'lastResetAt','') then raise exception 'quest_not_completed'; end if;
    select xp into v_xp from numix_private.progress_config where key='quest';
  end if;
  v_xp:=coalesce(v_xp,0);
  insert into numix_private.progress_events(user_id,kind,source_id,rarity_key,xp_awarded)
    values(v_user,p_kind,p_source_id,p_rarity,v_xp);
  v_old_level:=v_progress.level;
  update numix_private.progression set total_xp=total_xp+v_xp,
    spins=spins+case when p_kind in ('spin_manual','spin_auto') then 1 else 0 end,
    auto_spins=auto_spins+case when p_kind='spin_auto' then 1 else 0 end,
    updated_at=clock_timestamp() where user_id=v_user returning * into v_progress;
  select coalesce(sum(public.numix_xp_for_level(n)),0) into v_threshold
    from generate_series(1,v_progress.level) n;
  while v_progress.total_xp >= v_threshold loop
    v_progress.level:=v_progress.level+1;
    insert into numix_private.level_history(user_id,level) values(v_user,v_progress.level) on conflict do nothing;
    v_threshold:=v_threshold+public.numix_xp_for_level(v_progress.level);
  end loop;
  if v_progress.level<>v_old_level then
    update numix_private.progression set level=v_progress.level where user_id=v_user;
  end if;
  return jsonb_build_object('duplicate',false,'xp_awarded',v_xp,'level',v_progress.level,
    'old_level',v_old_level,'total_xp',v_progress.total_xp,'spins',v_progress.spins);
end;
$$;
revoke all on function public.numix_record_progress_event(text,text,text) from public,anon;
grant execute on function public.numix_record_progress_event(text,text,text) to authenticated;

create or replace function public.numix_buy_skill(p_skill text,p_request_id uuid,p_expected_revision bigint)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_profile public.profiles%rowtype; v_progress numix_private.progression%rowtype;
  v_config numix_private.skill_config%rowtype; v_current integer; v_cost integer; v_after numeric;
  v_previous numix_private.skill_purchases%rowtype; v_revision bigint;
begin
  if v_user is null or p_request_id is null then raise exception 'authentication_required'; end if;
  select * into v_previous from numix_private.skill_purchases where request_id=p_request_id;
  if found then
    if v_previous.user_id<>v_user or v_previous.skill<>p_skill then raise exception 'request_id_conflict'; end if;
    return jsonb_build_object('skill',p_skill,'level',v_previous.level,'cost',v_previous.cost,
      'ton_balance',v_previous.ton_after,'new_revision',v_previous.revision,'duplicate',true);
  end if;
  select * into v_profile from public.profiles where id=v_user for update;
  if not found or v_profile.save_revision<>p_expected_revision then raise exception 'save_revision_conflict'; end if;
  select * into v_progress from numix_private.progression where user_id=v_user for update;
  if not found then raise exception 'progress_not_initialized'; end if;
  select * into v_config from numix_private.skill_config where skill=p_skill;
  if not found then raise exception 'unknown_skill'; end if;
  if v_progress.level<v_config.unlock_level then raise exception 'skill_level_locked'; end if;
  select coalesce(level,0) into v_current from numix_private.skill_levels where user_id=v_user and skill=p_skill;
  v_current:=coalesce(v_current,0);
  if v_current>=5 then raise exception 'skill_maxed'; end if;
  v_cost:=v_config.costs[v_current+1];
  if v_profile.ton_balance<v_cost then raise exception 'insufficient_ton'; end if;
  v_after:=v_profile.ton_balance-v_cost;
  update public.profiles set ton_balance=v_after,
    data=jsonb_set(coalesce(data,'{}'::jsonb),'{state,tonBalance}',to_jsonb(v_after),true),
    save_revision=save_revision+1,updated_at=clock_timestamp()
    where id=v_user returning save_revision into v_revision;
  insert into numix_private.skill_levels(user_id,skill,level) values(v_user,p_skill,v_current+1)
    on conflict(user_id,skill) do update set level=excluded.level,updated_at=clock_timestamp();
  insert into numix_private.skill_purchases(request_id,user_id,skill,level,cost,ton_after,revision)
    values(p_request_id,v_user,p_skill,v_current+1,v_cost,v_after,v_revision);
  return jsonb_build_object('skill',p_skill,'level',v_current+1,'cost',v_cost,
    'ton_balance',v_after,'new_revision',v_revision,'duplicate',false);
end;
$$;
revoke all on function public.numix_buy_skill(text,uuid,bigint) from public,anon;
grant execute on function public.numix_buy_skill(text,uuid,bigint) to authenticated;

create or replace function public.numix_luck_roll()
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_progress numix_private.progression%rowtype;
  v_luck integer; v_greater integer; v_interval integer; v_mult integer;
  v_total numeric; v_draw numeric; v_running numeric:=0; v_row record; v_rarity text;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  select * into v_progress from numix_private.progression where user_id=v_user for update;
  select level into v_luck from numix_private.skill_levels where user_id=v_user and skill='luck';
  select level into v_greater from numix_private.skill_levels where user_id=v_user and skill='greater_luck';
  if coalesce(v_luck,0)<1 then raise exception 'luck_locked'; end if;
  select effects[v_luck] into v_interval from numix_private.skill_config where skill='luck';
  if v_progress.spins-v_progress.last_luck_spin<v_interval then raise exception 'luck_not_ready'; end if;
  v_mult:=case when coalesce(v_greater,0)>0 then v_greater*5 else 1 end;
  select sum(case when boostable then least(max_weight,base_weight+(v_mult-1)*base_weight*0.04)
    else base_weight end) into v_total from numix_private.luck_weights;
  v_draw:=random()*v_total;
  for v_row in select rarity_key,case when boostable then least(max_weight,base_weight+(v_mult-1)*base_weight*0.04)
      else base_weight end as weight from numix_private.luck_weights order by
      case rarity_key when 'common' then 1 when 'uncommon' then 2 when 'rare' then 3
        when 'epic' then 4 when 'legendary' then 5 else 6 end loop
    v_running:=v_running+v_row.weight;
    if v_draw<v_running then v_rarity:=v_row.rarity_key; exit; end if;
  end loop;
  update numix_private.progression set last_luck_spin=spins,updated_at=clock_timestamp() where user_id=v_user;
  return jsonb_build_object('rarity',coalesce(v_rarity,'rare'),'interval',v_interval,
    'spins',v_progress.spins,'multiplier',v_mult);
end;
$$;
revoke all on function public.numix_luck_roll() from public,anon;
grant execute on function public.numix_luck_roll() to authenticated;
