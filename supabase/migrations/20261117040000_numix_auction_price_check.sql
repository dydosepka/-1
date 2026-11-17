create or replace function public.numix_auction_buy(p_lot uuid,p_expected_revision bigint,p_expected_price numeric)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_lot numix_private.market_lots%rowtype; v_buyer public.profiles%rowtype;
  v_seller public.profiles%rowtype; v_fee_bps numeric; v_fee numeric; v_net numeric;
  v_item jsonb; v_revision bigint; v_seller_revision bigint; v_max integer;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  select * into v_lot from numix_private.market_lots where id=p_lot for update;
  if not found or v_lot.status<>'active' or v_lot.seller_id=v_user then raise exception 'lot_unavailable'; end if;
  if p_expected_price is null or v_lot.price_ton<>p_expected_price then raise exception 'lot_price_changed'; end if;
  -- Lock profile rows in a stable order across simultaneous trades.
  perform 1 from public.profiles where id in (v_user,v_lot.seller_id) order by id for update;
  select * into v_buyer from public.profiles where id=v_user;
  select * into v_seller from public.profiles where id=v_lot.seller_id;
  if not found or v_buyer.save_revision<>p_expected_revision then raise exception 'save_revision_conflict'; end if;
  if v_buyer.ton_balance<v_lot.price_ton then raise exception 'insufficient_ton'; end if;
  if v_lot.kind='number' then
    v_max:=least(2500,coalesce((v_buyer.data#>>'{state,upgrades,maxCapacity}')::integer,50)
      +100*coalesce((select level from numix_private.skill_levels where user_id=v_user and skill='collector'),0));
    if jsonb_array_length(coalesce(v_buyer.data#>'{state,collection}','[]'::jsonb))>=v_max then raise exception 'collection_full'; end if;
    if exists(select 1 from public.user_items where id=v_lot.item_id) then raise exception 'item_id_conflict'; end if;
    v_item:=jsonb_set(v_lot.item,'{isFavorite}','false'::jsonb,true);
    update public.profiles set data=jsonb_set(jsonb_set(data,'{state,collection}',
      coalesce(data#>'{state,collection}','[]'::jsonb)||jsonb_build_array(v_item)),
      '{state,tonBalance}',to_jsonb(v_buyer.ton_balance-v_lot.price_ton)),
      ton_balance=v_buyer.ton_balance-v_lot.price_ton,
      save_revision=save_revision+1,updated_at=clock_timestamp() where id=v_user returning save_revision into v_revision;
    insert into public.user_items(id,user_id,formatted_number,flag,rarity_key,price,pattern_desc,is_favorite,sync_revision)
      values(v_lot.item_id,v_user,v_item->>'formattedNumber',v_item->>'flag',v_item->>'rarityKey',
        (v_item->>'price')::bigint,v_item->>'patternDesc',false,v_revision);
  else
    update numix_private.market_gift_ownership set owner_id=v_user,updated_at=clock_timestamp() where uid=v_lot.item_id;
    update public.profiles set data=jsonb_set(jsonb_set(data,'{roulette,inventory}',
      coalesce(data#>'{roulette,inventory}','[]'::jsonb)||jsonb_build_array(v_lot.item)),
      '{state,tonBalance}',to_jsonb(v_buyer.ton_balance-v_lot.price_ton)),
      ton_balance=v_buyer.ton_balance-v_lot.price_ton,
      save_revision=save_revision+1,updated_at=clock_timestamp() where id=v_user returning save_revision into v_revision;
  end if;
  select value into v_fee_bps from numix_private.market_config where key='auction_fee_bps';
  v_fee:=round(v_lot.price_ton*v_fee_bps/10000,2); v_net:=v_lot.price_ton-v_fee;
  update public.profiles set data=jsonb_set(data,'{state,tonBalance}',to_jsonb(v_seller.ton_balance+v_net)),
    ton_balance=v_seller.ton_balance+v_net,save_revision=save_revision+1,updated_at=clock_timestamp()
    where id=v_lot.seller_id returning save_revision into v_seller_revision;
  update numix_private.market_lots set status='sold',buyer_id=v_user,closed_at=clock_timestamp(),
    fee_ton=v_fee,seller_net=v_net where id=p_lot;
  return jsonb_build_object('revision',v_revision,'seller_revision',v_seller_revision,
    'price_ton',v_lot.price_ton,'fee_ton',v_fee,'seller_net',v_net,'kind',v_lot.kind);
end $$;
revoke all on function public.numix_auction_buy(uuid,bigint,numeric) from public,anon;
grant execute on function public.numix_auction_buy(uuid,bigint,numeric) to authenticated;
revoke all on function public.numix_auction_buy(uuid,bigint) from public,anon,authenticated;
