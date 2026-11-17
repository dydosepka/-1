create or replace function public.numix_record_progress_batch(p_events jsonb)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,numix_private as $$
declare v_event jsonb; v_result jsonb; v_count integer:=0;
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  if jsonb_typeof(p_events)<>'array' or jsonb_array_length(p_events)>50 then raise exception 'invalid_event_batch'; end if;
  for v_event in select value from jsonb_array_elements(p_events) loop
    v_result:=public.numix_record_progress_event(v_event->>'kind',v_event->>'source_id',v_event->>'rarity');
    v_count:=v_count+1;
  end loop;
  return jsonb_build_object('processed',v_count,'last',v_result);
end;
$$;
revoke all on function public.numix_record_progress_batch(jsonb) from public,anon;
grant execute on function public.numix_record_progress_batch(jsonb) to authenticated;
