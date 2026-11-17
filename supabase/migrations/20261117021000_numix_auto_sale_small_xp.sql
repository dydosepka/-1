create schema if not exists numix_backup_20261117_auto_rewards;
create table if not exists numix_backup_20261117_auto_rewards.progression as table numix_private.progression;
create table if not exists numix_backup_20261117_auto_rewards.progress_events as table numix_private.progress_events;
revoke all on schema numix_backup_20261117_auto_rewards from public,anon,authenticated;
revoke all on numix_backup_20261117_auto_rewards.progression,
  numix_backup_20261117_auto_rewards.progress_events from public,anon,authenticated;

alter table numix_private.progression add column if not exists auto_sales bigint not null default 0;
update numix_private.progression p set auto_sales=(
  select count(*) from numix_private.progress_events sale
  where sale.user_id=p.user_id and sale.kind='sale' and exists(
    select 1 from numix_private.progress_events spin
    where spin.user_id=p.user_id and spin.kind='spin_auto' and spin.source_id=sale.source_id
  )
) where p.auto_sales=0;
alter table numix_private.progression drop constraint if exists numix_progress_auto_sales_nonnegative;
alter table numix_private.progression add constraint numix_progress_auto_sales_nonnegative check(auto_sales>=0);
insert into numix_private.progress_config(key,xp) values('sale_auto_ten',1)
  on conflict(key) do update set xp=excluded.xp;

create or replace function public.numix_progress_state()
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_progress numix_private.progression%rowtype;
  v_skills jsonb; v_config jsonb; v_xp_into bigint;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  insert into numix_private.progression(user_id) values(v_user) on conflict do nothing;
  select * into v_progress from numix_private.progression where user_id=v_user;
  v_xp_into:=v_progress.total_xp-v_progress.level_start_xp;
  select coalesce(jsonb_object_agg(skill,level),'{}'::jsonb) into v_skills
    from numix_private.skill_levels where user_id=v_user;
  select coalesce(jsonb_object_agg(skill,jsonb_build_object('unlock',unlock_level,'costs',costs,'effects',effects)),'{}'::jsonb)
    into v_config from numix_private.skill_config;
  return jsonb_build_object('level',v_progress.level,'total_xp',v_progress.total_xp,
    'xp_into_level',v_xp_into,'xp_needed',public.numix_xp_for_level(v_progress.level),
    'spins',v_progress.spins,'auto_spins',v_progress.auto_spins,'auto_sales',v_progress.auto_sales,'last_luck_spin',v_progress.last_luck_spin,
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
  v_rate integer; v_threshold bigint; v_is_auto_sale boolean:=false; v_new_auto_sales bigint;
  v_quest jsonb; v_item_exists boolean;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  if p_kind not in ('spin_manual','spin_auto','sale','sale_manual','sale_auto','quest') or length(coalesce(p_source_id,'')) not between 1 and 128
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
  elsif p_kind in ('sale','sale_manual','sale_auto') then
    if exists(select 1 from numix_private.progress_events where user_id=v_user
      and kind in ('sale','sale_manual','sale_auto') and source_id=p_source_id) then
      return jsonb_build_object('duplicate',true,'level',v_progress.level,
        'total_xp',v_progress.total_xp,'spins',v_progress.spins);
    end if;
    select exists(select 1 from public.user_items where user_id=v_user and id=p_source_id)
      or exists(select 1 from numix_private.progress_events where user_id=v_user and kind in ('spin_manual','spin_auto') and source_id=p_source_id)
      into v_item_exists;
    if not v_item_exists then raise exception 'item_not_owned'; end if;
    v_is_auto_sale:=p_kind='sale_auto' or (p_kind='sale' and exists(
      select 1 from numix_private.progress_events where user_id=v_user
        and kind='spin_auto' and source_id=p_source_id));
    if v_is_auto_sale then
      v_new_auto_sales:=v_progress.auto_sales+1;
      if v_new_auto_sales % 10 = 0 then
        select xp into v_xp from numix_private.progress_config where key='sale_auto_ten';
      end if;
    else
      select xp into v_xp from numix_private.progress_config where key='sale';
    end if;
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
    auto_sales=auto_sales+case when v_is_auto_sale then 1 else 0 end,
    updated_at=clock_timestamp() where user_id=v_user returning * into v_progress;
  v_threshold:=v_progress.level_start_xp+public.numix_xp_for_level(v_progress.level);
  while v_progress.total_xp >= v_threshold loop
    v_progress.level_start_xp:=v_threshold;
    v_progress.level:=v_progress.level+1;
    insert into numix_private.level_history(user_id,level) values(v_user,v_progress.level) on conflict do nothing;
    v_threshold:=v_progress.level_start_xp+public.numix_xp_for_level(v_progress.level);
  end loop;
  if v_progress.level<>v_old_level then
    update numix_private.progression set level=v_progress.level,level_start_xp=v_progress.level_start_xp where user_id=v_user;
  end if;
  return jsonb_build_object('duplicate',false,'xp_awarded',v_xp,'level',v_progress.level,
    'old_level',v_old_level,'total_xp',v_progress.total_xp,'spins',v_progress.spins);
end;
$$;
revoke all on function public.numix_record_progress_event(text,text,text) from public,anon;
grant execute on function public.numix_record_progress_event(text,text,text) to authenticated;
