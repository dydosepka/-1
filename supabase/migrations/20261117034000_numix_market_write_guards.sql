-- The current game still saves ordinary spins through one versioned RPC.
-- Direct table writes would bypass the auction escrow and its revision checks.
alter function public.save_numix_progress(bigint,jsonb,jsonb) security definer;
revoke update,delete on public.profiles from authenticated,anon;
revoke insert,update,delete on public.user_items from authenticated,anon;

create or replace function public.numix_validate_market_save(p_state jsonb,p_items jsonb)
returns void language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid();
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  if exists(select 1 from jsonb_array_elements(p_items) e
    where not exists(select 1 from jsonb_array_elements(p_state#>'{state,collection}') c
      where c->>'id'=e->>'id' and c->>'formattedNumber'=e->>'formatted_number'))
    then raise exception 'collection_item_mismatch'; end if;
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
