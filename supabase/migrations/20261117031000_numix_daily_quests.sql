create table if not exists numix_private.daily_quest_claims (
  user_id uuid not null references auth.users(id), quest_day date not null,
  quest_key text not null, rub_awarded bigint not null, xp_awarded integer not null,
  claimed_at timestamptz not null default clock_timestamp(),
  primary key(user_id,quest_day,quest_key)
);
create index if not exists numix_daily_quest_claims_day on numix_private.daily_quest_claims(quest_day,user_id);
alter table numix_private.daily_quest_claims enable row level security;
revoke all on numix_private.daily_quest_claims from public,anon,authenticated;

create table if not exists numix_private.daily_quest_days (
  user_id uuid not null references auth.users(id), quest_day date not null,
  activity_base bigint not null default 0, created_at timestamptz not null default clock_timestamp(),
  primary key(user_id,quest_day)
);
alter table numix_private.daily_quest_days enable row level security;
revoke all on numix_private.daily_quest_days from public,anon,authenticated;

create table if not exists numix_private.daily_gift_spins (
  user_id uuid not null references auth.users(id), spin_id text not null,
  created_at timestamptz not null default clock_timestamp(), primary key(user_id,spin_id)
);
create index if not exists numix_daily_gift_spins_day on numix_private.daily_gift_spins(user_id,created_at desc);
alter table numix_private.daily_gift_spins enable row level security;
revoke all on numix_private.daily_gift_spins from public,anon,authenticated;

create table if not exists numix_private.daily_quest_config (
  quest_key text primary key, title text not null, icon text not null,
  target_new integer not null, target_veteran integer not null,
  rub_new bigint not null, rub_veteran bigint not null,
  xp_new integer not null, xp_veteran integer not null
);
insert into numix_private.daily_quest_config values
  ('spins','Первые прокрутки','fa-solid fa-rotate',50,100,5000,15000,10,15),
  ('rare','Охотник за редкостью','fa-solid fa-gem',3,5,15000,30000,20,25),
  ('collection','Коллекционер','fa-solid fa-box-archive',10,20,25000,45000,25,30),
  ('sales','Торговец','fa-solid fa-cart-shopping',5,10,30000,50000,30,35),
  ('gifts','Любитель подарков','fa-solid fa-gift',5,10,20000,35000,20,25),
  ('activity','Активный игрок','fa-solid fa-stopwatch',1200,1800,40000,60000,40,50),
  ('epic','Мастер номеров','fa-solid fa-crown',1,2,75000,100000,50,60)
on conflict(quest_key) do update set title=excluded.title,icon=excluded.icon,
  target_new=excluded.target_new,target_veteran=excluded.target_veteran,
  rub_new=excluded.rub_new,rub_veteran=excluded.rub_veteran,
  xp_new=excluded.xp_new,xp_veteran=excluded.xp_veteran;
alter table numix_private.daily_quest_config enable row level security;
revoke all on numix_private.daily_quest_config from public,anon,authenticated;

create or replace function public.numix_record_gift_spin(p_spin_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_history jsonb; v_found boolean;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  if p_spin_id is null or length(p_spin_id) not between 4 and 80 then raise exception 'invalid_spin_id'; end if;
  select data#>'{roulette,history}' into v_history from public.profiles where id=v_user;
  select exists(select 1 from jsonb_array_elements(coalesce(v_history,'[]'::jsonb)) e
    where e->>'id'=p_spin_id and (e->>'cost')::numeric>0 and jsonb_array_length(coalesce(e->'items','[]'::jsonb))>0)
    into v_found;
  if not v_found then raise exception 'gift_spin_not_saved'; end if;
  insert into numix_private.daily_gift_spins(user_id,spin_id) values(v_user,p_spin_id)
    on conflict do nothing;
  return jsonb_build_object('recorded',true);
end $$;
revoke all on function public.numix_record_gift_spin(text) from public,anon;
grant execute on function public.numix_record_gift_spin(text) to authenticated;

create or replace function public.numix_daily_quest_state()
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_day date:=(clock_timestamp() at time zone 'UTC')::date;
  v_start timestamptz:=((clock_timestamp() at time zone 'UTC')::date)::timestamptz;
  v_level integer; v_activity bigint; v_base bigint; v_list jsonb; v_claimed integer;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  select coalesce(level,1) into v_level from numix_private.progression where user_id=v_user;
  v_level:=coalesce(v_level,1);
  select coalesce(total_seconds,0) into v_activity from numix_private.activity_totals where user_id=v_user;
  v_activity:=coalesce(v_activity,0);
  insert into numix_private.daily_quest_days(user_id,quest_day,activity_base)
    values(v_user,v_day,v_activity) on conflict do nothing;
  select activity_base into v_base from numix_private.daily_quest_days where user_id=v_user and quest_day=v_day;
  select coalesce(jsonb_agg(jsonb_build_object('key',c.quest_key,'title',c.title,'icon',c.icon,
    'target',case when v_level>=15 then c.target_veteran else c.target_new end,
    'rub',case when v_level>=15 then c.rub_veteran else c.rub_new end,
    'xp',case when v_level>=15 then c.xp_veteran else c.xp_new end,
    'progress',case c.quest_key
      when 'spins' then (select count(*) from numix_private.progress_events e where e.user_id=v_user and e.created_at>=v_start and e.kind in ('spin_manual','spin_auto'))
      when 'rare' then (select count(*) from numix_private.progress_events e where e.user_id=v_user and e.created_at>=v_start and e.kind in ('spin_manual','spin_auto') and e.rarity_key in ('rare','epic','legendary','mythic','ultra','secret','black'))
      when 'collection' then (select count(*) from public.user_items i where i.user_id=v_user and i.updated_at>=v_start)
      when 'sales' then (select count(*) from numix_private.progress_events e where e.user_id=v_user and e.created_at>=v_start and e.kind in ('sale','sale_manual','sale_auto'))
      when 'gifts' then (select count(*) from numix_private.daily_gift_spins g where g.user_id=v_user and g.created_at>=v_start)
      when 'activity' then greatest(0,v_activity-v_base)
      when 'epic' then (select count(*) from numix_private.progress_events e where e.user_id=v_user and e.created_at>=v_start and e.kind in ('spin_manual','spin_auto') and e.rarity_key in ('epic','legendary','mythic','ultra','secret','black'))
      end,
    'claimed',exists(select 1 from numix_private.daily_quest_claims q where q.user_id=v_user and q.quest_day=v_day and q.quest_key=c.quest_key)
  ) order by c.quest_key),'[]'::jsonb) into v_list from numix_private.daily_quest_config c;
  select count(*) into v_claimed from numix_private.daily_quest_claims where user_id=v_user and quest_day=v_day and quest_key<>'bonus';
  return jsonb_build_object('day',v_day,'reset_at',(v_start+interval '1 day'),
    'quests',v_list,'claimed_count',v_claimed,'bonus_claimed',exists(
      select 1 from numix_private.daily_quest_claims where user_id=v_user and quest_day=v_day and quest_key='bonus'));
end $$;
revoke all on function public.numix_daily_quest_state() from public,anon;
grant execute on function public.numix_daily_quest_state() to authenticated;

create or replace function public.numix_claim_daily_quest(p_key text,p_expected_revision bigint)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_day date:=(clock_timestamp() at time zone 'UTC')::date;
  v_state jsonb; v_entry jsonb; v_profile public.profiles%rowtype;
  v_progress numix_private.progression%rowtype; v_rub bigint; v_xp integer; v_revision bigint;
  v_old_level integer; v_threshold bigint;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  if p_key not in ('spins','rare','collection','sales','gifts','activity','epic','bonus') then raise exception 'invalid_quest'; end if;
  select * into v_profile from public.profiles where id=v_user for update;
  if not found or v_profile.save_revision<>p_expected_revision then raise exception 'save_revision_conflict'; end if;
  if exists(select 1 from numix_private.daily_quest_claims where user_id=v_user and quest_day=v_day and quest_key=p_key)
    then raise exception 'quest_already_claimed'; end if;
  v_state:=public.numix_daily_quest_state();
  if p_key='bonus' then
    if (v_state->>'claimed_count')::integer<>7 then raise exception 'quests_not_completed'; end if;
    v_rub:=100000; v_xp:=100;
  else
    select e into v_entry from jsonb_array_elements(v_state->'quests') e where e->>'key'=p_key;
    if v_entry is null or (v_entry->>'progress')::numeric<(v_entry->>'target')::numeric
      then raise exception 'quest_not_completed'; end if;
    v_rub:=(v_entry->>'rub')::bigint; v_xp:=(v_entry->>'xp')::integer;
  end if;
  insert into numix_private.daily_quest_claims(user_id,quest_day,quest_key,rub_awarded,xp_awarded)
    values(v_user,v_day,p_key,v_rub,v_xp);
  update public.profiles set balance=coalesce(balance,0)+v_rub,
    data=jsonb_set(data,'{state,balance}',to_jsonb(coalesce(balance,0)+v_rub)),
    save_revision=save_revision+1,updated_at=clock_timestamp()
    where id=v_user returning save_revision into v_revision;
  insert into numix_private.progression(user_id) values(v_user) on conflict do nothing;
  select * into v_progress from numix_private.progression where user_id=v_user for update;
  v_old_level:=v_progress.level;
  update numix_private.progression set total_xp=total_xp+v_xp,updated_at=clock_timestamp()
    where user_id=v_user returning * into v_progress;
  insert into numix_private.progress_events(user_id,kind,source_id,xp_awarded)
    values(v_user,'daily_quest',v_day::text||':'||p_key,v_xp);
  v_threshold:=v_progress.level_start_xp+public.numix_xp_for_level(v_progress.level);
  while v_progress.total_xp>=v_threshold loop
    v_progress.level_start_xp:=v_threshold; v_progress.level:=v_progress.level+1;
    insert into numix_private.level_history(user_id,level) values(v_user,v_progress.level) on conflict do nothing;
    v_threshold:=v_progress.level_start_xp+public.numix_xp_for_level(v_progress.level);
  end loop;
  if v_progress.level<>v_old_level then
    update numix_private.progression set level=v_progress.level,level_start_xp=v_progress.level_start_xp where user_id=v_user;
  end if;
  return jsonb_build_object('rub',v_rub,'xp',v_xp,'level',v_progress.level,'revision',v_revision);
end $$;
revoke all on function public.numix_claim_daily_quest(text,bigint) from public,anon;
grant execute on function public.numix_claim_daily_quest(text,bigint) to authenticated;
