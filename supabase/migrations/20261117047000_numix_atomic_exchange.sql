-- Registered accounts exchange currencies atomically; rates are unchanged.
create table if not exists numix_private.exchange_requests (
  request_id uuid primary key,
  user_id uuid not null references public.profiles(id),
  kind text not null check (kind in ('usd','ton')),
  amount bigint not null check (amount>0),
  rub_after bigint not null,
  usd_after bigint not null,
  ton_after numeric not null,
  revision bigint not null,
  created_at timestamptz not null default clock_timestamp()
);
create index if not exists numix_exchange_requests_user_time
  on numix_private.exchange_requests(user_id,created_at desc);
alter table numix_private.exchange_requests enable row level security;
revoke all on numix_private.exchange_requests from public,anon,authenticated;

create or replace function public.numix_exchange_currency(
  p_kind text,p_amount bigint,p_request_id uuid,p_expected_revision bigint)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_profile public.profiles%rowtype;
  v_previous numix_private.exchange_requests%rowtype; v_cost numeric;
  v_rub bigint; v_usd bigint; v_ton numeric; v_revision bigint; v_state jsonb;
begin
  if v_user is null or p_request_id is null then raise exception 'authentication_required'; end if;
  if p_kind not in ('usd','ton') or p_amount is null or p_amount<1 or p_amount>1000000000
    then raise exception 'invalid_exchange'; end if;
  select * into v_previous from numix_private.exchange_requests where request_id=p_request_id;
  if found then
    if v_previous.user_id<>v_user or v_previous.kind<>p_kind or v_previous.amount<>p_amount
      then raise exception 'request_id_conflict'; end if;
    return jsonb_build_object('rub',v_previous.rub_after,'usd',v_previous.usd_after,
      'ton',v_previous.ton_after,'revision',v_previous.revision,'duplicate',true);
  end if;
  select * into v_profile from public.profiles where id=v_user for no key update;
  if not found then raise exception 'profile_required'; end if;
  select * into v_previous from numix_private.exchange_requests where request_id=p_request_id;
  if found then
    if v_previous.user_id<>v_user or v_previous.kind<>p_kind or v_previous.amount<>p_amount
      then raise exception 'request_id_conflict'; end if;
    return jsonb_build_object('rub',v_previous.rub_after,'usd',v_previous.usd_after,
      'ton',v_previous.ton_after,'revision',v_previous.revision,'duplicate',true);
  end if;
  if v_profile.save_revision is distinct from p_expected_revision then raise exception 'save_revision_conflict'; end if;
  v_rub:=coalesce(v_profile.balance,0);
  v_usd:=coalesce(v_profile.usd_balance,0);
  v_ton:=coalesce(v_profile.ton_balance,0);
  if p_kind='usd' then
    v_cost:=p_amount::numeric*1000000;
    if v_rub<v_cost or v_usd::numeric+p_amount>9223372036854775807 then raise exception 'insufficient_rub'; end if;
    v_rub:=v_rub-v_cost::bigint; v_usd:=v_usd+p_amount;
  else
    v_cost:=p_amount::numeric*100;
    if v_usd<v_cost then raise exception 'insufficient_usd'; end if;
    v_usd:=v_usd-v_cost::bigint; v_ton:=v_ton+p_amount;
  end if;
  v_state:=coalesce(v_profile.data->'state','{}'::jsonb)||
    jsonb_build_object('balance',v_rub,'usdBalance',v_usd,'tonBalance',v_ton);
  update public.profiles set balance=v_rub,usd_balance=v_usd,ton_balance=v_ton,
    data=jsonb_set(coalesce(data,'{}'::jsonb),'{state}',v_state,true),
    save_revision=save_revision+1,updated_at=clock_timestamp()
    where id=v_user returning save_revision into v_revision;
  insert into numix_private.exchange_requests(request_id,user_id,kind,amount,rub_after,usd_after,ton_after,revision)
    values(p_request_id,v_user,p_kind,p_amount,v_rub,v_usd,v_ton,v_revision);
  return jsonb_build_object('rub',v_rub,'usd',v_usd,'ton',v_ton,'revision',v_revision,'duplicate',false);
end $$;
revoke all on function public.numix_exchange_currency(text,bigint,uuid,bigint) from public,anon;
grant execute on function public.numix_exchange_currency(text,bigint,uuid,bigint) to authenticated;
