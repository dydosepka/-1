-- Preserve existing cumulative time and sessions before changing leave accounting.
create table if not exists numix_private.activity_time_backup_20261117 (
  source text not null,
  row_data jsonb not null,
  backed_up_at timestamptz not null default clock_timestamp()
);
alter table numix_private.activity_time_backup_20261117 enable row level security;
revoke all on numix_private.activity_time_backup_20261117 from public, anon, authenticated;
insert into numix_private.activity_time_backup_20261117(source,row_data)
select 'activity_totals',to_jsonb(t) from numix_private.activity_totals t
union all select 'activity_sessions',to_jsonb(t) from numix_private.activity_sessions t
union all select 'activity_ping_function',jsonb_build_object('definition',pg_get_functiondef('public.numix_activity_ping(uuid,boolean)'::regprocedure))
union all select 'activity_leave_function',jsonb_build_object('definition',pg_get_functiondef('public.numix_activity_leave(uuid)'::regprocedure));

-- Commit the short active tail of a session before removing it. The global
-- total row serializes concurrent devices, so a second device cannot credit
-- the same interval again. An inactive or delayed leave credits nothing.
create or replace function public.numix_activity_leave(p_client_id uuid)
returns void language plpgsql security definer
set search_path = pg_catalog, public, numix_private as $$
declare
  v_user uuid := auth.uid();
  v_closed numix_private.activity_sessions%rowtype;
  v_last_credit timestamptz;
  v_now timestamptz;
  v_delta integer := 0;
begin
  if v_user is null or p_client_id is null then raise exception 'authentication_required'; end if;
  delete from numix_private.activity_sessions
    where user_id=v_user and client_id=p_client_id returning * into v_closed;
  if not found then return; end if;

  select last_credited_at into v_last_credit
    from numix_private.activity_totals where user_id=v_user for update;
  v_now := clock_timestamp();
  if v_last_credit is not null
     and v_last_credit >= v_now - interval '35 seconds'
     and v_closed.last_seen_at >= v_now - interval '20 seconds'
     and v_closed.last_interaction_at >= v_now - interval '60 seconds' then
    v_delta := least(20,greatest(0,floor(extract(epoch from v_now-v_last_credit))::integer));
  end if;
  if v_delta > 0 then
    update numix_private.activity_totals
       set total_seconds=total_seconds+v_delta,
           last_credited_at=v_now,updated_at=v_now
     where user_id=v_user;
  end if;
  if not exists (select 1 from numix_private.activity_sessions
      where user_id=v_user and last_seen_at > v_now-interval '45 seconds'
      and last_interaction_at > v_now-interval '60 seconds') then
    update numix_private.activity_totals
       set last_credited_at=null where user_id=v_user;
  end if;
end;
$$;
revoke all on function public.numix_activity_leave(uuid) from public, anon;
grant execute on function public.numix_activity_leave(uuid) to authenticated;
