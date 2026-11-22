-- =====================================================================
--  Times com a classe e os atributos ATUAIS do perfil (Novembro/2026)
--  Ao confirmar presença, a resposta guarda uma "foto" da classe e dos
--  atributos. Com este arquivo, quando o membro (ou o líder) muda o perfil,
--  a foto é atualizada nos eventos que AINDA NÃO COMEÇARAM. Nos eventos que
--  já começaram ou passaram, a foto fica como estava (para consulta).
--
--  O que ALTERA: só a classe e os atributos guardados nas respostas "Vou"
--  de eventos futuros, que passam a ser iguais aos do perfil (inclusive uma
--  vez, agora, para quem já mudou o perfil depois de confirmar).
--  Não mexe em eventos passados, presenças, times, nem no perfil.
--  Pode ser executado de novo.
-- =====================================================================

create or replace function public.rsvps_follow_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.rsvps r
     set char_class = new.char_class, armor = new.armor, armor_pen = new.armor_pen,
         potency = new.potency, resistance = new.resistance, resonance = new.resonance
    from public.events e
   where e.id = r.event_id
     and r.user_id = new.id
     and r.going
     and e.starts_at > now()
     and (r.char_class, r.armor, r.armor_pen, r.potency, r.resistance, r.resonance)
         is distinct from (new.char_class, new.armor, new.armor_pen, new.potency, new.resistance, new.resonance);
  return new;
end $$;

drop trigger if exists profiles_follow_rsvps on public.profiles;
create trigger profiles_follow_rsvps
  after update of char_class, armor, armor_pen, potency, resistance, resonance on public.profiles
  for each row
  when ((old.char_class, old.armor, old.armor_pen, old.potency, old.resistance, old.resonance)
        is distinct from (new.char_class, new.armor, new.armor_pen, new.potency, new.resistance, new.resonance))
  execute function public.rsvps_follow_profile();

revoke execute on function public.rsvps_follow_profile() from public, anon, authenticated;

-- Acerta agora quem já mudou o perfil depois de confirmar (só eventos futuros)
update public.rsvps r
   set char_class = p.char_class, armor = p.armor, armor_pen = p.armor_pen,
       potency = p.potency, resistance = p.resistance, resonance = p.resonance
  from public.events e, public.profiles p
 where e.id = r.event_id
   and p.id = r.user_id
   and r.going
   and e.starts_at > now()
   and (r.char_class, r.armor, r.armor_pen, r.potency, r.resistance, r.resonance)
       is distinct from (p.char_class, p.armor, p.armor_pen, p.potency, p.resistance, p.resonance);
