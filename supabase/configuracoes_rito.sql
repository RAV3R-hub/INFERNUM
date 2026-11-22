-- =====================================================================
--  Configurações do membro: Rito do Exílio (Novembro/2026)
--  Rode DEPOIS de configuracoes_membro.sql (já rodado) e ANTES de agenda_membro.sql.
--  • Acrescenta o Rito do Exílio à presença automática (com a resposta do Discord).
--  • Cada opção vale para os eventos do TIPO escolhido pela liderança ao criar o
--    evento: tipo "Guerra…" → Guerras, "Vigília…" → Vigílias, "Rito…" → Ritos.
--  • Se a liderança trocar o tipo de um evento, a presença automática acompanha:
--    quem pediu o novo tipo é confirmado; as confirmações automáticas de quem não
--    pediu o novo tipo saem (respostas dadas pelo próprio membro nunca mudam).
--  Só ADICIONA duas colunas e troca funções. Nenhum dado existente é alterado ou
--  apagado. Pode ser executado de novo.
-- =====================================================================

alter table public.member_settings add column if not exists auto_rite boolean not null default false;
alter table public.member_settings add column if not exists auto_rite_discord boolean;

-- Tipo do evento → opção das configurações ('war', 'vigil', 'rite' ou null)
create or replace function public.event_type_key(p_type bigint) returns text
language sql stable security definer set search_path = public as $$
  select case when t.name ilike 'guerra%' then 'war'
              when t.name ilike 'vig_lia%' then 'vigil'
              when t.name ilike 'rito%' then 'rite' end
    from public.event_types t where t.id = p_type
$$;

-- A conta quer confirmar sozinha este tipo de evento? Devolve a resposta do Discord ou null
create or replace function public.auto_rsvp_discord(s public.member_settings, p_type bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select case public.event_type_key(p_type)
           when 'war'   then case when s.auto_war   then s.auto_war_discord end
           when 'vigil' then case when s.auto_vigil then s.auto_vigil_discord end
           when 'rite'  then case when s.auto_rite  then s.auto_rite_discord end
         end
$$;

-- Confirma a conta nos eventos futuros sem resposta (devolve quantos)
create or replace function public.apply_auto_rsvp(p_user uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare s public.member_settings; n integer;
begin
  select * into s from public.member_settings where user_id = p_user;
  if not found or not (s.auto_war or s.auto_vigil or s.auto_rite) or not public.is_active_account(p_user) then return 0; end if;
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

-- Salva as configurações com o Rito (a própria conta ou quem pilota). Devolve quantos eventos foram confirmados.
-- (A versão antiga, sem o Rito, continua existindo para o site antigo não quebrar até ser atualizado.)
create or replace function public.save_member_settings(p_user uuid, p_war boolean, p_war_discord boolean,
  p_vigil boolean, p_vigil_discord boolean, p_rite boolean, p_rite_discord boolean) returns integer
language plpgsql security definer set search_path = public as $$
begin
  if not public.can_act_as(p_user) then
    raise exception 'Você não pode mudar as configurações desta conta' using errcode = '42501';
  end if;
  if not public.is_active_account(p_user) then raise exception 'Esta conta não está ativa no clã'; end if;
  if (coalesce(p_war, false) and p_war_discord is null) or (coalesce(p_vigil, false) and p_vigil_discord is null)
     or (coalesce(p_rite, false) and p_rite_discord is null) then
    raise exception 'Diga se vai estar no Discord em cada tipo de evento marcado';
  end if;
  insert into public.member_settings (user_id, auto_war, auto_war_discord, auto_vigil, auto_vigil_discord,
                                      auto_rite, auto_rite_discord, updated_at)
  values (p_user, coalesce(p_war, false), p_war_discord, coalesce(p_vigil, false), p_vigil_discord,
          coalesce(p_rite, false), p_rite_discord, now())
  on conflict (user_id) do update set auto_war = excluded.auto_war, auto_war_discord = excluded.auto_war_discord,
    auto_vigil = excluded.auto_vigil, auto_vigil_discord = excluded.auto_vigil_discord,
    auto_rite = excluded.auto_rite, auto_rite_discord = excluded.auto_rite_discord, updated_at = now();
  return public.apply_auto_rsvp(p_user);
end $$;

-- Evento novo, ou tipo trocado: confirma quem pediu aquele tipo (depois das ausências, que já marcaram "Não vou")
create or replace function public.events_auto_rsvp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    if new.type_id is not distinct from old.type_id then return new; end if;
    -- Tipo trocado: tira as confirmações automáticas de quem não pediu o novo tipo
    delete from public.rsvps r
     using public.member_settings s
     where r.event_id = new.id and r.auto and r.going and s.user_id = r.user_id
       and public.auto_rsvp_discord(s, new.type_id) is null;
  end if;
  if new.starts_at > now() then
    insert into public.rsvps (event_id, user_id, going, discord, auto, updated_at,
                              char_class, armor, armor_pen, potency, resistance, resonance)
    select new.id, p.id, true, public.auto_rsvp_discord(s, new.type_id), true, now(),
           p.char_class, p.armor, p.armor_pen, p.potency, p.resistance, p.resonance
      from public.member_settings s
      join public.profiles p on p.id = s.user_id
     where (s.auto_war or s.auto_vigil or s.auto_rite)
       and public.auto_rsvp_discord(s, new.type_id) is not null
       and public.is_active_account(p.id)
       and not exists (select 1 from public.absences a where a.user_id = p.id
                         and public.event_day(new.starts_at) between a.starts_on and a.ends_on)
    on conflict (event_id, user_id) do nothing;
  end if;
  return new;
end $$;
drop trigger if exists events_auto_rsvp on public.events;
create trigger events_auto_rsvp after insert or update of type_id on public.events
  for each row execute function public.events_auto_rsvp();

revoke execute on function public.event_type_key(bigint) from public, anon;
grant  execute on function public.event_type_key(bigint) to authenticated;
revoke execute on function public.save_member_settings(uuid, boolean, boolean, boolean, boolean, boolean, boolean) from public, anon;
grant  execute on function public.save_member_settings(uuid, boolean, boolean, boolean, boolean, boolean, boolean) to authenticated;
