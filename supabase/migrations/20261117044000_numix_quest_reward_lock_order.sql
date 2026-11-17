-- Progression is always locked before the profile, matching progress-event batches.
-- NO KEY UPDATE allows the profile foreign-key check in progress_events to proceed.
create or replace function public.numix_claim_daily_quest(p_key text,p_expected_revision bigint)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_day date:=(clock_timestamp() at time zone 'UTC')::date;
  v_state jsonb; v_entry jsonb; v_profile public.profiles%rowtype;
  v_progress numix_private.progression%rowtype; v_claim numix_private.daily_quest_claims%rowtype;
  v_rub bigint; v_xp integer; v_revision bigint; v_old_level integer; v_threshold bigint;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  if p_key not in ('spins','rare','collection','sales','gifts','activity','epic','bonus') then raise exception 'invalid_quest'; end if;

  insert into numix_private.progression(user_id) values(v_user) on conflict do nothing;
  select * into v_progress from numix_private.progression where user_id=v_user for update;
  select * into v_profile from public.profiles where id=v_user for no key update;
  if not found then raise exception 'profile_not_found'; end if;

  select * into v_claim from numix_private.daily_quest_claims
    where user_id=v_user and quest_day=v_day and quest_key=p_key;
  if found then
    return jsonb_build_object('rub',v_claim.rub_awarded,'xp',v_claim.xp_awarded,
      'level',v_progress.level,'revision',v_profile.save_revision,'duplicate',true);
  end if;
  if v_profile.save_revision is distinct from p_expected_revision then raise exception 'save_revision_conflict'; end if;

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
    data=jsonb_set(coalesce(data,'{}'::jsonb),'{state,balance}',to_jsonb(coalesce(balance,0)+v_rub),true),
    save_revision=save_revision+1,updated_at=clock_timestamp()
    where id=v_user returning save_revision into v_revision;
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
  return jsonb_build_object('rub',v_rub,'xp',v_xp,'level',v_progress.level,
    'revision',v_revision,'duplicate',false);
end $$;

create or replace function public.numix_buy_skill(p_skill text, p_request_id uuid, p_expected_revision bigint)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
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
  select * into v_progress from numix_private.progression where user_id=v_user for update;
  if not found then raise exception 'progress_not_initialized'; end if;
  select * into v_profile from public.profiles where id=v_user for no key update;
  if not found or v_profile.save_revision is distinct from p_expected_revision then raise exception 'save_revision_conflict'; end if;
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
end $$;

revoke all on function public.numix_claim_daily_quest(text,bigint) from public,anon;
grant execute on function public.numix_claim_daily_quest(text,bigint) to authenticated;
revoke all on function public.numix_buy_skill(text,uuid,bigint) from public,anon;
grant execute on function public.numix_buy_skill(text,uuid,bigint) to authenticated;
