-- Existing profiles, items, skills and event data were copied to
-- numix_backup_20261117_market_quests before this migration.
create table if not exists numix_private.market_config (
  key text primary key, value numeric not null check (value >= 0),
  updated_at timestamptz not null default now()
);
insert into numix_private.market_config(key,value) values
  ('system_fee_bps',1500),('auction_fee_bps',300)
on conflict (key) do nothing;
alter table numix_private.market_config enable row level security;
revoke all on numix_private.market_config from public,anon,authenticated;

insert into numix_private.skill_config(skill,unlock_level,costs,effects)
values ('no_fee',30,array[200,400,700,1100,1700],array[12,9,6,3,0])
on conflict (skill) do update set unlock_level=excluded.unlock_level,
  costs=excluded.costs,effects=excluded.effects;

create table if not exists numix_private.market_lots (
  id uuid primary key default gen_random_uuid(), seller_id uuid not null references auth.users(id),
  buyer_id uuid references auth.users(id), kind text not null check(kind in ('number','gift')),
  item_id text not null, item jsonb not null, price_ton numeric(20,2) not null check(price_ton>=1 and price_ton<=1000000000),
  status text not null default 'active' check(status in ('active','sold','cancelled')),
  created_at timestamptz not null default clock_timestamp(), closed_at timestamptz,
  fee_ton numeric(20,2), seller_net numeric(20,2)
);
create unique index if not exists numix_market_active_item on numix_private.market_lots(kind,item_id) where status='active';
create index if not exists numix_market_feed on numix_private.market_lots(status,created_at desc);
create index if not exists numix_market_seller on numix_private.market_lots(seller_id,created_at desc);
create index if not exists numix_market_buyer on numix_private.market_lots(buyer_id,closed_at desc);
alter table numix_private.market_lots enable row level security;
revoke all on numix_private.market_lots from public,anon,authenticated;

create table if not exists numix_private.market_gift_ownership (
  uid text primary key, owner_id uuid not null references auth.users(id), updated_at timestamptz not null default now()
);
alter table numix_private.market_gift_ownership enable row level security;
revoke all on numix_private.market_gift_ownership from public,anon,authenticated;

create table if not exists numix_private.market_sales (
  request_id uuid primary key, seller_id uuid not null references auth.users(id),
  item_ids text[] not null, gross jsonb not null, fee jsonb not null, payout jsonb not null,
  created_at timestamptz not null default clock_timestamp(), revision bigint not null
);
alter table numix_private.market_sales enable row level security;
revoke all on numix_private.market_sales from public,anon,authenticated;

create or replace function public.numix_market_settings()
returns jsonb language sql security definer set search_path=pg_catalog,public,numix_private as $$
  select jsonb_object_agg(key,value) from numix_private.market_config
$$;
revoke all on function public.numix_market_settings() from public;
grant execute on function public.numix_market_settings() to anon,authenticated;

create or replace function public.numix_admin_market_setting(p_key text,p_value numeric)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
begin
  if auth.uid() is null or not public.numix_is_admin() then raise exception 'admin_required'; end if;
  if p_key not in ('system_fee_bps','auction_fee_bps') or p_value is null or p_value<>trunc(p_value)
    or p_value<0 or p_value>5000 then raise exception 'invalid_market_setting'; end if;
  update numix_private.market_config set value=p_value,updated_at=clock_timestamp() where key=p_key;
  return public.numix_market_settings();
end $$;
revoke all on function public.numix_admin_market_setting(text,numeric) from public,anon;
grant execute on function public.numix_admin_market_setting(text,numeric) to authenticated;

create or replace function public.numix_admin_skill_cost(p_skill text,p_level integer,p_cost integer)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_costs integer[];
begin
  if auth.uid() is null or not public.numix_is_admin() then raise exception 'admin_required'; end if;
  if p_level not between 1 and 5 or p_cost not between 1 and 10000000 then raise exception 'invalid_skill_cost'; end if;
  select costs into v_costs from numix_private.skill_config where skill=p_skill for update;
  if not found then raise exception 'unknown_skill'; end if;
  v_costs[p_level]:=p_cost;
  update numix_private.skill_config set costs=v_costs where skill=p_skill;
  return jsonb_build_object('skill',p_skill,'costs',to_jsonb(v_costs));
end $$;
revoke all on function public.numix_admin_skill_cost(text,integer,integer) from public,anon;
grant execute on function public.numix_admin_skill_cost(text,integer,integer) to authenticated;

create or replace function public.numix_auction_feed(p_kind text default 'all',p_search text default null,
  p_sort text default 'new',p_min numeric default null,p_max numeric default null,p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_rows jsonb;
begin
  if p_kind not in ('all','number','gift','mine','history') then raise exception 'invalid_filter'; end if;
  select coalesce(jsonb_agg(x.entry order by x.sort_value), '[]'::jsonb) into v_rows from (
    select jsonb_build_object('id',l.id,'kind',l.kind,'item_id',l.item_id,'item',l.item,
      'price_ton',l.price_ton,'seller_id',p.player_id,'seller_name',coalesce(p.nickname,'Игрок'),
      'created_at',l.created_at,'status',l.status,'closed_at',l.closed_at,
      'fee_ton',l.fee_ton,'seller_net',l.seller_net,
      'buyer_id',bp.player_id,'buyer_name',bp.nickname,
      'is_mine',l.seller_id=auth.uid()) entry,
      case when p_sort='cheap' then l.price_ton when p_sort='expensive' then -l.price_ton else 0 end sort_value
    from numix_private.market_lots l join public.profiles p on p.id=l.seller_id
      left join public.profiles bp on bp.id=l.buyer_id
    where ((p_kind='history' and auth.uid() is not null and l.status='sold'
      and (l.seller_id=auth.uid() or l.buyer_id=auth.uid()))
      or (p_kind='mine' and auth.uid() is not null and l.seller_id=auth.uid() and l.status='active')
      or (p_kind in ('all','number','gift') and l.status='active' and (p_kind='all' or l.kind=p_kind)))
      and (p_min is null or l.price_ton>=p_min) and (p_max is null or l.price_ton<=p_max)
      and (nullif(trim(p_search),'') is null or coalesce(l.item->>'formattedNumber',l.item->>'name',l.item_id) ilike '%'||left(trim(p_search),60)||'%'
        or p.nickname ilike '%'||left(trim(p_search),60)||'%')
    order by case when p_sort='cheap' then l.price_ton end asc,
      case when p_sort='expensive' then l.price_ton end desc,l.created_at desc
    limit least(greatest(coalesce(p_limit,50),1),100)
  ) x;
  return jsonb_build_object('lots',v_rows,'fee_bps',(select value from numix_private.market_config where key='auction_fee_bps'));
end $$;
revoke all on function public.numix_auction_feed(text,text,text,numeric,numeric,integer) from public;
grant execute on function public.numix_auction_feed(text,text,text,numeric,numeric,integer) to anon,authenticated;

create or replace function public.numix_auction_list(p_kind text,p_item_id text,p_price numeric,p_expected_revision bigint)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_profile public.profiles%rowtype; v_item jsonb; v_items jsonb;
  v_lot uuid; v_revision bigint; v_gift_owner uuid; v_fee numeric;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  if p_kind not in ('number','gift') or length(coalesce(p_item_id,'')) not between 1 and 128
    or p_price is null or p_price<1 or p_price>1000000000 or p_price<>round(p_price,2)
    then raise exception 'invalid_listing'; end if;
  select * into v_profile from public.profiles where id=v_user for update;
  if not found or v_profile.save_revision<>p_expected_revision then raise exception 'save_revision_conflict'; end if;
  if p_kind='number' then
    select e into v_item from jsonb_array_elements(coalesce(v_profile.data#>'{state,collection}','[]'::jsonb)) e where e->>'id'=p_item_id limit 1;
    if v_item is null or not exists(select 1 from public.user_items where id=p_item_id and user_id=v_user)
      then raise exception 'item_not_owned'; end if;
    if coalesce(v_item->>'rarityKey','') in ('black','secret') then raise exception 'item_not_tradeable'; end if;
    select coalesce(jsonb_agg(e),'[]'::jsonb) into v_items from jsonb_array_elements(v_profile.data#>'{state,collection}') e where e->>'id'<>p_item_id;
    update public.profiles set data=jsonb_set(jsonb_set(data,'{state,collection}',v_items),'{state,favorites}',
      coalesce((select jsonb_agg(e) from jsonb_array_elements(coalesce(data#>'{state,favorites}','[]'::jsonb)) e
        where coalesce(e->>'id',e#>>'{}')<>p_item_id),'[]'::jsonb)),
      save_revision=save_revision+1,updated_at=clock_timestamp() where id=v_user returning save_revision into v_revision;
    delete from public.user_items where id=p_item_id and user_id=v_user;
  else
    select e into v_item from jsonb_array_elements(coalesce(v_profile.data#>'{roulette,inventory}','[]'::jsonb)) e where e->>'u'=p_item_id limit 1;
    if v_item is null or coalesce(v_item->>'id','') !~ '^g[0-9]{1,3}$' then raise exception 'item_not_owned'; end if;
    select owner_id into v_gift_owner from numix_private.market_gift_ownership where uid=p_item_id for update;
    if v_gift_owner is not null and v_gift_owner<>v_user then raise exception 'item_not_owned'; end if;
    insert into numix_private.market_gift_ownership(uid,owner_id) values(p_item_id,v_user)
      on conflict(uid) do update set updated_at=clock_timestamp();
    select coalesce(jsonb_agg(e),'[]'::jsonb) into v_items from jsonb_array_elements(v_profile.data#>'{roulette,inventory}') e where e->>'u'<>p_item_id;
    update public.profiles set data=jsonb_set(jsonb_set(data,'{roulette,inventory}',v_items),'{state,profile,pinnedGifts}',
      coalesce((select jsonb_agg(e) from jsonb_array_elements(coalesce(data#>'{state,profile,pinnedGifts}','[]'::jsonb)) e
        where e->>'uid'<>p_item_id),'[]'::jsonb)),
      save_revision=save_revision+1,updated_at=clock_timestamp() where id=v_user returning save_revision into v_revision;
  end if;
  insert into numix_private.market_lots(seller_id,kind,item_id,item,price_ton)
    values(v_user,p_kind,p_item_id,v_item,p_price) returning id into v_lot;
  select value into v_fee from numix_private.market_config where key='auction_fee_bps';
  return jsonb_build_object('id',v_lot,'revision',v_revision,'fee_ton',round(p_price*v_fee/10000,2),
    'seller_net',p_price-round(p_price*v_fee/10000,2));
end $$;
revoke all on function public.numix_auction_list(text,text,numeric,bigint) from public,anon;
grant execute on function public.numix_auction_list(text,text,numeric,bigint) to authenticated;

create or replace function public.numix_auction_cancel(p_lot uuid,p_expected_revision bigint)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_lot numix_private.market_lots%rowtype; v_profile public.profiles%rowtype;
  v_revision bigint;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  select * into v_lot from numix_private.market_lots where id=p_lot for update;
  if not found or v_lot.seller_id<>v_user or v_lot.status<>'active' then raise exception 'lot_unavailable'; end if;
  select * into v_profile from public.profiles where id=v_user for update;
  if v_profile.save_revision<>p_expected_revision then raise exception 'save_revision_conflict'; end if;
  if v_lot.kind='number' then
    update public.profiles set data=jsonb_set(data,'{state,collection}',
      coalesce(data#>'{state,collection}','[]'::jsonb)||jsonb_build_array(v_lot.item)),
      save_revision=save_revision+1,updated_at=clock_timestamp() where id=v_user returning save_revision into v_revision;
    insert into public.user_items(id,user_id,formatted_number,flag,rarity_key,price,pattern_desc,is_favorite,sync_revision)
      values(v_lot.item_id,v_user,v_lot.item->>'formattedNumber',v_lot.item->>'flag',v_lot.item->>'rarityKey',
        (v_lot.item->>'price')::bigint,v_lot.item->>'patternDesc',false,v_revision);
  else
    update public.profiles set data=jsonb_set(data,'{roulette,inventory}',
      coalesce(data#>'{roulette,inventory}','[]'::jsonb)||jsonb_build_array(v_lot.item)),
      save_revision=save_revision+1,updated_at=clock_timestamp() where id=v_user returning save_revision into v_revision;
  end if;
  update numix_private.market_lots set status='cancelled',closed_at=clock_timestamp() where id=p_lot;
  return jsonb_build_object('revision',v_revision,'cancelled',true);
end $$;
revoke all on function public.numix_auction_cancel(uuid,bigint) from public,anon;
grant execute on function public.numix_auction_cancel(uuid,bigint) to authenticated;

create or replace function public.numix_auction_reprice(p_lot uuid,p_price numeric)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_lot numix_private.market_lots%rowtype; v_fee numeric;
begin
  if auth.uid() is null or p_price is null or p_price<1 or p_price>1000000000 or p_price<>round(p_price,2)
    then raise exception 'invalid_price'; end if;
  select * into v_lot from numix_private.market_lots where id=p_lot for update;
  if not found or v_lot.status<>'active' or v_lot.seller_id<>auth.uid() then raise exception 'lot_unavailable'; end if;
  update numix_private.market_lots set price_ton=p_price where id=p_lot;
  select value into v_fee from numix_private.market_config where key='auction_fee_bps';
  return jsonb_build_object('price_ton',p_price,'fee_ton',round(p_price*v_fee/10000,2));
end $$;
revoke all on function public.numix_auction_reprice(uuid,numeric) from public,anon;
grant execute on function public.numix_auction_reprice(uuid,numeric) to authenticated;

create or replace function public.numix_auction_buy(p_lot uuid,p_expected_revision bigint)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_lot numix_private.market_lots%rowtype; v_buyer public.profiles%rowtype;
  v_seller public.profiles%rowtype; v_fee_bps numeric; v_fee numeric; v_net numeric;
  v_item jsonb; v_revision bigint; v_seller_revision bigint; v_max integer;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  select * into v_lot from numix_private.market_lots where id=p_lot for update;
  if not found or v_lot.status<>'active' or v_lot.seller_id=v_user then raise exception 'lot_unavailable'; end if;
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
revoke all on function public.numix_auction_buy(uuid,bigint) from public,anon;
grant execute on function public.numix_auction_buy(uuid,bigint) to authenticated;
