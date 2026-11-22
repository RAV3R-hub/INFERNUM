-- =====================================================================
--  Liderança move membros entre "Vou", "Não vou" e "Sem resposta"
--  Rode este arquivo uma vez no Supabase (SQL Editor). Pode rodar de novo.
--  Precisa do historico_eventos.sql (histórico de alterações do evento).
--
--  - staff_set_rsvp: oficiais (permissão "Mover membros entre as listas")
--    e o líder mudam a resposta de um membro num evento que ainda não
--    terminou. Para "Vou", a classe e os atributos vêm do perfil atual.
--  - Cada mudança entra no Histórico de alterações do evento: quem fez,
--    quando, qual membro e de qual lista para qual.
--
--  Não altera nem apaga dados existentes. Só amplia a lista de tipos do
--  histórico (inclui "rsvp") e cria uma função.
-- =====================================================================

alter table public.event_log drop constraint if exists event_log_kind_check;
alter table public.event_log add constraint event_log_kind_check
  check (kind in ('created', 'edit', 'format', 'rename', 'lock', 'unlock', 'room', 'rsvp'));

create or replace function public.staff_set_rsvp(p_event bigint, p_user uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare
  e      public.events%rowtype;
  p      public.profiles%rowtype;
  r      public.rsvps%rowtype;
  v_from text;
  v_go   boolean := p_status = 'going';
begin
  if not public.is_officer() then
    raise exception 'Só oficiais e o líder podem mudar a resposta de outro membro' using errcode = '42501';
  end if;
  perform public.require_perm('rsvp_manage');
  if p_status is null or p_status not in ('going', 'not_going', 'none') then raise exception 'Opção inválida'; end if;

  select * into e from public.events where id = p_event;
  if not found then raise exception 'Evento não encontrado'; end if;
  if e.starts_at < now() - interval '20 minutes' then
    raise exception 'Este evento já terminou: use “Registrar presença”';
  end if;

  select * into p from public.profiles where id = p_user;
  if not found or p.role not in ('member', 'officer', 'leader') then raise exception 'Esta pessoa não está ativa no clã'; end if;
  if coalesce(p.pilot_only, false) then raise exception 'Esta pessoa é só piloto: mova a conta que ela pilota'; end if;

  select * into r from public.rsvps where event_id = p_event and user_id = p_user;
  v_from := case when not found then 'none' when r.going then 'going' else 'not_going' end;
  if v_from = p_status then return; end if;

  if p_status = 'none' then
    delete from public.rsvps where event_id = p_event and user_id = p_user;
  elsif v_from = 'none' then
    insert into public.rsvps (event_id, user_id, going, discord, auto,
                              char_class, armor, armor_pen, potency, resistance, resonance)
    values (p_event, p_user, v_go, null, false,
            case when v_go then p.char_class end, case when v_go then p.armor end, case when v_go then p.armor_pen end,
            case when v_go then p.potency end, case when v_go then p.resistance end, case when v_go then p.resonance end);
  else
    update public.rsvps
       set going = v_go, discord = null, auto = false,
           withdraw_reason = null, withdraw_requested_at = null,
           char_class = case when v_go then p.char_class else char_class end,
           armor      = case when v_go then p.armor      else armor end,
           armor_pen  = case when v_go then p.armor_pen  else armor_pen end,
           potency    = case when v_go then p.potency    else potency end,
           resistance = case when v_go then p.resistance else resistance end,
           resonance  = case when v_go then p.resonance  else resonance end
     where event_id = p_event and user_id = p_user;
  end if;

  insert into public.event_log (event_id, actor, kind, detail)
  values (p_event, auth.uid(), 'rsvp', jsonb_build_object('user', p_user, 'from', v_from, 'to', p_status));
end $$;

revoke execute on function public.staff_set_rsvp(bigint, uuid, text) from public, anon;
grant  execute on function public.staff_set_rsvp(bigint, uuid, text) to authenticated;
