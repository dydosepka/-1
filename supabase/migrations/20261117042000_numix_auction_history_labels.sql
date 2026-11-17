create or replace function public.numix_auction_feed(p_kind text default 'all',p_search text default null,
  p_sort text default 'new',p_min numeric default null,p_max numeric default null,p_limit integer default 50,p_rarity text default 'all')
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_rows jsonb;
begin
  if p_kind not in ('all','number','gift','mine','history') or length(coalesce(p_rarity,''))>32 then raise exception 'invalid_filter'; end if;
  select coalesce(jsonb_agg(x.entry order by x.sort_value,x.sort_created desc), '[]'::jsonb) into v_rows from (
    select jsonb_build_object('id',l.id,'kind',l.kind,'item_id',l.item_id,'item',l.item,
      'price_ton',l.price_ton,'seller_id',p.player_id,'seller_name',coalesce(p.nickname,'Игрок'),
      'created_at',l.created_at,'status',l.status,'closed_at',l.closed_at,
      'fee_ton',l.fee_ton,'seller_net',l.seller_net,
      'buyer_id',bp.player_id,'buyer_name',bp.nickname,
      'is_mine',l.seller_id=auth.uid(),'is_buyer',l.buyer_id=auth.uid()) entry,
      case when p_sort='cheap' then l.price_ton when p_sort='expensive' then -l.price_ton else 0 end sort_value, l.created_at sort_created
    from numix_private.market_lots l join public.profiles p on p.id=l.seller_id
      left join public.profiles bp on bp.id=l.buyer_id
    where ((p_kind='history' and auth.uid() is not null and l.status='sold'
      and (l.seller_id=auth.uid() or l.buyer_id=auth.uid()))
      or (p_kind='mine' and auth.uid() is not null and l.seller_id=auth.uid() and l.status='active')
      or (p_kind in ('all','number','gift') and l.status='active' and (p_kind='all' or l.kind=p_kind)))
      and (p_rarity='all' or coalesce(l.item->>'rarityKey',l.item->>'rarity')=p_rarity)
      and (p_min is null or l.price_ton>=p_min) and (p_max is null or l.price_ton<=p_max)
      and (nullif(trim(p_search),'') is null or coalesce(l.item->>'formattedNumber',l.item->>'name',l.item_id) ilike '%'||left(trim(p_search),60)||'%'
        or p.nickname ilike '%'||left(trim(p_search),60)||'%')
    order by case when p_sort='cheap' then l.price_ton end asc,
      case when p_sort='expensive' then l.price_ton end desc,l.created_at desc
    limit least(greatest(coalesce(p_limit,50),1),100)
  ) x;
  return jsonb_build_object('lots',v_rows,'fee_bps',(select value from numix_private.market_config where key='auction_fee_bps'));
end $$;
