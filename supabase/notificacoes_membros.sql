-- =====================================================================
--  Aviso no Discord (mensagem privada) sobre o acesso ao site (Novembro/2026)
--  O bot do INFERNUM manda uma DM curta quando a liderança:
--    • APROVA o acesso de quem estava aguardando (primeira vez no clã);
--    • READMITE um ex-membro (direto ou pelo pedido de volta);
--    • RECUSA a entrada de quem estava aguardando (sem o motivo).
--  Usa a mesma Edge Function "ticket-notify" dos tickets (cole a versão
--  nova de supabase/functions/ticket-notify/index.ts no Supabase).
--  A chave publicável é a mesma que você já colou no aviso dos tickets:
--  este SQL a lê de lá, então não é preciso colar de novo.
--  Contas sem login (pilotadas) não recebem aviso. Se o envio falhar, a
--  aprovação no site continua funcionando normalmente.
--  Só ADICIONA tabela, funções e gatilho. Nenhum dado existente é
--  alterado ou apagado. Pode ser executado de novo.
-- =====================================================================

create table if not exists public.member_notifications (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  kind       text not null check (kind in ('approved', 'readmitted', 'refused')),
  actor_id   uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  sent_at    timestamptz,
  error      text
);
create index if not exists member_notifications_user_idx on public.member_notifications (user_id, created_at desc);

-- Ninguém do site lê ou escreve nesta fila (só a Edge Function, com a chave de serviço)
alter table public.member_notifications enable row level security;

-- Chave publicável já cadastrada no aviso dos tickets (supabase/notificacoes_discord.sql)
create or replace function public.notify_publishable_key() returns text
language sql stable security definer set search_path = public as $$
  select substring(pg_get_functiondef('public.queue_ticket_notification(bigint, text)'::regprocedure)
                   from 'sb_publishable_[A-Za-z0-9_-]+')
$$;
revoke execute on function public.notify_publishable_key() from public, anon, authenticated;

-- Guarda o aviso e chama a Edge Function (sem nunca travar a ação no site)
create or replace function public.queue_member_notification(p_user uuid, p_kind text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_id  bigint;
  v_key text;
begin
  insert into public.member_notifications (user_id, kind, actor_id)
  values (p_user, p_kind, auth.uid()) returning id into v_id;
  begin
    v_key := public.notify_publishable_key();
    if v_key is null then raise exception 'chave publicável não encontrada no aviso dos tickets'; end if;
    perform net.http_post(
      url     := 'https://xvqxggkmrurvcbaxyifh.supabase.co/functions/v1/ticket-notify',
      body    := jsonb_build_object('id', v_id, 'type', 'member'),
      headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', v_key, 'Authorization', 'Bearer ' || v_key));
  exception when others then
    update public.member_notifications set error = left('Falha ao chamar a função: ' || sqlerrm, 300) where id = v_id;
  end;
end $$;
revoke execute on function public.queue_member_notification(uuid, text) from public, anon, authenticated;

-- Mudança de cargo feita pela liderança
create or replace function public.profiles_notify_role() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.managed or auth.uid() is null or auth.uid() = new.id then return new; end if;
  if new.role = 'member' and old.role = 'former' then
    perform public.queue_member_notification(new.id, 'readmitted');
  elsif new.role = 'member' and old.role = 'pending' then
    -- Já foi do clã antes? Então é um retorno
    if exists (select 1 from public.membership_log l where l.user_id = new.id and l.to_role = 'former') then
      perform public.queue_member_notification(new.id, 'readmitted');
    else
      perform public.queue_member_notification(new.id, 'approved');
    end if;
  elsif new.role = 'former' and old.role = 'pending' then
    perform public.queue_member_notification(new.id, 'refused');
  end if;
  return new;
end $$;
drop trigger if exists profiles_notify_role on public.profiles;
create trigger profiles_notify_role after update of role on public.profiles
  for each row when (old.role is distinct from new.role)
  execute function public.profiles_notify_role();

-- Usada só pela Edge Function: pega o aviso pendente (uma única vez)
create or replace function public.claim_member_notification(p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare n public.member_notifications; v_discord text;
begin
  update public.member_notifications set sent_at = now()
   where id = p_id and sent_at is null and error is null and created_at > now() - interval '1 hour'
  returning * into n;
  if not found then return null; end if;
  select coalesce(i.identity_data ->> 'sub', i.identity_data ->> 'provider_id', i.provider_id) into v_discord
    from auth.identities i where i.user_id = n.user_id and i.provider = 'discord'
   order by i.updated_at desc nulls last limit 1;
  return json_build_object('id', n.id, 'kind', n.kind, 'discord_id', v_discord);
end $$;

create or replace function public.fail_member_notification(p_id bigint, p_error text) returns void
language sql security definer set search_path = public as $$
  update public.member_notifications set sent_at = null, error = left(coalesce(p_error, 'erro'), 300) where id = p_id;
$$;

revoke execute on function public.claim_member_notification(bigint) from public, anon, authenticated;
revoke execute on function public.fail_member_notification(bigint, text) from public, anon, authenticated;
grant  execute on function public.claim_member_notification(bigint) to service_role;
grant  execute on function public.fail_member_notification(bigint, text) to service_role;
