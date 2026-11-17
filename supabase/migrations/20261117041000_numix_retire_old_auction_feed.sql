-- Keep only the filtered seven-argument feed exposed to clients.
revoke all on function public.numix_auction_feed(text,text,text,numeric,numeric,integer)
  from public,anon,authenticated;
