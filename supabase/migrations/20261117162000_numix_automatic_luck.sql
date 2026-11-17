-- Reserve the next ordinary spin for luck; no additional spin or currency cost.
-- A stable spin ID lets a client safely retry after a lost response.
create table if not exists numix_private.luck_rolls (
  spin_id text primary key,
  user_id uuid not null references public.profiles(id),
  rarity_key text not null,
  spin_index bigint not null,
  created_at timestamptz not null default clock_timestamp()
);
create index if not exists numix_luck_rolls_user_time on numix_private.luck_rolls(user_id,created_at desc);
alter table numix_private.luck_rolls enable row level security;
revoke all on numix_private.luck_rolls from public,anon,authenticated;

create or replace function public.numix_luck_roll_auto(p_spin_id text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_progress numix_private.progression%rowtype;
  v_previous numix_private.luck_rolls%rowtype; v_luck integer; v_greater integer;
  v_interval integer; v_mult integer; v_total numeric; v_draw numeric;
  v_running numeric:=0; v_row record; v_rarity text;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  if p_spin_id is null or p_spin_id !~ '^num_[a-zA-Z0-9_]+$' or length(p_spin_id)>128
    then raise exception 'invalid_spin_id'; end if;
  select * into v_previous from numix_private.luck_rolls where spin_id=p_spin_id;
  if found then
    if v_previous.user_id<>v_user then raise exception 'request_id_conflict'; end if;
    return jsonb_build_object('rarity',v_previous.rarity_key,'spin_index',v_previous.spin_index,'duplicate',true);
  end if;
  select * into v_progress from numix_private.progression where user_id=v_user for update;
  if not found then raise exception 'progress_not_initialized'; end if;
  select * into v_previous from numix_private.luck_rolls where spin_id=p_spin_id;
  if found then
    if v_previous.user_id<>v_user then raise exception 'request_id_conflict'; end if;
    return jsonb_build_object('rarity',v_previous.rarity_key,'spin_index',v_previous.spin_index,'duplicate',true);
  end if;
  select level into v_luck from numix_private.skill_levels where user_id=v_user and skill='luck';
  select level into v_greater from numix_private.skill_levels where user_id=v_user and skill='greater_luck';
  if coalesce(v_luck,0)<1 then raise exception 'luck_locked'; end if;
  select effects[v_luck] into v_interval from numix_private.skill_config where skill='luck';
  if v_interval is null or v_progress.spins-v_progress.last_luck_spin+1<v_interval
    then raise exception 'luck_not_ready'; end if;
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
  update numix_private.progression set last_luck_spin=spins+1,updated_at=clock_timestamp()
    where user_id=v_user;
  insert into numix_private.luck_rolls(spin_id,user_id,rarity_key,spin_index)
    values(p_spin_id,v_user,coalesce(v_rarity,'rare'),v_progress.spins+1);
  return jsonb_build_object('rarity',coalesce(v_rarity,'rare'),'spin_index',v_progress.spins+1,
    'interval',v_interval,'multiplier',v_mult,'duplicate',false);
end $$;
revoke all on function public.numix_luck_roll_auto(text) from public,anon;
grant execute on function public.numix_luck_roll_auto(text) to authenticated;
