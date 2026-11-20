-- =====================================================================
--  Pedido de piloto: busca uma conta pelo nick (mínimo de 3 letras,
--  até 8 resultados, só o nome e a classe). Pode ser executado de novo.
-- =====================================================================
create or replace function public.find_accounts(p_q text) returns json
language sql stable security definer set search_path = public as $$
  with q as (
    select replace(replace(replace(trim(coalesce(p_q, '')), '\', '\'), '%', '\%'), '_', '\_') as s
  )
  select case when not public.is_member() or char_length((select s from q)) < 3 then '[]'::json
    else coalesce((select json_agg(x) from (
      select p.id, coalesce(nullif(trim(p.game_name), ''), p.discord_name) as game_name, p.char_class
        from public.profiles p
       where p.role in ('member', 'officer', 'leader') and p.id <> auth.uid()
         and coalesce(nullif(trim(p.game_name), ''), p.discord_name) ilike '%' || (select s from q) || '%'
       order by 2 limit 8) x), '[]'::json) end
$$;

revoke execute on function public.find_accounts(text) from public, anon;
grant  execute on function public.find_accounts(text) to authenticated;
