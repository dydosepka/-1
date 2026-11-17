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
  v_rate:=greatest(0,v_fee_bps-300*v_no_fee);
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

create or replace function public.numix_system_sell(p_ids text[],p_request_id uuid,p_expected_revision bigint)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_profile public.profiles%rowtype; v_quote jsonb;
  v_previous numix_private.market_sales%rowtype; v_rub numeric; v_usd numeric; v_ton numeric;
  v_revision bigint; v_id text; v_items jsonb; v_favs jsonb;
begin
  if v_user is null or p_request_id is null then raise exception 'authentication_required'; end if;
  select * into v_previous from numix_private.market_sales where request_id=p_request_id;
  if found then
    if v_previous.seller_id<>v_user or v_previous.item_ids<>p_ids then raise exception 'request_id_conflict'; end if;
    return jsonb_build_object('revision',v_previous.revision,'gross',v_previous.gross,
      'fee',v_previous.fee,'payout',v_previous.payout,'duplicate',true);
  end if;
  select * into v_profile from public.profiles where id=v_user for update;
  if not found or v_profile.save_revision<>p_expected_revision then raise exception 'save_revision_conflict'; end if;
  v_quote:=public.numix_system_sale_quote(p_ids);
  v_rub:=coalesce((v_quote#>>'{payout,rub}')::numeric,0);
  v_usd:=coalesce((v_quote#>>'{payout,usd}')::numeric,0);
  v_ton:=coalesce((v_quote#>>'{payout,ton}')::numeric,0);
  foreach v_id in array p_ids loop
    perform public.numix_record_progress_event('sale_manual',v_id,null);
  end loop;
  select coalesce(jsonb_agg(e),'[]'::jsonb) into v_items
    from jsonb_array_elements(v_profile.data#>'{state,collection}') e where not (e->>'id'=any(p_ids));
  select coalesce(jsonb_agg(e),'[]'::jsonb) into v_favs
    from jsonb_array_elements(coalesce(v_profile.data#>'{state,favorites}','[]'::jsonb)) e
    where not (coalesce(e->>'id',trim(both '"' from e::text))=any(p_ids));
  update public.profiles set data=jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(data,
    '{state,collection}',v_items),'{state,favorites}',v_favs),
    '{state,balance}',to_jsonb(coalesce(balance,0)+v_rub)),
    '{state,usdBalance}',to_jsonb(coalesce(usd_balance,0)+v_usd)),
    '{state,tonBalance}',to_jsonb(coalesce(ton_balance,0)+v_ton)),
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
revoke all on function public.numix_system_sell(text[],uuid,bigint) from public,anon;
grant execute on function public.numix_system_sell(text[],uuid,bigint) to authenticated;

create or replace function public.numix_system_sale_history(p_limit integer default 30)
returns jsonb language sql security definer set search_path=pg_catalog,public,numix_private as $$
  select coalesce(jsonb_agg(jsonb_build_object('created_at',s.created_at,'items',s.item_ids,
    'gross',s.gross,'fee',s.fee,'payout',s.payout) order by s.created_at desc),'[]'::jsonb)
    from (select * from numix_private.market_sales where seller_id=auth.uid()
      order by created_at desc limit least(greatest(coalesce(p_limit,30),1),100)) s
$$;
revoke all on function public.numix_system_sale_history(integer) from public,anon;
grant execute on function public.numix_system_sale_history(integer) to authenticated;

create or replace function public.numix_validate_market_save(p_state jsonb,p_items jsonb)
returns void language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid();
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  if exists(select 1 from jsonb_array_elements(p_items) e join numix_private.market_lots l
    on l.kind='number' and l.item_id=e->>'id' and l.status='active')
    then raise exception 'listed_item_cannot_be_saved'; end if;
  if exists(select 1 from jsonb_array_elements(p_items) e join public.user_items i
    on i.id=e->>'id' and i.user_id<>v_user)
    then raise exception 'item_owned_by_another_player'; end if;
  if exists(select 1 from jsonb_array_elements(coalesce(p_state#>'{roulette,inventory}','[]'::jsonb)) e
    join numix_private.market_gift_ownership o on o.uid=e->>'u' and o.owner_id<>v_user)
    then raise exception 'gift_owned_by_another_player'; end if;
  if exists(select 1 from jsonb_array_elements(coalesce(p_state#>'{roulette,inventory}','[]'::jsonb)) e
    join numix_private.market_lots l on l.kind='gift' and l.item_id=e->>'u' and l.status='active')
    then raise exception 'listed_gift_cannot_be_saved'; end if;
end $$;
revoke all on function public.numix_validate_market_save(jsonb,jsonb) from public,anon;
grant execute on function public.numix_validate_market_save(jsonb,jsonb) to authenticated;

create or replace function public.save_numix_progress(p_expected_revision bigint,p_state jsonb,p_items jsonb)
returns table(new_revision bigint,saved_at timestamptz) language plpgsql
set search_path=pg_catalog,public as $$
declare v_user uuid:=auth.uid(); v_ids text[]; v_revision bigint; v_saved_at timestamptz;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  if jsonb_typeof(p_state)<>'object' or jsonb_typeof(p_state->'state')<>'object'
    or jsonb_typeof(p_items)<>'array' then raise exception 'invalid_save_payload'; end if;
  if jsonb_typeof(p_state#>'{state,collection}')<>'array'
    or jsonb_array_length(p_state#>'{state,collection}')<>jsonb_array_length(p_items)
    then raise exception 'collection_mismatch'; end if;
  if jsonb_array_length(p_items)>2500 then raise exception 'collection_limit_exceeded'; end if;
  select array_agg(e->>'id') into v_ids from jsonb_array_elements(p_items) e;
  if coalesce(array_length(v_ids,1),0)<>(select count(distinct x) from unnest(v_ids) x)
    or exists(select 1 from unnest(v_ids) x where x is null or x='')
    then raise exception 'duplicate_or_empty_item_id'; end if;
  perform public.numix_validate_market_save(p_state,p_items);
  update public.profiles p set data=p_state,
    balance=(p_state#>>'{state,balance}')::bigint,
    usd_balance=(p_state#>>'{state,usdBalance}')::bigint,
    ton_balance=(p_state#>>'{state,tonBalance}')::numeric,
    nickname=nullif(p_state#>>'{state,profile,nickname}',''),
    player_id=coalesce(nullif(p_state#>>'{state,profile,userId}',''),p.player_id),
    save_revision=p.save_revision+1,updated_at=clock_timestamp()
    where p.id=v_user and p.save_revision=p_expected_revision
    returning p.save_revision,p.updated_at into v_revision,v_saved_at;
  if not found then raise exception 'save_revision_conflict'; end if;
  insert into public.user_items(id,user_id,formatted_number,flag,rarity_key,price,pattern_desc,is_favorite,updated_at,sync_revision)
    select x.id,v_user,x.formatted_number,x.flag,x.rarity_key,x.price,x.pattern_desc,x.is_favorite,clock_timestamp(),v_revision
    from jsonb_to_recordset(p_items) as x(id text,formatted_number text,flag text,rarity_key text,price bigint,pattern_desc text,is_favorite boolean)
    on conflict(id) do update set formatted_number=excluded.formatted_number,flag=excluded.flag,
      rarity_key=excluded.rarity_key,price=excluded.price,pattern_desc=excluded.pattern_desc,
      is_favorite=excluded.is_favorite,updated_at=clock_timestamp(),sync_revision=v_revision
      where public.user_items.user_id=v_user and
        ((public.user_items.formatted_number,public.user_items.flag,public.user_items.rarity_key,
          public.user_items.price,public.user_items.pattern_desc,public.user_items.is_favorite)
        is distinct from (excluded.formatted_number,excluded.flag,excluded.rarity_key,
          excluded.price,excluded.pattern_desc,excluded.is_favorite)
        or public.user_items.sync_revision is distinct from v_revision);
  delete from public.user_items where user_id=v_user and sync_revision is not null
    and sync_revision<v_revision and not (id=any(coalesce(v_ids,array[]::text[])));
  return query select v_revision,v_saved_at;
end $$;
