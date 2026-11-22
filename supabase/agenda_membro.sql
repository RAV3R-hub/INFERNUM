-- =====================================================================
--  Lembretes na agenda do celular (Novembro/2026)
--  Rode DEPOIS de configuracoes_rito.sql (usa a função event_type_key de lá).
--  Cada membro escolhe em "Minhas configurações" o que quer lembrar e, para
--  cada item, com quanto tempo de antecedência. Ao salvar, o site adiciona um
--  link pessoal (com um código secreto) no Google Agenda ou no iPhone.
--  A Edge Function "agenda" monta a agenda na hora:
--  • Guerras, Vigílias e Ritos: os eventos JÁ CRIADOS no site daqueles tipos
--    (pelo tipo escolhido pela liderança), sem os que ele respondeu "Não vou".
--  • Cofre (seg a sáb, 12h–13h e 19h–20h) e Assembleia (seg a sáb, 12h–14h e
--    19h–21h, só no ciclo das Sombras): eventos do jogo, nos horários escolhidos.
--  Só CRIA uma tabela e funções novas. Nenhum dado existente é alterado ou
--  apagado. Pode ser executado de novo.
-- =====================================================================

create table if not exists public.member_calendar (
  user_id        uuid primary key references public.profiles(id) on delete cascade,
  token          text not null unique default replace(gen_random_uuid()::text, '-', ''),
  cal_war        boolean not null default false,
  war_alarm      integer not null default 0 check (war_alarm in (0, 15, 30, 60, 120)),
  cal_vigil      boolean not null default false,
  vigil_alarm    integer not null default 0 check (vigil_alarm in (0, 15, 30, 60, 120)),
  cal_rite       boolean not null default false,
  rite_alarm     integer not null default 0 check (rite_alarm in (0, 15, 30, 60, 120)),
  cal_vault      boolean not null default false,
  vault_slot     text not null default 'both' check (vault_slot in ('12', '19', 'both')),
  vault_alarm    integer not null default 0 check (vault_alarm in (0, 15, 30, 60, 120)),
  cal_assembly   boolean not null default false,
  assembly_slot  text not null default 'both' check (assembly_slot in ('12', '19', 'both')),
  assembly_alarm integer not null default 0 check (assembly_alarm in (0, 15, 30, 60, 120)),
  updated_at     timestamptz not null default now()
);
alter table public.member_calendar enable row level security;
-- Ver: só a própria conta e quem pilota (o link é pessoal). Escrever: só pela função abaixo.
drop policy if exists "member_calendar_select" on public.member_calendar;
create policy "member_calendar_select" on public.member_calendar
  for select to authenticated using (public.can_act_as(user_id));

-- Salva a escolha (p = { cal_war, war_alarm, ..., cal_vault, vault_slot, vault_alarm, ... }) e devolve o código do link
create or replace function public.save_member_calendar(p_user uuid, p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare v_token text; k text;
begin
  if not public.can_act_as(p_user) then
    raise exception 'Você não pode mudar as configurações desta conta' using errcode = '42501';
  end if;
  if not public.is_active_account(p_user) then raise exception 'Esta conta não está ativa no clã'; end if;
  foreach k in array array['war', 'vigil', 'rite', 'vault', 'assembly'] loop
    if coalesce(p->>(k || '_alarm'), '0') not in ('0', '15', '30', '60', '120') then
      raise exception 'Antecedência do lembrete inválida';
    end if;
  end loop;
  foreach k in array array['vault', 'assembly'] loop
    if coalesce(p->>(k || '_slot'), 'both') not in ('12', '19', 'both') then raise exception 'Horário do lembrete inválido'; end if;
  end loop;
  insert into public.member_calendar (user_id, cal_war, war_alarm, cal_vigil, vigil_alarm, cal_rite, rite_alarm,
                                      cal_vault, vault_slot, vault_alarm, cal_assembly, assembly_slot, assembly_alarm, updated_at)
  values (p_user,
          coalesce((p->>'cal_war')::boolean, false), coalesce((p->>'war_alarm')::int, 0),
          coalesce((p->>'cal_vigil')::boolean, false), coalesce((p->>'vigil_alarm')::int, 0),
          coalesce((p->>'cal_rite')::boolean, false), coalesce((p->>'rite_alarm')::int, 0),
          coalesce((p->>'cal_vault')::boolean, false), coalesce(p->>'vault_slot', 'both'), coalesce((p->>'vault_alarm')::int, 0),
          coalesce((p->>'cal_assembly')::boolean, false), coalesce(p->>'assembly_slot', 'both'), coalesce((p->>'assembly_alarm')::int, 0),
          now())
  on conflict (user_id) do update set
    cal_war = excluded.cal_war, war_alarm = excluded.war_alarm,
    cal_vigil = excluded.cal_vigil, vigil_alarm = excluded.vigil_alarm,
    cal_rite = excluded.cal_rite, rite_alarm = excluded.rite_alarm,
    cal_vault = excluded.cal_vault, vault_slot = excluded.vault_slot, vault_alarm = excluded.vault_alarm,
    cal_assembly = excluded.cal_assembly, assembly_slot = excluded.assembly_slot, assembly_alarm = excluded.assembly_alarm,
    updated_at = now()
  returning token into v_token;
  return v_token;
end $$;

-- Agenda de um link (usada só pela Edge Function "agenda", com a chave de serviço)
create or replace function public.calendar_feed(p_token text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'name', coalesce(nullif(trim(p.game_name), ''), p.discord_name),
    'events', coalesce((
      select json_agg(json_build_object('id', e.id, 'title', e.title, 'starts_at', e.starts_at,
                                        'description', e.description, 'alarm', x.alarm) order by e.starts_at)
        from public.events e
        cross join lateral (
          select case public.event_type_key(e.type_id)
                   when 'war'   then case when c.cal_war   then c.war_alarm end
                   when 'vigil' then case when c.cal_vigil then c.vigil_alarm end
                   when 'rite'  then case when c.cal_rite  then c.rite_alarm end
                 end as alarm) x
       where e.starts_at > now() - interval '7 days'
         and x.alarm is not null
         and not exists (select 1 from public.rsvps r
                          where r.event_id = e.id and r.user_id = c.user_id and not r.going)
    ), '[]'::json),
    'vault', case when c.cal_vault then json_build_object('slot', c.vault_slot, 'alarm', c.vault_alarm) end,
    'assembly', case when c.cal_assembly then json_build_object('slot', c.assembly_slot, 'alarm', c.assembly_alarm) end,
    'cycles', coalesce((select json_agg(json_build_object('starts_on', cy.starts_on, 'side', cy.side) order by cy.starts_on)
                          from public.clan_cycles cy), '[]'::json))
  from public.member_calendar c
  join public.profiles p on p.id = c.user_id
  where c.token = p_token and public.is_active_account(c.user_id)
$$;

revoke execute on function public.save_member_calendar(uuid, jsonb) from public, anon;
revoke execute on function public.calendar_feed(text) from public, anon, authenticated;
grant  execute on function public.save_member_calendar(uuid, jsonb) to authenticated;
grant  execute on function public.calendar_feed(text) to service_role;
