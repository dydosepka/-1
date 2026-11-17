-- The old manual luck RPC is no longer used by the game.
revoke execute on function public.numix_luck_roll() from authenticated;
