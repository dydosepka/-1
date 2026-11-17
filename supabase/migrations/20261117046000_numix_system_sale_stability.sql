-- Preserve the existing sale quote and economy while avoiding repeated JSON scans.
create or replace function public.numix_system_sale_quote(p_ids text[])
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_data jsonb; v_item_map jsonb; v_id text; v_item jsonb;
  v_fee_bps numeric; v_trade integer; v_no_fee integer; v_rate numeric;
  v_currency text; v_base numeric; v_boosted numeric; v_fee numeric; v_payout numeric;
  v_rows jsonb:='[]'::jsonb; v_gross jsonb:='{}'::jsonb; v_fees jsonb:='{}'::jsonb; v_payouts jsonb:='{}'::jsonb;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  if p_ids is null or cardinality(p_ids)<1 or cardinality(p_ids)>2500
    or cardinality(p_ids)<>(select count(distinct x) from unnest(p_ids) x)
    then raise exception 'invalid_sale_items'; end if;
  select data into v_data from public.profiles where id=v_user;
  if v_data is null then raise exception 'profile_required'; end if;
  select coalesce(jsonb_object_agg(e.value->>'id',e.value),'{}'::jsonb) into v_item_map
    from jsonb_array_elements(coalesce(v_data#>'{state,collection}','[]'::jsonb)) e
    where nullif(e.value->>'id','') is not null;
  select value into v_fee_bps from numix_private.market_config where key='system_fee_bps';
  select coalesce(level,0) into v_trade from numix_private.skill_levels where user_id=v_user and skill='trade';
  select coalesce(level,0) into v_no_fee from numix_private.skill_levels where user_id=v_user and skill='no_fee';
  v_trade:=coalesce(v_trade,0); v_no_fee:=coalesce(v_no_fee,0);
  v_rate:=greatest(0,v_fee_bps*(5-v_no_fee)/5);
  foreach v_id in array p_ids loop
    v_item:=v_item_map->v_id;
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

-- All XP writers now lock progression first. Profile is locked in NO KEY UPDATE
-- mode so progress_events' foreign-key KEY SHARE cannot form a deadlock cycle.
create or replace function public.numix_system_sell(p_ids text[],p_request_id uuid,p_expected_revision bigint)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_profile public.profiles%rowtype; v_progress numix_private.progression%rowtype;
  v_quote jsonb; v_previous numix_private.market_sales%rowtype;
  v_rub numeric; v_usd numeric; v_ton numeric; v_revision bigint; v_items jsonb; v_favs jsonb;
  v_state jsonb; v_data jsonb; v_sale_xp integer; v_total_xp bigint; v_old_level integer; v_threshold bigint;
begin
  if v_user is null or p_request_id is null then raise exception 'authentication_required'; end if;
  select * into v_previous from numix_private.market_sales where request_id=p_request_id;
  if found then
    if v_previous.seller_id<>v_user or v_previous.item_ids<>p_ids then raise exception 'request_id_conflict'; end if;
    return jsonb_build_object('revision',v_previous.revision,'gross',v_previous.gross,
      'fee',v_previous.fee,'payout',v_previous.payout,'duplicate',true);
  end if;
  insert into numix_private.progression(user_id) values(v_user) on conflict do nothing;
  select * into v_progress from numix_private.progression where user_id=v_user for update;
  select * into v_profile from public.profiles where id=v_user for no key update;
  if not found then raise exception 'profile_required'; end if;
  -- A second call with the same request ID may have waited for the first one.
  select * into v_previous from numix_private.market_sales where request_id=p_request_id;
  if found then
    if v_previous.seller_id<>v_user or v_previous.item_ids<>p_ids then raise exception 'request_id_conflict'; end if;
    return jsonb_build_object('revision',v_previous.revision,'gross',v_previous.gross,
      'fee',v_previous.fee,'payout',v_previous.payout,'duplicate',true);
  end if;
  if v_profile.save_revision is distinct from p_expected_revision then raise exception 'save_revision_conflict'; end if;
  v_quote:=public.numix_system_sale_quote(p_ids);
  v_rub:=coalesce((v_quote#>>'{payout,rub}')::numeric,0);
  v_usd:=coalesce((v_quote#>>'{payout,usd}')::numeric,0);
  v_ton:=coalesce((v_quote#>>'{payout,ton}')::numeric,0);

  select coalesce(xp,0) into v_sale_xp from numix_private.progress_config where key='sale';
  v_sale_xp:=coalesce(v_sale_xp,0);
  with added as (
    insert into numix_private.progress_events(user_id,kind,source_id,xp_awarded)
      select v_user,'sale_manual',x.id,v_sale_xp from unnest(p_ids) x(id)
      where not exists(select 1 from numix_private.progress_events e
        where e.user_id=v_user and e.kind in ('sale','sale_manual','sale_auto') and e.source_id=x.id)
      on conflict (user_id,kind,source_id) do nothing returning xp_awarded
  ) select coalesce(sum(xp_awarded),0) into v_total_xp from added;
  v_old_level:=v_progress.level;
  update numix_private.progression set total_xp=total_xp+v_total_xp,updated_at=clock_timestamp()
    where user_id=v_user returning * into v_progress;
  v_threshold:=v_progress.level_start_xp+public.numix_xp_for_level(v_progress.level);
  while v_progress.total_xp>=v_threshold loop
    v_progress.level_start_xp:=v_threshold; v_progress.level:=v_progress.level+1;
    insert into numix_private.level_history(user_id,level) values(v_user,v_progress.level) on conflict do nothing;
    v_threshold:=v_progress.level_start_xp+public.numix_xp_for_level(v_progress.level);
  end loop;
  if v_progress.level<>v_old_level then
    update numix_private.progression set level=v_progress.level,level_start_xp=v_progress.level_start_xp where user_id=v_user;
  end if;

  select coalesce(jsonb_agg(e),'[]'::jsonb) into v_items
    from jsonb_array_elements(coalesce(v_profile.data#>'{state,collection}','[]'::jsonb)) e
    where not (e->>'id'=any(p_ids));
  select coalesce(jsonb_agg(e),'[]'::jsonb) into v_favs
    from jsonb_array_elements(coalesce(v_profile.data#>'{state,favorites}','[]'::jsonb)) e
    where not (coalesce(e->>'id',trim(both '"' from e::text))=any(p_ids));
  v_state:=coalesce(v_profile.data->'state','{}'::jsonb)||jsonb_build_object(
    'collection',v_items,'favorites',v_favs,
    'balance',coalesce(v_profile.balance,0)+v_rub,
    'usdBalance',coalesce(v_profile.usd_balance,0)+v_usd,
    'tonBalance',coalesce(v_profile.ton_balance,0)+v_ton);
  if v_profile.data#>>'{state,profile,selectedNumberId}'=any(p_ids) then
    v_state:=jsonb_set(v_state,'{profile,selectedNumberId}','null'::jsonb,true);
  end if;
  v_data:=jsonb_set(v_profile.data,'{state}',v_state);
  update public.profiles set data=v_data,
    balance=coalesce(balance,0)+v_rub,usd_balance=coalesce(usd_balance,0)+v_usd,
    ton_balance=coalesce(ton_balance,0)+v_ton,
    save_revision=save_revision+1,updated_at=clock_timestamp()
    where id=v_user returning save_revision into v_revision;
  delete from public.user_items where user_id=v_user and id=any(p_ids);
  insert into numix_private.market_sales(request_id,seller_id,item_ids,gross,fee,payout,revision)
    values(p_request_id,v_user,p_ids,v_quote->'gross',v_quote->'fee',v_quote->'payout',v_revision);
  return jsonb_build_object('revision',v_revision,'gross',v_quote->'gross',
    'fee',v_quote->'fee','payout',v_quote->'payout','duplicate',false);
end $$;

revoke all on function public.numix_system_sale_quote(text[]) from public,anon;
grant execute on function public.numix_system_sale_quote(text[]) to authenticated;
revoke all on function public.numix_system_sell(text[],uuid,bigint) from public,anon;
grant execute on function public.numix_system_sell(text[],uuid,bigint) to authenticated;
