create or replace function public.numix_xp_for_level(p_level integer)
returns integer language sql immutable set search_path=pg_catalog as $$
  select greatest(100,(
    round((100 + 25.0 * (greatest(p_level,1)-1) * (greatest(p_level,1)+2) / 2)
      / (1 + 0.035 * greatest(p_level-5,0)) / 25) * 25
  )::integer)
$$;
revoke all on function public.numix_xp_for_level(integer) from public,anon;
grant execute on function public.numix_xp_for_level(integer) to authenticated;
