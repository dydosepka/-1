-- Recovery snapshot before changing sale and currency RPCs.
create table if not exists numix_private.stability_backup_20261117 (
  id bigint generated always as identity primary key,
  source text not null,
  record jsonb not null,
  captured_at timestamptz not null default clock_timestamp()
);
alter table numix_private.stability_backup_20261117 enable row level security;
revoke all on numix_private.stability_backup_20261117 from public, anon, authenticated;

insert into numix_private.stability_backup_20261117(source,record)
select 'profiles',to_jsonb(t) from public.profiles t
union all select 'user_items',to_jsonb(t) from public.user_items t
union all select 'progression',to_jsonb(t) from numix_private.progression t
union all select 'level_history',to_jsonb(t) from numix_private.level_history t
union all select 'market_sales',to_jsonb(t) from numix_private.market_sales t
union all select 'market_lots',to_jsonb(t) from numix_private.market_lots t
union all select 'market_gift_ownership',to_jsonb(t) from numix_private.market_gift_ownership t
union all select 'sale_progress_events',to_jsonb(t) from numix_private.progress_events t
  where t.kind in ('sale','sale_manual','sale_auto')
union all select 'function',jsonb_build_object('name',p.proname,
  'arguments',pg_get_function_identity_arguments(p.oid),'definition',pg_get_functiondef(p.oid))
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prokind='f' and p.proname in
    ('numix_system_sale_quote','numix_system_sell','numix_auction_buy','save_numix_progress');
