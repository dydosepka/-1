-- Global rarity configuration. The standard mode retains the existing
-- pattern-based generator; custom mode uses the normalized percentages.
create table if not exists public.numix_drop_chances (
  id smallint primary key default 1 check (id = 1),
  mode text not null default 'standard' check (mode in ('standard','custom')),
  weights jsonb not null,
  effective jsonb not null,
  version bigint not null default 1,
  updated_at timestamptz not null default clock_timestamp(),
  updated_by uuid references auth.users(id)
);
alter table public.numix_drop_chances enable row level security;
revoke all on public.numix_drop_chances from public, anon, authenticated;
grant select on public.numix_drop_chances to anon, authenticated;
create policy numix_drop_chances_read on public.numix_drop_chances
  for select to anon, authenticated using (true);

-- Values already displayed by the standard game. Common absorbs the
-- rounding remainder; BLACK and secret retain their exact stated odds.
insert into public.numix_drop_chances(id,mode,weights,effective)
select 1,'standard',v,v from (select jsonb_build_object(
  'common', 100 - (13::numeric + 3.3 + 100::numeric/150 + 100::numeric/510
    + 100::numeric/10008 + 100::numeric/28357 + 100::numeric/74444 + 100::numeric/111111),
  'uncommon',13,'rare',3.3,'epic',100::numeric/150,
  'legendary',100::numeric/510,'mythic',100::numeric/10008,
  'ultra',100::numeric/28357,'secret',100::numeric/74444,
  'black',100::numeric/111111) v) defaults
on conflict(id) do nothing;

create or replace function public.numix_admin_set_drop_chances(
  p_weights jsonb default null, p_reset boolean default false
) returns public.numix_drop_chances
language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  v_user uuid := auth.uid();
  v_key text;
  v_value jsonb;
  v_total numeric := 0;
  v_effective jsonb := '{}'::jsonb;
  v_defaults jsonb;
  v_row public.numix_drop_chances;
begin
  if v_user is null or not exists
    (select 1 from public.numix_admins where user_id = v_user) then
    raise exception 'admin_required';
  end if;

  select weights into v_defaults from public.numix_drop_chances where id = 1;
  if not found then raise exception 'drop_settings_missing'; end if;

  if p_reset then
    -- The initial standard values are immutable in this branch.
    p_weights := jsonb_build_object(
      'common', 100 - (13::numeric + 3.3 + 100::numeric/150 + 100::numeric/510
        + 100::numeric/10008 + 100::numeric/28357 + 100::numeric/74444 + 100::numeric/111111),
      'uncommon',13,'rare',3.3,'epic',100::numeric/150,
      'legendary',100::numeric/510,'mythic',100::numeric/10008,
      'ultra',100::numeric/28357,'secret',100::numeric/74444,
      'black',100::numeric/111111);
    v_effective := p_weights;
  else
    if p_weights is null or jsonb_typeof(p_weights) <> 'object'
       or (select count(*) from jsonb_object_keys(p_weights)) <> 9 then
      raise exception 'invalid_drop_weights';
    end if;
    for v_key, v_value in select * from jsonb_each(p_weights) loop
      if v_key not in ('common','uncommon','rare','epic','legendary','mythic','ultra','secret','black')
         or jsonb_typeof(v_value) <> 'number'
         or (v_value::text)::numeric < 0
         or (v_value::text)::numeric > 100 then
        raise exception 'invalid_drop_weights';
      end if;
      v_total := v_total + (v_value::text)::numeric;
    end loop;
    if v_total <= 0 then raise exception 'invalid_drop_weights'; end if;
    for v_key, v_value in select * from jsonb_each(p_weights) loop
      v_effective := v_effective || jsonb_build_object(v_key, (v_value::text)::numeric * 100 / v_total);
    end loop;
  end if;

  update public.numix_drop_chances
  set mode = case when p_reset then 'standard' else 'custom' end,
      weights = p_weights, effective = v_effective,
      version = version + 1, updated_at = clock_timestamp(), updated_by = v_user
  where id = 1 returning * into v_row;
  return v_row;
end $$;
revoke all on function public.numix_admin_set_drop_chances(jsonb,boolean) from public,anon,authenticated;
grant execute on function public.numix_admin_set_drop_chances(jsonb,boolean) to authenticated;
