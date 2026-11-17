create table if not exists numix_private.daily_collection_adds (
  user_id uuid not null references auth.users(id), quest_day date not null,
  item_id text not null, created_at timestamptz not null default clock_timestamp(),
  primary key(user_id,quest_day,item_id)
);
alter table numix_private.daily_collection_adds enable row level security;
revoke all on numix_private.daily_collection_adds from public,anon,authenticated;

create or replace function numix_private.capture_daily_collection_add()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_day date:=(clock_timestamp() at time zone 'UTC')::date;
begin
  if new.user_id is not null and not exists(
    select 1 from numix_private.market_lots l where l.kind='number' and l.item_id=new.id
      and l.seller_id=new.user_id and l.status='active') then
    insert into numix_private.daily_collection_adds(user_id,quest_day,item_id)
      values(new.user_id,v_day,new.id) on conflict do nothing;
  end if;
  return new;
end $$;
drop trigger if exists numix_daily_collection_add on public.user_items;
create trigger numix_daily_collection_add after insert on public.user_items
  for each row execute function numix_private.capture_daily_collection_add();

create or replace function public.numix_daily_quest_state()
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,numix_private as $$
declare v_user uuid:=auth.uid(); v_day date:=(clock_timestamp() at time zone 'UTC')::date;
  v_start timestamptz:=((clock_timestamp() at time zone 'UTC')::date)::timestamptz;
  v_level integer; v_activity bigint; v_base bigint; v_list jsonb; v_claimed integer;
begin
  if v_user is null then raise exception 'authentication_required'; end if;
  select coalesce(level,1) into v_level from numix_private.progression where user_id=v_user;
  v_level:=coalesce(v_level,1);
  select coalesce(total_seconds,0) into v_activity from numix_private.activity_totals where user_id=v_user;
  v_activity:=coalesce(v_activity,0);
  insert into numix_private.daily_quest_days(user_id,quest_day,activity_base)
    values(v_user,v_day,v_activity) on conflict do nothing;
  select activity_base into v_base from numix_private.daily_quest_days where user_id=v_user and quest_day=v_day;
  select coalesce(jsonb_agg(jsonb_build_object('key',c.quest_key,'title',c.title,'icon',c.icon,
    'target',case when v_level>=15 then c.target_veteran else c.target_new end,
    'rub',case when v_level>=15 then c.rub_veteran else c.rub_new end,
    'xp',case when v_level>=15 then c.xp_veteran else c.xp_new end,
    'progress',case c.quest_key
      when 'spins' then (select count(*) from numix_private.progress_events e where e.user_id=v_user and e.created_at>=v_start and e.kind in ('spin_manual','spin_auto'))
      when 'rare' then (select count(*) from numix_private.progress_events e where e.user_id=v_user and e.created_at>=v_start and e.kind in ('spin_manual','spin_auto') and e.rarity_key in ('rare','epic','legendary','mythic','ultra','secret','black'))
      when 'collection' then (select count(*) from numix_private.daily_collection_adds a where a.user_id=v_user and a.quest_day=v_day)
      when 'sales' then (select count(*) from numix_private.progress_events e where e.user_id=v_user and e.created_at>=v_start and e.kind in ('sale','sale_manual','sale_auto'))
      when 'gifts' then (select count(*) from numix_private.daily_gift_spins g where g.user_id=v_user and g.created_at>=v_start)
      when 'activity' then greatest(0,v_activity-v_base)
      when 'epic' then (select count(*) from numix_private.progress_events e where e.user_id=v_user and e.created_at>=v_start and e.kind in ('spin_manual','spin_auto') and e.rarity_key in ('epic','legendary','mythic','ultra','secret','black'))
      end,
    'claimed',exists(select 1 from numix_private.daily_quest_claims q where q.user_id=v_user and q.quest_day=v_day and q.quest_key=c.quest_key)
  ) order by c.quest_key),'[]'::jsonb) into v_list from numix_private.daily_quest_config c;
  select count(*) into v_claimed from numix_private.daily_quest_claims where user_id=v_user and quest_day=v_day and quest_key<>'bonus';
  return jsonb_build_object('day',v_day,'reset_at',(v_start+interval '1 day'),
    'quests',v_list,'claimed_count',v_claimed,'bonus_claimed',exists(
      select 1 from numix_private.daily_quest_claims where user_id=v_user and quest_day=v_day and quest_key='bonus'));
end $$;
