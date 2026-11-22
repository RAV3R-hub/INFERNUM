-- =====================================================================
--  "Só piloto": cadastro que existe apenas para responder pelas contas
--  que pilota. Rode este arquivo uma vez no Supabase (SQL Editor).
--  Pode rodar de novo sem problema.
--
--  - Cria a coluna profiles.pilot_only (começa "não" para todo mundo).
--  - Oficiais (com a permissão "Gerenciar pilotos de contas") e o líder
--    marcam e desmarcam pela função set_pilot_only.
--  - Quem é só piloto não conta como membro: fica fora do rank de força,
--    da frequência, da contagem de membros e das listas dos eventos.
--  - Não responde eventos com a própria conta (só pelas contas que pilota)
--    e não pode ser pilotado por outra pessoa.
--
--  ATENÇÃO: ao MARCAR alguém como só piloto, as respostas e vagas em
--  times DA PRÓPRIA CONTA dessa pessoa em eventos que ainda não
--  começaram são apagadas, e quem pilotava a conta dela deixa de
--  pilotar. Eventos passados, presenças e histórico ficam guardados.
-- =====================================================================

alter table public.profiles add column if not exists pilot_only boolean not null default false;
-- Ninguém escreve direto na coluna (o "update" dos perfis é liberado só coluna a coluna);
-- a troca é feita pela função abaixo.

-- ---------- Oficiais e líder marcam / desmarcam ----------
create or replace function public.set_pilot_only(p_user uuid, p_value boolean) returns void
language plpgsql security definer set search_path = public as $$
declare
  me  text := public.my_role();
  t   public.profiles%rowtype;
  v   boolean := coalesce(p_value, false);
begin
  if me is distinct from 'leader' and me is distinct from 'officer' then
    raise exception 'Só oficiais e o líder podem marcar quem é só piloto' using errcode = '42501';
  end if;
  if p_user = auth.uid() then raise exception 'Peça a outro oficial ou ao líder para alterar o seu cadastro'; end if;
  select * into t from public.profiles where id = p_user;
  if not found then raise exception 'Membro não encontrado'; end if;
  if t.managed then raise exception 'Conta sem login é uma conta do jogo: não pode ser só piloto'; end if;
  if me = 'officer' then
    perform public.require_perm('pilots');
    if t.role not in ('pending', 'member') then
      raise exception 'Só o líder pode alterar o cadastro de oficiais e do líder' using errcode = '42501';
    end if;
  end if;
  if v = t.pilot_only then return; end if;

  update public.profiles set pilot_only = v where id = p_user;
  if v then
    -- Sai dos próximos eventos com a própria conta (o gatilho apaga a vaga no time junto)
    delete from public.rsvps r using public.events e
     where r.event_id = e.id and r.user_id = p_user and e.starts_at > now();
    -- Ninguém mais pilota esta pessoa (ela não tem conta própria no jogo)
    delete from public.account_pilots where account_id = p_user;
  end if;
  insert into public.profile_history (user_id, changed_by, changes)
  values (p_user, auth.uid(), jsonb_build_object('pilot_only', jsonb_build_array(t.pilot_only, v)));
end $$;

revoke execute on function public.set_pilot_only(uuid, boolean) from public, anon;
grant  execute on function public.set_pilot_only(uuid, boolean) to authenticated;

-- ---------- Só piloto não responde com a própria conta ----------
-- Se for a própria pessoa tentando, avisa. Se for automático (presença automática,
-- ausência programada) ou outra pessoa, simplesmente ignora a linha.
create or replace function public.rsvp_pilot_only_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.profiles where id = new.user_id and pilot_only) then
    if new.user_id = auth.uid() then
      raise exception 'Você está cadastrado só como piloto: escolha a conta que você pilota em “Respondendo como”';
    end if;
    return null;
  end if;
  return new;
end $$;

drop trigger if exists rsvps_pilot_only on public.rsvps;
create trigger rsvps_pilot_only before insert or update of user_id, going on public.rsvps
  for each row execute function public.rsvp_pilot_only_guard();

-- ---------- Só piloto não pode ser pilotado ----------
create or replace function public.pilot_only_account_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.profiles where id = new.account_id and pilot_only) then
    raise exception 'Esta pessoa está cadastrada só como piloto (não tem conta própria no jogo para ser pilotada)';
  end if;
  return new;
end $$;

drop trigger if exists account_pilots_pilot_only on public.account_pilots;
create trigger account_pilots_pilot_only before insert or update of account_id on public.account_pilots
  for each row execute function public.pilot_only_account_guard();

revoke execute on function public.rsvp_pilot_only_guard(), public.pilot_only_account_guard() from public, anon, authenticated;

-- ---------- Membros comuns também enxergam quem é só piloto ----------
-- (mesma visão de antes, com a coluna nova no fim)
create or replace view public.member_directory
with (security_barrier = true) as
select p.id, p.discord_name, p.game_name, p.role, p.managed,
       p.char_class, p.armor, p.armor_pen, p.potency, p.resistance, p.resonance,
       case when p.avatar_hidden then null else p.avatar_url end        as avatar_url,
       case when p.avatar_hidden then null else p.custom_avatar_url end as custom_avatar_url,
       p.avatar_hidden, p.pilot_only
  from public.profiles p
 where public.is_member() and p.role in ('member', 'officer', 'leader');

-- ---------- Busca de conta para pedir acesso: só piloto não aparece ----------
create or replace function public.find_accounts(p_q text) returns json
language sql stable security definer set search_path = public as $$
  with q as (
    select replace(replace(replace(trim(coalesce(p_q, '')), '\', '\'), '%', '\%'), '_', '\_') as s
  )
  select case when not public.is_member() or char_length((select s from q)) < 3 then '[]'::json
    else coalesce((select json_agg(x) from (
      select p.id, coalesce(nullif(trim(p.game_name), ''), p.discord_name) as game_name, p.char_class
        from public.profiles p
       where p.role in ('member', 'officer', 'leader') and p.id <> auth.uid() and not p.pilot_only
         and (coalesce(nullif(trim(p.game_name), ''), p.discord_name) ilike '%' || (select s from q) || '%'
              or coalesce(p.alias, '') ilike '%' || (select s from q) || '%')
       order by 2 limit 8) x), '[]'::json) end
$$;
