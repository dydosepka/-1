create or replace view numix_private.ranking_base as
select p.id,
  coalesce(nullif(trim(p.nickname),''),'Игрок') as nickname,
  p.player_id,
  greatest(coalesce(p.balance,0),0)::numeric as rub_balance,
  greatest(coalesce(p.usd_balance,0),0)::numeric as usd_balance,
  greatest(coalesce(p.ton_balance,0),0)::numeric as ton_balance,
  coalesce(a.total_seconds,0)::bigint as active_seconds,
  best.id as best_item_id,
  best.formatted_number as best_number,
  best.flag as best_flag,
  best.rarity_key as best_rarity,
  best.price as best_price,
  best.price_rub as best_price_rub,
  coalesce(
    (select elem #>> '{plan,country}' from jsonb_array_elements(
      case when jsonb_typeof(p.data #> '{state,collection}')='array' then p.data #> '{state,collection}' else '[]'::jsonb end
    ) elem where elem->>'id'=best.id limit 1),
    case best.flag when '🇷🇺' then 'Россия' when '🇰🇿' then 'Казахстан'
      when '🇺🇸' then 'США' when '🇦🇪' then 'ОАЭ' when '🇬🇧' then 'Великобритания'
      when '🇩🇪' then 'Германия' when '🇹🇬' then 'Того' when '🇸🇴' then 'Сомали'
      when '🇸🇱' then 'Сьерра-Леоне' when '🇲🇦' then 'Марокко' when '🇲🇽' then 'Мексика'
      when '🇲🇷' then 'Мавритания' when '🇰🇬' then 'Кыргызстан' when '🇨🇿' then 'Чехия'
      else 'Серия NumixSpin' end
  ) as best_country,
  coalesce(prog.level,1) as level,
  coalesce(prog.total_xp,0) as total_xp
from public.profiles p
left join numix_private.activity_totals a on a.user_id=p.id
left join numix_private.progression prog on prog.user_id=p.id
left join lateral (
  select i.id,i.formatted_number,i.flag,i.rarity_key,i.price,
    case when i.rarity_key='black' then i.price::numeric*100000000
         when i.rarity_key='secret' then i.price::numeric*1000000
         else i.price::numeric end as price_rub
  from public.user_items i where i.user_id=p.id
  order by (case when i.rarity_key='black' then i.price::numeric*100000000
                 when i.rarity_key='secret' then i.price::numeric*1000000
                 else i.price::numeric end) desc,i.id
  limit 1
) best on true
where p.player_id is not null;
revoke all on numix_private.ranking_base from public, anon, authenticated;

create or replace function public.numix_leaderboard(
  p_category text, p_search text default null, p_limit integer default 50
) returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, numix_private as $$
declare
  v_rows jsonb;
  v_me integer;
  v_total integer;
  v_online integer;
  v_search text := nullif(trim(left(coalesce(p_search,''),64)),'');
begin
  if p_category not in ('best','rub','usd','ton','activity','level') or p_category is null
    then raise exception 'invalid_leaderboard_category'; end if;
  with values_by_category as (
    select b.*,
      case p_category when 'best' then b.best_price_rub when 'rub' then b.rub_balance
        when 'usd' then b.usd_balance when 'ton' then b.ton_balance
        when 'level' then b.level::numeric else b.active_seconds::numeric end as metric
    from numix_private.ranking_base b
    where p_category <> 'best' or b.best_item_id is not null
  ), ranked as (
    select v.*,row_number() over(order by v.metric desc,case when p_category='level' then v.total_xp else 0 end desc,v.player_id,v.id)::integer as position
    from values_by_category v
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'position',z.position,'player_id',z.player_id,'nickname',z.nickname,
    'level',z.level,'total_xp',z.total_xp,
    'value',z.metric,'number',case when p_category='best' then z.best_number else null end,
    'country',case when p_category='best' then z.best_country else null end,
    'flag',case when p_category='best' then z.best_flag else null end,
    'rarity',case when p_category='best' then z.best_rarity else null end,
    'original_price',case when p_category='best' then z.best_price else null end
  ) order by z.position),'[]'::jsonb)
  into v_rows from (
    select * from ranked
    where v_search is null or nickname ilike '%'||v_search||'%' or player_id ilike '%'||v_search||'%'
    order by position limit least(greatest(coalesce(p_limit,50),1),100)
  ) z;
  with values_by_category as (
    select b.id,b.player_id,b.total_xp,
      case p_category when 'best' then b.best_price_rub when 'rub' then b.rub_balance
        when 'usd' then b.usd_balance when 'ton' then b.ton_balance
        when 'level' then b.level::numeric else b.active_seconds::numeric end as metric
    from numix_private.ranking_base b where p_category <> 'best' or b.best_item_id is not null
  ), ranked as (
    select id,row_number() over(order by metric desc,case when p_category='level' then total_xp else 0 end desc,player_id,id)::integer as position from values_by_category
  ) select count(*),max(position) filter(where id=auth.uid()) into v_total,v_me from ranked;
  select count(distinct user_id) into v_online from numix_private.activity_sessions
    where last_seen_at > clock_timestamp()-interval '45 seconds'
      and last_interaction_at > clock_timestamp()-interval '60 seconds';
  return jsonb_build_object('category',p_category,'rows',v_rows,'my_position',v_me,
    'total_players',v_total,'online_count',v_online,'updated_at',clock_timestamp());
end;
$$;
revoke all on function public.numix_leaderboard(text,text,integer) from public;
grant execute on function public.numix_leaderboard(text,text,integer) to anon, authenticated;

create or replace function public.numix_my_positions()
returns jsonb language sql security definer
set search_path = pg_catalog, public, numix_private as $$
with ranks as (
  select id,best_item_id,active_seconds,
    row_number() over(order by best_price_rub desc nulls last,player_id,id)::integer as best_rank,
    row_number() over(order by rub_balance desc,player_id,id)::integer as rub_rank,
    row_number() over(order by usd_balance desc,player_id,id)::integer as usd_rank,
    row_number() over(order by ton_balance desc,player_id,id)::integer as ton_rank,
    row_number() over(order by active_seconds desc,player_id,id)::integer as activity_rank,
    row_number() over(order by level desc,total_xp desc,player_id,id)::integer as level_rank
  from numix_private.ranking_base
) select coalesce((select jsonb_build_object('best',case when best_item_id is null then null else best_rank end,
  'rub',rub_rank,'usd',usd_rank,'ton',ton_rank,'activity',activity_rank,'level',level_rank,
  'active_seconds',active_seconds) from ranks where id=auth.uid()),'null'::jsonb)
$$;
revoke all on function public.numix_my_positions() from public, anon;
grant execute on function public.numix_my_positions() to authenticated;

create or replace function public.numix_public_player(p_player_id text)
returns jsonb language sql security definer
set search_path = pg_catalog, public, numix_private as $$
select coalesce((select jsonb_build_object(
  'nickname',nickname,'player_id',player_id,'rub',rub_balance,'usd',usd_balance,
  'ton',ton_balance,'active_seconds',active_seconds,'level',level,'total_xp',total_xp,'best_number',best_number,
  'best_flag',best_flag,'best_country',best_country,'best_rarity',best_rarity,
  'best_price_rub',best_price_rub,'best_price',best_price
) from numix_private.ranking_base where player_id=upper(trim(p_player_id)) limit 1),'null'::jsonb)
$$;
revoke all on function public.numix_public_player(text) from public;
grant execute on function public.numix_public_player(text) to anon, authenticated;
