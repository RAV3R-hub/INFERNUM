-- =====================================================================
--  Aviso no Discord (mensagem privada) para quem abriu o ticket (Novembro/2026)
--  Quando alguém da liderança RESPONDE (sem ser nota interna), ASSUME ou
--  ENCERRA (Resolvido) um ticket, o bot do INFERNUM manda uma DM para o
--  autor com um aviso curto e o link. O texto da resposta fica só no site.
--
--  Como funciona: os gatilhos guardam o aviso numa fila e chamam a Edge
--  Function "ticket-notify", que envia a DM e marca o aviso como enviado.
--  Se o envio falhar (função não publicada, membro sem Discord, DM
--  fechada), a resposta no site continua funcionando normalmente.
--
--  Antes de rodar: publique a Edge Function e cadastre o segredo
--  DISCORD_BOT_TOKEN (veja supabase/functions/ticket-notify/index.ts).
--  Só ADICIONA extensão, tabela, funções e gatilhos. Nenhum dado existente
--  é alterado ou apagado.
-- =====================================================================

create extension if not exists pg_net;

create table if not exists public.ticket_notifications (
  id         bigint generated always as identity primary key,
  ticket_id  bigint not null references public.tickets(id) on delete cascade,
  kind       text not null check (kind in ('reply', 'assigned', 'closed')),
  actor_id   uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  sent_at    timestamptz,
  error      text
);
create index if not exists ticket_notifications_ticket_idx on public.ticket_notifications (ticket_id, created_at desc);

-- Ninguém do site lê ou escreve nesta fila (só a Edge Function, com a chave de serviço)
alter table public.ticket_notifications enable row level security;

-- Guarda o aviso e chama a Edge Function (sem nunca travar a ação no site)
create or replace function public.queue_ticket_notification(p_ticket bigint, p_kind text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_id  bigint;
  -- Chave PUBLICÁVEL do projeto (Project Settings → API Keys → começa com sb_publishable_).
  -- É pública (feita para ficar em sites). NUNCA coloque aqui a chave sb_secret_.
  v_key text := 'COLE_AQUI_A_CHAVE_sb_publishable';
begin
  insert into public.ticket_notifications (ticket_id, kind, actor_id)
  values (p_ticket, p_kind, auth.uid()) returning id into v_id;
  begin
    perform net.http_post(
      url     := 'https://xvqxggkmrurvcbaxyifh.supabase.co/functions/v1/ticket-notify',
      body    := jsonb_build_object('id', v_id),
      headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', v_key, 'Authorization', 'Bearer ' || v_key));
  exception when others then
    update public.ticket_notifications set error = left('Falha ao chamar a função: ' || sqlerrm, 300) where id = v_id;
  end;
end $$;
revoke execute on function public.queue_ticket_notification(bigint, text) from public, anon, authenticated;

-- Resposta da liderança (mensagem pública de quem não é o autor)
create or replace function public.tickets_notify_message() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not new.internal and exists (select 1 from public.tickets t
                                   where t.id = new.ticket_id and t.author_id is distinct from new.author_id) then
    perform public.queue_ticket_notification(new.ticket_id, 'reply');
  end if;
  return new;
end $$;
drop trigger if exists tickets_notify_message on public.ticket_messages;
create trigger tickets_notify_message after insert on public.ticket_messages
  for each row execute function public.tickets_notify_message();

-- Assumido por alguém da liderança / encerrado pela liderança
create or replace function public.tickets_notify_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.assigned_to is not null and new.assigned_to is distinct from old.assigned_to
     and new.assigned_to <> new.author_id then
    perform public.queue_ticket_notification(new.id, 'assigned');
  end if;
  if new.status = 'resolved' and old.status <> 'resolved'
     and auth.uid() is distinct from new.author_id then
    perform public.queue_ticket_notification(new.id, 'closed');
  end if;
  return new;
end $$;
drop trigger if exists tickets_notify_update on public.tickets;
create trigger tickets_notify_update after update of assigned_to, status on public.tickets
  for each row execute function public.tickets_notify_update();

-- Usada só pela Edge Function: pega o aviso pendente (uma única vez) e devolve
-- o que a mensagem precisa. O Discord do autor vem do login com Discord.
create or replace function public.claim_ticket_notification(p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare n public.ticket_notifications; t public.tickets; v_discord text; v_actor text;
begin
  update public.ticket_notifications set sent_at = now()
   where id = p_id and sent_at is null and error is null and created_at > now() - interval '1 hour'
  returning * into n;
  if not found then return null; end if;
  select * into t from public.tickets where id = n.ticket_id;
  if not found then return null; end if;
  select coalesce(i.identity_data ->> 'sub', i.identity_data ->> 'provider_id', i.provider_id) into v_discord
    from auth.identities i where i.user_id = t.author_id and i.provider = 'discord'
   order by i.updated_at desc nulls last limit 1;
  select coalesce(nullif(p.game_name, ''), nullif(p.discord_name, ''), 'A liderança') into v_actor
    from public.profiles p where p.id = n.actor_id;
  return json_build_object('id', n.id, 'kind', n.kind, 'ticket_id', t.id, 'title', t.title,
                           'discord_id', v_discord, 'actor', coalesce(v_actor, 'A liderança'));
end $$;

-- A Edge Function registra quando o Discord recusou o envio
create or replace function public.fail_ticket_notification(p_id bigint, p_error text) returns void
language sql security definer set search_path = public as $$
  update public.ticket_notifications set sent_at = null, error = left(coalesce(p_error, 'erro'), 300) where id = p_id;
$$;

revoke execute on function public.claim_ticket_notification(bigint) from public, anon, authenticated;
revoke execute on function public.fail_ticket_notification(bigint, text) from public, anon, authenticated;
grant  execute on function public.claim_ticket_notification(bigint) to service_role;
grant  execute on function public.fail_ticket_notification(bigint, text) to service_role;
