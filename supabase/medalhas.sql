-- =====================================================================
--  Medalhas (Novembro/2026)
--  Calcula, para cada membro ativo, só o necessário para as medalhas:
--    streak         = presenças seguidas (do evento mais recente para trás)
--    perfect_months = meses fechados com 100% de presença (mínimo 4 eventos)
--    res_gain       = Ressonância ganha desde o primeiro valor registrado
--  Qualquer membro vê as medalhas de todos, mas NÃO a frequência detalhada.
--  Só ADICIONA uma função. Nenhum dado é alterado ou apagado.
-- =====================================================================
create or replace function public.member_badges()
returns table (user_id uuid, streak integer, perfect_months integer, res_gain integer)
language sql stable security definer set search_path = public as $$
  with mem as (
    select p.id, p.created_at, p.resonance
      from public.profiles p
     where public.is_member() and p.role in ('member', 'officer', 'leader')
  ),
  -- Eventos que já aconteceram e tiveram a presença registrada
  reg as (
    select e.id, e.starts_at
      from public.events e
     where e.starts_at <= now() and exists (select 1 from public.attendance a where a.event_id = e.id)
  ),
  hist as (
    select m.id as uid, r.starts_at,
           coalesce((select a.present from public.attendance a where a.event_id = r.id and a.user_id = m.id), false) as was
      from mem m join reg r on r.starts_at >= m.created_at
  ),
  ordered as (
    select uid, was,
           sum(case when was then 0 else 1 end) over (partition by uid order by starts_at desc rows unbounded preceding) as misses
      from hist
  ),
  stk as (select uid, (count(*) filter (where misses = 0))::int as streak from ordered group by uid),
  months as (
    select uid, date_trunc('month', starts_at at time zone 'America/Sao_Paulo') as mon, count(*) as n, bool_and(was) as all_in
      from hist group by uid, date_trunc('month', starts_at at time zone 'America/Sao_Paulo')
  ),
  pm as (
    select uid, (count(*) filter (where n >= 4 and all_in
                   and mon < date_trunc('month', now() at time zone 'America/Sao_Paulo')))::int as perfect
      from months group by uid
  ),
  -- Primeiro valor de Ressonância registrado no histórico de alterações
  rg as (
    select distinct on (h.user_id) h.user_id as uid, (h.changes -> 'resonance' ->> 0)::numeric as first_val
      from public.profile_history h
     where h.changes ? 'resonance' and jsonb_typeof(h.changes -> 'resonance' -> 0) = 'number'
     order by h.user_id, h.changed_at asc
  )
  select m.id, coalesce(s.streak, 0), coalesce(p.perfect, 0),
         greatest(0, coalesce(m.resonance - rg.first_val, 0))::int
    from mem m
    left join stk s on s.uid = m.id
    left join pm  p on p.uid = m.id
    left join rg    on rg.uid = m.id;
$$;

revoke execute on function public.member_badges() from public, anon;
grant  execute on function public.member_badges() to authenticated;
