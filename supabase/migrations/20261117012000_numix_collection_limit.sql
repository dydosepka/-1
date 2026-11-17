CREATE OR REPLACE FUNCTION public.save_numix_progress(p_expected_revision bigint, p_state jsonb, p_items jsonb)
 RETURNS TABLE(new_revision bigint, saved_at timestamp with time zone)
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_user uuid := auth.uid();
  v_ids text[];
  v_revision bigint;
  v_saved_at timestamptz;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  if jsonb_typeof(p_state) <> 'object' or jsonb_typeof(p_state->'state') <> 'object'
     or jsonb_typeof(p_items) <> 'array' then raise exception 'invalid_save_payload'; end if;
  if jsonb_typeof(p_state #> '{state,collection}') <> 'array'
     or jsonb_array_length(p_state #> '{state,collection}') <> jsonb_array_length(p_items)
     then raise exception 'collection_mismatch'; end if;
  if jsonb_array_length(p_items) > 2500 then raise exception 'collection_limit_exceeded'; end if;
  select array_agg(e->>'id') into v_ids from jsonb_array_elements(p_items) e;
  if coalesce(array_length(v_ids,1),0) <> coalesce((select count(distinct x) from unnest(v_ids) x),0)
     or exists (select 1 from unnest(v_ids) x where x is null or x = '')
     then raise exception 'duplicate_or_empty_item_id'; end if;

  update public.profiles p
  set data = p_state,
      balance = (p_state #>> '{state,balance}')::bigint,
      usd_balance = (p_state #>> '{state,usdBalance}')::bigint,
      ton_balance = (p_state #>> '{state,tonBalance}')::numeric,
      nickname = nullif(p_state #>> '{state,profile,nickname}',''),
      player_id = coalesce(nullif(p_state #>> '{state,profile,userId}',''), p.player_id),
      save_revision = p.save_revision + 1,
      updated_at = clock_timestamp()
  where p.id = v_user and p.save_revision = p_expected_revision
  returning p.save_revision, p.updated_at into v_revision, v_saved_at;
  if not found then raise exception 'save_revision_conflict'; end if;

  insert into public.user_items (id,user_id,formatted_number,flag,rarity_key,price,pattern_desc,is_favorite,updated_at,sync_revision)
  select x.id, v_user, x.formatted_number, x.flag, x.rarity_key, x.price, x.pattern_desc, x.is_favorite, clock_timestamp(), v_revision
  from jsonb_to_recordset(p_items) as x(id text, formatted_number text, flag text, rarity_key text, price bigint, pattern_desc text, is_favorite boolean)
  on conflict (id) do update
    set formatted_number=excluded.formatted_number, flag=excluded.flag, rarity_key=excluded.rarity_key,
        price=excluded.price, pattern_desc=excluded.pattern_desc, is_favorite=excluded.is_favorite,
        updated_at=clock_timestamp(), sync_revision=v_revision
    where public.user_items.user_id = v_user and
          ((public.user_items.formatted_number,public.user_items.flag,public.user_items.rarity_key,public.user_items.price,public.user_items.pattern_desc,public.user_items.is_favorite)
          is distinct from
          (excluded.formatted_number,excluded.flag,excluded.rarity_key,excluded.price,excluded.pattern_desc,excluded.is_favorite)
          or public.user_items.sync_revision is distinct from v_revision);

  delete from public.user_items
  where user_id = v_user and sync_revision is not null and sync_revision < v_revision
    and not (id = any(coalesce(v_ids,array[]::text[])));
  return query select v_revision, v_saved_at;
end;
$function$
