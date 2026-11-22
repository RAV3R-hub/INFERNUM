-- =====================================================================
--  Configurações do membro (Novembro/2026)
--  Primeira opção: confirmar presença automaticamente nas Guerras e Vigílias.
--  • Quando a liderança cria uma Guerra ou Vigília, quem ligou a opção já
--    entra como "Vou", com a classe e os atributos do perfil e a resposta do
--    Discord escolhida para aquele tipo de evento.
--  • Ao ligar, as Guerras e Vigílias já agendadas sem resposta também são
--    confirmadas (dentro do prazo de resposta). Nunca troca uma resposta dada.
--  • Com ausência programada no dia, não confirma (a ausência já marca "Não vou").
--  • A confirmação automática fica marcada (rsvps.auto) e aparece como
--    "confirmação automática" na lista do evento, em vez de "respondido por".
--  Cria uma tabela e uma coluna novas e troca a função que registra quem
--  respondeu (só para não marcar quem criou o evento como autor da resposta).
--  Nenhum dado existente é alterado ou apagado. Pode ser executado de novo.
-- =====================================================================

create table if not exists public.member_settings (
  user_id            uuid primary key references public.profiles(id) on delete cascade,
  auto_war           boolean not null default false,
  auto_war_discord   boolean,
  auto_vigil         boolean not null default false,
  auto_vigil_discord boolean,
  updated_at         timestamptz not null default now()
);
alter table public.member_settings enable row level security;
-- Ver: a própria conta, quem pilota a conta e a liderança. Escrever: só pela função abaixo.
drop policy if exists "member_settings_select" on public.member_settings;
create policy "member_settings_select" on public.member_settings
  for select to authenticated using (public.can_act_as(user_id) or public.is_officer());

-- Resposta criada pela confirmação automática
alter table public.rsvps add column if not exists auto boolean not null default false;

-- Quem respondeu: a confirmação automática não tem autor; quem muda a resposta depois vira o autor
create or replace function public.set_answered_by() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then new.auto := false; end if;
  if new.auto then
    new.answered_by := null;
  elsif auth.uid() is not null then
    new.answered_by := auth.uid();
  end if;
  return new;
end $$;

-- A conta quer confirmar sozinha este tipo de evento? Devolve a resposta do Discord
-- (true / false) ou null quando não quer.
create or replace function public.auto_rsvp_discord(s public.member_settings, p_type bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select case when s.auto_war and t.name ilike '%guerra%' then s.auto_war_discord
              when s.auto_vigil and t.name ilike '%vig_lia%' then s.auto_vigil_discord end
    from public.event_types t where t.id = p_type
$$;

-- Confirma a conta nos eventos futuros sem resposta (devolve quantos)
create or replace function public.apply_auto_rsvp(p_user uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare s public.member_settings; n integer;
begin
  select * into s from public.member_settings where user_id = p_user;
  if not found or not (s.auto_war or s.auto_vigil) or not public.is_active_account(p_user) then return 0; end if;
  insert into public.rsvps (event_id, user_id, going, discord, auto, updated_at,
                            char_class, armor, armor_pen, potency, resistance, resonance)
  select e.id, p.id, true, public.auto_rsvp_discord(s, e.type_id), true, now(),
         p.char_class, p.armor, p.armor_pen, p.potency, p.resistance, p.resonance
    from public.events e
    join public.profiles p on p.id = p_user
   where e.starts_at > now()
     and public.auto_rsvp_discord(s, e.type_id) is not null
     and public.can_change_rsvp_for(e.id, p_user)
     and not exists (select 1 from public.rsvps r where r.event_id = e.id and r.user_id = p_user)
     and not exists (select 1 from public.absences a where a.user_id = p_user
                       and public.event_day(e.starts_at) between a.starts_on and a.ends_on)
  on conflict (event_id, user_id) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- Salva as configurações (a própria conta ou quem pilota). Devolve quantos eventos foram confirmados.
create or replace function public.save_member_settings(p_user uuid, p_war boolean, p_war_discord boolean,
  p_vigil boolean, p_vigil_discord boolean) returns integer
language plpgsql security definer set search_path = public as $$
begin
  if not public.can_act_as(p_user) then
    raise exception 'Você não pode mudar as configurações desta conta' using errcode = '42501';
  end if;
  if not public.is_active_account(p_user) then raise exception 'Esta conta não está ativa no clã'; end if;
  if (coalesce(p_war, false) and p_war_discord is null) or (coalesce(p_vigil, false) and p_vigil_discord is null) then
    raise exception 'Diga se vai estar no Discord em cada tipo de evento marcado';
  end if;
  insert into public.member_settings (user_id, auto_war, auto_war_discord, auto_vigil, auto_vigil_discord, updated_at)
  values (p_user, coalesce(p_war, false), p_war_discord, coalesce(p_vigil, false), p_vigil_discord, now())
  on conflict (user_id) do update set auto_war = excluded.auto_war, auto_war_discord = excluded.auto_war_discord,
    auto_vigil = excluded.auto_vigil, auto_vigil_discord = excluded.auto_vigil_discord, updated_at = now();
  return public.apply_auto_rsvp(p_user);
end $$;

-- Evento novo: confirma quem pediu (depois das ausências, que já marcaram "Não vou")
create or replace function public.events_auto_rsvp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.starts_at > now() then
    insert into public.rsvps (event_id, user_id, going, discord, auto, updated_at,
                              char_class, armor, armor_pen, potency, resistance, resonance)
    select new.id, p.id, true, public.auto_rsvp_discord(s, new.type_id), true, now(),
           p.char_class, p.armor, p.armor_pen, p.potency, p.resistance, p.resonance
      from public.member_settings s
      join public.profiles p on p.id = s.user_id
     where (s.auto_war or s.auto_vigil)
       and public.auto_rsvp_discord(s, new.type_id) is not null
       and public.is_active_account(p.id)
       and not exists (select 1 from public.absences a where a.user_id = p.id
                         and public.event_day(new.starts_at) between a.starts_on and a.ends_on)
    on conflict (event_id, user_id) do nothing;
  end if;
  return new;
end $$;
drop trigger if exists events_auto_rsvp on public.events;
create trigger events_auto_rsvp after insert on public.events
  for each row execute function public.events_auto_rsvp();

revoke execute on function public.auto_rsvp_discord(public.member_settings, bigint) from public, anon, authenticated;
revoke execute on function public.apply_auto_rsvp(uuid) from public, anon, authenticated;
revoke execute on function public.save_member_settings(uuid, boolean, boolean, boolean, boolean) from public, anon;
grant  execute on function public.save_member_settings(uuid, boolean, boolean, boolean, boolean) to authenticated;
