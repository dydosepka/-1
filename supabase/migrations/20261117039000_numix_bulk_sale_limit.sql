create or replace function public.numix_system_sale_quote(p_ids text[])
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_data jsonb; v_id text; v_item jsonb;
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
