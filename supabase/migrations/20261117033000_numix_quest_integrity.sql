alter table numix_private.daily_quest_days add column if not exists gift_history_baseline jsonb not null default '[]'::jsonb;

create or replace function numix_private.capture_daily_activity()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_day date:=(clock_timestamp() at time zone 'UTC')::date; v_history jsonb;
begin
  select coalesce(data#>'{roulette,history}','[]'::jsonb) into v_history from public.profiles where id=new.user_id;
  insert into numix_private.daily_quest_days(user_id,quest_day,activity_base,gift_history_baseline)
    values(new.user_id,v_day,old.total_seconds,coalesce(v_history,'[]'::jsonb)) on conflict do nothing;
  return new;
end $$;
drop trigger if exists numix_capture_daily_activity on numix_private.activity_totals;
create trigger numix_capture_daily_activity before update of total_seconds on numix_private.activity_totals
  for each row when (new.total_seconds>old.total_seconds) execute function numix_private.capture_daily_activity();

create or replace function public.numix_record_gift_spin(p_spin_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_history jsonb; v_found boolean; v_day date:=(clock_timestamp() at time zone 'UTC')::date;
  v_baseline jsonb;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  if p_spin_id is null or length(p_spin_id) not between 4 and 80 then raise exception 'invalid_spin_id'; end if;
  select data#>'{roulette,history}' into v_history from public.profiles where id=v_user;
  select exists(select 1 from jsonb_array_elements(coalesce(v_history,'[]'::jsonb)) e
    where e->>'id'=p_spin_id and (e->>'cost')::numeric>0 and jsonb_array_length(coalesce(e->'items','[]'::jsonb))>0)
    into v_found;
  if not v_found then raise exception 'gift_spin_not_saved'; end if;
  select gift_history_baseline into v_baseline from numix_private.daily_quest_days
    where user_id=v_user and quest_day=v_day;
  if v_baseline is null then raise exception 'daily_quests_not_initialized'; end if;
  if exists(select 1 from jsonb_array_elements(v_baseline) e where e->>'id'=p_spin_id)
    then raise exception 'gift_spin_from_previous_day'; end if;
  insert into numix_private.daily_gift_spins(user_id,spin_id) values(v_user,p_spin_id)
    on conflict do nothing;
  return jsonb_build_object('recorded',true);
end $$;
revoke all on function public.numix_record_gift_spin(text) from public,anon;
grant execute on function public.numix_record_gift_spin(text) to authenticated;

-- The original daily quest function is retained; this wrapper initialises a
-- baseline before the user starts a roulette session in the new interface.
create or replace function public.numix_init_daily_quests()
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_day date:=(clock_timestamp() at time zone 'UTC')::date;
  v_history jsonb; v_activity bigint;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  select coalesce(data#>'{roulette,history}','[]'::jsonb) into v_history from public.profiles where id=v_user;
  select coalesce(total_seconds,0) into v_activity from numix_private.activity_totals where user_id=v_user;
  insert into numix_private.daily_quest_days(user_id,quest_day,activity_base,gift_history_baseline)
    values(v_user,v_day,coalesce(v_activity,0),coalesce(v_history,'[]'::jsonb)) on conflict do nothing;
  return public.numix_daily_quest_state();
end $$;
revoke all on function public.numix_init_daily_quests() from public,anon;
grant execute on function public.numix_init_daily_quests() to authenticated;

-- All five upgrades remove the configured base system commission, including
-- when the administrator changes that base rate.
create or replace function public.numix_system_sale_quote(p_ids text[])
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_data jsonb; v_id text; v_item jsonb;
  v_fee_bps numeric; v_trade integer; v_no_fee integer; v_rate numeric;
  v_currency text; v_base numeric; v_boosted numeric; v_fee numeric; v_payout numeric;
  v_rows jsonb:='[]'::jsonb; v_gross jsonb:='{}'::jsonb; v_fees jsonb:='{}'::jsonb; v_payouts jsonb:='{}'::jsonb;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  if p_ids is null or cardinality(p_ids)<1 or cardinality(p_ids)>500
    or cardinality(p_ids)<>(select count(distinct x) from unnest(p_ids) x)
    then raise exception 'invalid_sale_items'; end if;
  select data into v_data from public.profiles where id=v_user;
  if v_data is null then raise exception 'profile_required'; end if;
  select value into v_fee_bps from numix_private.market_config where key='system_fee_bps';
  select coalesce(level,0) into v_trade from numix_private.skill_levels where user_id=v_user and skill='trade';
  select coalesce(level,0) into v_no_fee from numix_private.skill_levels where user_id=v_user and skill='no_fee';
  v_trade:=coalesce(v_trade,0); v_no_fee:=coalesce(v_no_fee,0);
  v_rate:=greatest(0,v_fee_bps*(5-v_no_fee)/5);
  foreach v_id in array p_ids loop
    select e into v_item from jsonb_array_elements(coalesce(v_data#>'{state,collection}','[]'::jsonb)) e where e->>'id'=v_id limit 1;
    if v_item is null or not exists(select 1 from public.user_items where id=v_id and user_id=v_user)
      then raise exception 'item_not_owned'; end if;
    if exists(select 1 from numix_private.market_lots where kind='number' and item_id=v_id and status='active')
      then raise exception 'item_listed'; end if;
    v_currency:=case when v_item->>'currency' in ('ton','usd') then v_item->>'currency'
      when v_item->>'rarityKey'='secret' then 'usd' else 'rub' end;
    v_base:=(v_item->>'price')::numeric;
    if v_base is null or v_base<0 or v_base>100000000000000 then raise exception 'invalid_item_price'; end if;
    v_boosted:=v_base*(1+v_trade/100.0);
    v_fee:=case when v_currency='ton' then round(v_boosted*v_rate/10000,2)
      else floor(v_boosted*v_rate/10000) end;
    v_payout:=case when v_currency='ton' then round(v_boosted-v_fee,2)
      else floor(v_boosted-v_fee) end;
    v_rows:=v_rows||jsonb_build_array(jsonb_build_object('id',v_id,'number',v_item->>'formattedNumber',
      'currency',v_currency,'price',v_base,'trade_percent',v_trade,
      'fee_percent',v_rate/100,'fee',v_fee,'payout',v_payout));
    v_gross:=jsonb_set(v_gross,array[v_currency],to_jsonb(coalesce((v_gross->>v_currency)::numeric,0)+v_base),true);
    v_fees:=jsonb_set(v_fees,array[v_currency],to_jsonb(coalesce((v_fees->>v_currency)::numeric,0)+v_fee),true);
    v_payouts:=jsonb_set(v_payouts,array[v_currency],to_jsonb(coalesce((v_payouts->>v_currency)::numeric,0)+v_payout),true);
  end loop;
  return jsonb_build_object('items',v_rows,'gross',v_gross,'fee',v_fees,'payout',v_payouts,'fee_percent',v_rate/100);
end $$;
revoke all on function public.numix_system_sale_quote(text[]) from public,anon;
grant execute on function public.numix_system_sale_quote(text[]) to authenticated;
