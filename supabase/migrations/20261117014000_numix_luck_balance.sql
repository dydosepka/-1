insert into numix_private.luck_weights(rarity_key,base_weight,boostable,max_weight)
values('ultra',0.003,false,0.003) on conflict(rarity_key) do nothing;
update numix_private.luck_weights w set base_weight=v.base_weight,max_weight=v.max_weight from (values
('common',79.997::numeric,79.997::numeric),('uncommon',15,15),('rare',4.6,4.6),
('epic',0.35,0.70),('legendary',0.045,0.09),('mythic',0.005,0.01)
) v(rarity_key,base_weight,max_weight) where w.rarity_key=v.rarity_key;

create or replace function public.numix_luck_roll()
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_progress numix_private.progression%rowtype;
  v_luck integer; v_greater integer; v_interval integer; v_mult integer;
  v_total numeric; v_draw numeric; v_running numeric:=0; v_row record; v_rarity text;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  select * into v_progress from numix_private.progression where user_id=v_user for update;
  select level into v_luck from numix_private.skill_levels where user_id=v_user and skill='luck';
  select level into v_greater from numix_private.skill_levels where user_id=v_user and skill='greater_luck';
  if coalesce(v_luck,0)<1 then raise exception 'luck_locked'; end if;
  select effects[v_luck] into v_interval from numix_private.skill_config where skill='luck';
  if v_progress.spins-v_progress.last_luck_spin<v_interval then raise exception 'luck_not_ready'; end if;
  v_mult:=case when coalesce(v_greater,0)>0 then v_greater*5 else 1 end;
  select sum(case when boostable then least(max_weight,base_weight+(v_mult-1)*base_weight*0.04)
    else base_weight end) into v_total from numix_private.luck_weights;
  v_draw:=random()*v_total;
  for v_row in select rarity_key,case when boostable then least(max_weight,base_weight+(v_mult-1)*base_weight*0.04)
      else base_weight end as weight from numix_private.luck_weights order by
      case rarity_key when 'common' then 1 when 'uncommon' then 2 when 'rare' then 3
        when 'epic' then 4 when 'legendary' then 5 when 'mythic' then 6 else 7 end loop
    v_running:=v_running+v_row.weight;
    if v_draw<v_running then v_rarity:=v_row.rarity_key; exit; end if;
  end loop;
  update numix_private.progression set last_luck_spin=spins,updated_at=clock_timestamp() where user_id=v_user;
  return jsonb_build_object('rarity',coalesce(v_rarity,'rare'),'interval',v_interval,
    'spins',v_progress.spins,'multiplier',v_mult);
end;
$$;
revoke all on function public.numix_luck_roll() from public,anon;
grant execute on function public.numix_luck_roll() to authenticated;
