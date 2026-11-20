-- =====================================================================
--  Gerenciador de eventos do clã — esquema do banco (Supabase)
--  Cole TODO este arquivo no "SQL Editor" do Supabase e clique em "Run".
-- =====================================================================

-- ---------- Tabelas ----------------------------------------------------

-- Um perfil por pessoa que fez login com o Discord.
-- role: pending (aguardando aprovação), member, officer, leader
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  discord_name text not null default '',
  avatar_url   text,
  game_name    text check (game_name is null or char_length(game_name) <= 40),
  role         text not null default 'pending'
               check (role in ('pending', 'member', 'officer', 'leader')),
  created_at   timestamptz not null default now()
);

create table if not exists public.events (
  id          bigint generated always as identity primary key,
  title       text not null check (char_length(title) between 1 and 100),
  description text check (description is null or char_length(description) <= 1000),
  starts_at   timestamptz not null,
  created_by  uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists events_starts_at_idx on public.events (starts_at);

-- Resposta de cada membro a cada evento (true = vai, false = não vai)
create table if not exists public.rsvps (
  event_id   bigint not null references public.events(id) on delete cascade,
  user_id    uuid   not null references public.profiles(id) on delete cascade,
  going      boolean not null,
  updated_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

-- ---------- Classe e atributos ---------------------------------------
-- Classes: dh, cruzado, mago, bk, monge, druida, barbaro, necromante, bruxo, tempest

alter table public.profiles add column if not exists char_class text;
alter table public.profiles add column if not exists armor      integer;
alter table public.profiles add column if not exists armor_pen  integer;
alter table public.profiles add column if not exists potency    integer;
alter table public.profiles add column if not exists resistance integer;
alter table public.profiles add column if not exists resonance  integer;

-- Na resposta guardamos uma "foto" da classe/atributos confirmados para aquele evento
alter table public.rsvps add column if not exists char_class text;
alter table public.rsvps add column if not exists armor      integer;
alter table public.rsvps add column if not exists armor_pen  integer;
alter table public.rsvps add column if not exists potency    integer;
alter table public.rsvps add column if not exists resistance integer;
alter table public.rsvps add column if not exists resonance  integer;
-- Ao confirmar presença, o membro informa se vai usar o Discord no evento
alter table public.rsvps add column if not exists discord    boolean;

do $$
declare t text;
begin
  foreach t in array array['profiles', 'rsvps'] loop
    execute format('alter table public.%I drop constraint if exists %I', t, t || '_char_class_chk');
    execute format($f$alter table public.%I add constraint %I check (char_class is null or char_class in
      ('dh','cruzado','mago','bk','monge','druida','barbaro','necromante','bruxo','tempest'))$f$, t, t || '_char_class_chk');
    execute format('alter table public.%I drop constraint if exists %I', t, t || '_attrs_chk');
    execute format($f$alter table public.%I add constraint %I check (
      coalesce(armor, 0) between 0 and 1000000 and coalesce(armor_pen, 0) between 0 and 1000000 and
      coalesce(potency, 0) between 0 and 1000000 and coalesce(resistance, 0) between 0 and 1000000 and
      coalesce(resonance, 0) between 0 and 1000000)$f$, t, t || '_attrs_chk');
  end loop;
end $$;

-- ---------- Telefone de contato (opcional) ---------------------------
-- Tabela separada para que só o próprio membro, oficiais e o líder vejam o número.
create table if not exists public.member_contacts (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  phone   text check (phone is null or char_length(phone) <= 30)
);

-- ---------- Times ----------------------------------------------------
-- Formato do evento: 'guerra' (12 times fixos) ou 'rito' (até 10 times)
alter table public.events add column if not exists team_format text;
alter table public.events add column if not exists team_count  smallint not null default 10;
alter table public.events drop constraint if exists events_team_chk;
alter table public.events add constraint events_team_chk
  check ((team_format is null or team_format in ('guerra', 'rito')) and team_count between 1 and 10);

-- Em qual time cada membro está, por evento
create table if not exists public.team_slots (
  event_id bigint not null references public.events(id) on delete cascade,
  user_id  uuid   not null references public.profiles(id) on delete cascade,
  team     text   not null check (char_length(team) between 1 and 30),
  primary key (event_id, user_id)
);

-- ---------- Presença real ---------------------------------------------
-- Depois do evento, um oficial marca quem realmente compareceu.
create table if not exists public.attendance (
  event_id bigint  not null references public.events(id) on delete cascade,
  user_id  uuid    not null references public.profiles(id) on delete cascade,
  present  boolean not null,
  primary key (event_id, user_id)
);

-- ---------- Tipos de evento -------------------------------------------
-- Para criar um tipo novo: Supabase → Table Editor → event_types → Insert row.
--   name:       nome que aparece no site
--   sort_order: posição na lista (menor aparece primeiro)
--   active:     desmarque para esconder o tipo sem apagá-lo
create table if not exists public.event_types (
  id         bigint generated always as identity primary key,
  name       text not null unique check (char_length(name) between 1 and 60),
  sort_order integer not null default 50,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

insert into public.event_types (name, sort_order) values
  ('Guerra das Sombras', 10),
  ('Vigília',            20),
  ('Rito do Exílio',     30),
  ('Outros',            999)
on conflict (name) do nothing;

-- Um tipo em uso por algum evento não pode ser apagado (use "active = false" para escondê-lo)
alter table public.events add column if not exists type_id bigint
  references public.event_types(id) on delete restrict;
create index if not exists events_type_idx on public.events (type_id);

-- Classifica pelo nome os eventos que ainda não têm tipo
update public.events e
   set type_id = (select t.id from public.event_types t where t.name = case
                    when e.title ilike '%guerra%'   then 'Guerra das Sombras'
                    when e.title ilike '%vig_lia%'  then 'Vigília'
                    when e.title ilike '%rito%'     then 'Rito do Exílio'
                    else 'Outros' end)
 where e.type_id is null;

-- ---------- Histórico de alterações do perfil -------------------------
-- Toda mudança de nome (personagem ou Discord), classe ou atributos é registrada aqui.
-- changes = { "campo": [valor_antigo, valor_novo], ... }
create table if not exists public.profile_history (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  changed_at timestamptz not null default now(),
  changed_by uuid default auth.uid(),
  changes    jsonb not null
);
create index if not exists profile_history_user_idx on public.profile_history (user_id, changed_at desc);

-- ---------- Prazo de confirmação, times travados e pedidos de saída ----
-- rsvp_close_minutes: prazo para responder, em minutos antes do início (null = sem prazo)
-- teams_locked:       com os times travados, quem está escalado não sai sozinho; pede ao oficial
alter table public.events add column if not exists rsvp_close_minutes integer
  check (rsvp_close_minutes is null or rsvp_close_minutes between 0 and 10080);
alter table public.events add column if not exists teams_locked boolean not null default false;

-- Pedido de saída feito pelo membro quando já não pode mudar a resposta sozinho
alter table public.rsvps add column if not exists withdraw_reason       text
  check (withdraw_reason is null or char_length(withdraw_reason) <= 300);
alter table public.rsvps add column if not exists withdraw_requested_at timestamptz;

-- ---------- Anotações internas (oficiais e líder) ---------------------
create table if not exists public.member_notes (
  id         bigint generated always as identity primary key,
  member_id  uuid not null references public.profiles(id) on delete cascade,
  author_id  uuid default auth.uid() references public.profiles(id) on delete set null,
  body       text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index if not exists member_notes_member_idx on public.member_notes (member_id, created_at desc);

-- ---------- Ex-membros e histórico no clã -----------------------------
-- role 'former' = ex-membro: sai das listas, perde o acesso, mas o histórico é mantido.
-- Se a pessoa entrar de novo no site, pode pedir para voltar (vira 'pending').
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('pending', 'member', 'officer', 'leader', 'former'));

-- Toda mudança de cargo fica registrada (entrou, aprovado, promovido, removido, voltou...)
create table if not exists public.membership_log (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  from_role  text,
  to_role    text not null,
  changed_by uuid references public.profiles(id) on delete set null,
  reason     text check (reason is null or char_length(reason) <= 300),
  changed_at timestamptz not null default now()
);
create index if not exists membership_log_user_idx on public.membership_log (user_id, changed_at desc);

-- Quem já estava cadastrado antes do histórico existir ganha um registro inicial
insert into public.membership_log (user_id, from_role, to_role, reason, changed_at)
select p.id, null, p.role, 'Registro inicial (antes do histórico do clã)', p.created_at
  from public.profiles p
 where not exists (select 1 from public.membership_log m where m.user_id = p.id);

-- ---------- Malah News -------------------------------------------------
-- Edições (imagens) publicadas por oficiais e líder; membros veem.
create table if not exists public.news_posts (
  id           bigint generated always as identity primary key,
  title        text not null check (char_length(title) between 1 and 120),
  caption      text check (caption is null or char_length(caption) <= 2000),
  image_path   text not null,                 -- caminho do arquivo no bucket "news"
  author_id    uuid default auth.uid() references public.profiles(id) on delete set null,
  published_at timestamptz not null default now(),
  edited_at    timestamptz
);
create index if not exists news_posts_published_idx on public.news_posts (published_at desc);

-- Espaço PRIVADO para as imagens (até 10 MB cada; só imagens)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('news', 'news', false, 10485760, array['image/png', 'image/jpeg', 'image/webp', 'image/gif'])
on conflict (id) do nothing;

-- ---------- Funções auxiliares ----------------------------------------

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid()
$$;

create or replace function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() in ('member', 'officer', 'leader'), false)
$$;

create or replace function public.is_officer() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() in ('officer', 'leader'), false)
$$;

-- Cria o perfil automaticamente no primeiro login com o Discord
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, discord_name, avatar_url)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data -> 'custom_claims' ->> 'global_name',
      new.raw_user_meta_data ->> 'full_name',
      new.raw_user_meta_data ->> 'name',
      'Sem nome'
    ),
    new.raw_user_meta_data ->> 'avatar_url'
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Alterar cargo de alguém.
--   Líder:   pode definir qualquer cargo para qualquer pessoa.
--   Oficial: pode apenas aprovar (pending -> member) ou tirar o acesso de membros comuns.
--   Ninguém altera o próprio cargo.
create or replace function public.set_member_role(target uuid, new_role text) returns void
language plpgsql security definer set search_path = public as $$
declare
  me  text := public.my_role();
  cur text;
begin
  if new_role not in ('pending', 'member', 'officer', 'leader') then
    raise exception 'Cargo inválido';
  end if;
  if target = auth.uid() then
    raise exception 'Você não pode alterar o próprio cargo';
  end if;
  select role into cur from public.profiles where id = target;
  if cur is null then
    raise exception 'Membro não encontrado';
  end if;
  if me = 'leader' then
    null;
  elsif me = 'officer' and cur in ('pending', 'member') and new_role in ('pending', 'member') then
    null;
  else
    raise exception 'Sem permissão para essa alteração';
  end if;
  update public.profiles set role = new_role where id = target;
end $$;

revoke execute on function public.set_member_role(uuid, text) from public, anon;
grant  execute on function public.set_member_role(uuid, text) to authenticated;

-- Remover do clã (ou recusar quem está aguardando aprovação).
--   Líder:   qualquer pessoa (menos ele mesmo).
--   Oficial: só quem está aguardando aprovação ou é membro comum.
-- Mantém presenças passadas, histórico e anotações; apaga respostas/vagas de eventos futuros e o telefone.
-- with_managed: remove junto as contas sem login que só essa pessoa pilotava.
drop function if exists public.remove_member(uuid, text);

create or replace function public.remove_member(target uuid, reason text, with_managed boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare
  me  text := public.my_role();
  cur text;
  acc uuid;
begin
  if target = auth.uid() then
    raise exception 'Você não pode remover a si mesmo';
  end if;
  select role into cur from public.profiles where id = target;
  if cur is null then
    raise exception 'Membro não encontrado';
  end if;
  if cur = 'former' then
    raise exception 'Esta pessoa já é ex-membro';
  end if;
  if not (me = 'leader' or (me = 'officer' and cur in ('pending', 'member'))) then
    raise exception 'Sem permissão para remover esta pessoa';
  end if;
  perform set_config('infernum.reason', left(coalesce(nullif(trim(reason), ''), ''), 300), true);
  update public.profiles set role = 'former' where id = target;
  delete from public.rsvps r
   using public.events e
   where r.event_id = e.id and r.user_id = target and e.starts_at > now();
  delete from public.member_contacts where user_id = target;
  -- Contas sem login que só ele pilotava
  if with_managed then
    for acc in
      select a.account_id
        from public.account_pilots a
        join public.profiles p on p.id = a.account_id
       where a.pilot_id = target and a.status = 'approved' and p.managed and p.role <> 'former'
         and not exists (select 1 from public.account_pilots b
                          where b.account_id = a.account_id and b.pilot_id <> target and b.status = 'approved')
    loop
      perform set_config('infernum.reason', 'Removida junto com o piloto', true);
      update public.profiles set role = 'former' where id = acc;
      delete from public.rsvps r
       using public.events e
       where r.event_id = e.id and r.user_id = acc and e.starts_at > now();
    end loop;
  end if;
  -- Quem sai do clã deixa de pilotar contas
  delete from public.account_pilots where pilot_id = target;
end $$;

-- Ex-membro pede para voltar (aparece de novo em "Aguardando aprovação")
create or replace function public.request_rejoin() returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() is distinct from 'former' then
    raise exception 'Você não é ex-membro';
  end if;
  perform set_config('infernum.reason', 'Pediu para voltar ao clã', true);
  update public.profiles set role = 'pending' where id = auth.uid();
end $$;

revoke execute on function public.remove_member(uuid, text, boolean) from public, anon;
revoke execute on function public.request_rejoin()                    from public, anon;
grant  execute on function public.remove_member(uuid, text, boolean) to authenticated;
grant  execute on function public.request_rejoin()                    to authenticated;

-- Registra toda mudança de cargo no histórico do clã
create or replace function public.log_role_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.membership_log (user_id, from_role, to_role, changed_by, reason)
    values (new.id, null, new.role, auth.uid(),
            coalesce(nullif(current_setting('infernum.reason', true), ''), 'Primeiro acesso ao site'));
  elsif old.role is distinct from new.role then
    insert into public.membership_log (user_id, from_role, to_role, changed_by, reason)
    values (new.id, old.role, new.role, auth.uid(), nullif(current_setting('infernum.reason', true), ''));
  end if;
  return new;
end $$;

drop trigger if exists profiles_log_role on public.profiles;
create trigger profiles_log_role
  after insert or update of role on public.profiles
  for each row execute function public.log_role_change();

-- Registra no histórico qualquer mudança de nome, classe ou atributos
create or replace function public.log_profile_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  diff jsonb := '{}'::jsonb;
  f    text;
  o    jsonb := to_jsonb(old);
  n    jsonb := to_jsonb(new);
begin
  foreach f in array array['discord_name', 'game_name', 'char_class',
                           'armor', 'armor_pen', 'potency', 'resistance', 'resonance'] loop
    if (o -> f) is distinct from (n -> f) then
      diff := diff || jsonb_build_object(f, jsonb_build_array(o -> f, n -> f));
    end if;
  end loop;
  if diff <> '{}'::jsonb then
    insert into public.profile_history (user_id, changes) values (new.id, diff);
  end if;
  return new;
end $$;

drop trigger if exists profiles_log_change on public.profiles;
create trigger profiles_log_change
  after update on public.profiles
  for each row execute function public.log_profile_change();

-- Chamada pelo site a cada login: atualiza nome e foto do Discord (se mudaram)
create or replace function public.sync_discord_profile() returns void
language plpgsql security definer set search_path = public as $$
declare
  meta   jsonb;
  name   text;
  avatar text;
begin
  select raw_user_meta_data into meta from auth.users where id = auth.uid();
  if meta is null then return; end if;
  name   := coalesce(meta -> 'custom_claims' ->> 'global_name', meta ->> 'full_name', meta ->> 'name');
  avatar := meta ->> 'avatar_url';
  update public.profiles
     set discord_name = coalesce(name, discord_name),
         avatar_url   = coalesce(avatar, avatar_url)
   where id = auth.uid()
     and (discord_name is distinct from coalesce(name, discord_name)
          or avatar_url is distinct from coalesce(avatar, avatar_url));
end $$;

revoke execute on function public.sync_discord_profile() from public, anon;
grant  execute on function public.sync_discord_profile() to authenticated;

-- Times: só entra quem confirmou presença, e no máximo 8 por time
create or replace function public.team_slot_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.rsvps
                 where event_id = new.event_id and user_id = new.user_id and going) then
    raise exception 'Este membro não confirmou presença no evento';
  end if;
  if (select count(*) from public.team_slots
      where event_id = new.event_id and team = new.team and user_id <> new.user_id) >= 8 then
    raise exception 'O time % já tem 8 membros', new.team;
  end if;
  return new;
end $$;

drop trigger if exists team_slot_check on public.team_slots;
create trigger team_slot_check
  before insert or update on public.team_slots
  for each row execute function public.team_slot_check();

-- Salva todos os times de um evento de uma vez (botão "Salvar" do painel).
-- Roda numa única transação: se algo falhar (ex.: time com mais de 8), nada é alterado.
create or replace function public.save_teams(p_event bigint, p_slots jsonb) returns void
language plpgsql security invoker set search_path = public as $$
begin
  if not public.is_officer() then
    raise exception 'Sem permissão para montar times';
  end if;
  delete from public.team_slots where event_id = p_event;
  insert into public.team_slots (event_id, user_id, team)
  select p_event, (s ->> 'user_id')::uuid, s ->> 'team'
    from jsonb_array_elements(coalesce(p_slots, '[]'::jsonb)) as s;
end $$;

revoke execute on function public.save_teams(bigint, jsonb) from public, anon;
grant  execute on function public.save_teams(bigint, jsonb) to authenticated;

-- O prazo de resposta do evento ainda está aberto?
create or replace function public.rsvp_open(p_event bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select e.rsvp_close_minutes is null
        or now() < e.starts_at - make_interval(mins => e.rsvp_close_minutes)
      from public.events e where e.id = p_event), false)
$$;

-- O membro pode mudar a própria resposta? (prazo aberto e não está escalado num time travado)
create or replace function public.can_change_rsvp(p_event bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select public.rsvp_open(p_event) and not exists (
    select 1 from public.events e
      join public.team_slots ts on ts.event_id = e.id
     where e.id = p_event and e.teams_locked and ts.user_id = auth.uid())
$$;

-- Membro pede para sair (quando já não pode mudar a resposta sozinho).
-- p_user = a conta do jogo: a do próprio membro (padrão) ou uma conta que ele pilota.
drop function if exists public.request_withdrawal(bigint, text);
drop function if exists public.cancel_withdrawal(bigint);

create or replace function public.request_withdrawal(p_event bigint, p_reason text, p_user uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare
  acct uuid := coalesce(p_user, auth.uid());
begin
  if not public.can_act_as(acct) then
    raise exception 'Você não pode responder por esta conta';
  end if;
  if not exists (select 1 from public.rsvps where event_id = p_event and user_id = acct and going) then
    raise exception 'Esta conta não está confirmada neste evento';
  end if;
  if public.can_change_rsvp_for(p_event, acct) then
    raise exception 'Esta conta ainda pode mudar a resposta normalmente';
  end if;
  update public.rsvps
     set withdraw_reason = left(coalesce(nullif(trim(p_reason), ''), 'Sem motivo informado'), 300),
         withdraw_requested_at = now()
   where event_id = p_event and user_id = acct;
end $$;

create or replace function public.cancel_withdrawal(p_event bigint, p_user uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare
  acct uuid := coalesce(p_user, auth.uid());
begin
  if not public.can_act_as(acct) then
    raise exception 'Você não pode responder por esta conta';
  end if;
  update public.rsvps set withdraw_reason = null, withdraw_requested_at = null
   where event_id = p_event and user_id = acct;
end $$;

-- Oficial aceita (vira "Não vou" e sai do time) ou recusa (continua confirmado) o pedido
create or replace function public.resolve_withdrawal(p_event bigint, p_user uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_officer() then
    raise exception 'Só oficiais e o líder podem decidir pedidos de saída';
  end if;
  if p_accept then
    update public.rsvps
       set going = false, discord = null, withdraw_reason = null, withdraw_requested_at = null, updated_at = now()
     where event_id = p_event and user_id = p_user;
  else
    update public.rsvps set withdraw_reason = null, withdraw_requested_at = null
     where event_id = p_event and user_id = p_user;
  end if;
end $$;

revoke execute on function public.request_withdrawal(bigint, text, uuid)    from public, anon;
revoke execute on function public.cancel_withdrawal(bigint, uuid)           from public, anon;
revoke execute on function public.resolve_withdrawal(bigint, uuid, boolean) from public, anon;
grant  execute on function public.request_withdrawal(bigint, text, uuid)    to authenticated;
grant  execute on function public.cancel_withdrawal(bigint, uuid)           to authenticated;
grant  execute on function public.resolve_withdrawal(bigint, uuid, boolean) to authenticated;

-- Quem desmarca presença sai automaticamente do time
create or replace function public.rsvp_cleanup_slot() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    delete from public.team_slots where event_id = old.event_id and user_id = old.user_id;
    return old;
  end if;
  if not new.going then
    delete from public.team_slots where event_id = new.event_id and user_id = new.user_id;
  end if;
  return new;
end $$;

drop trigger if exists rsvps_cleanup_slot on public.rsvps;
create trigger rsvps_cleanup_slot
  after update or delete on public.rsvps
  for each row execute function public.rsvp_cleanup_slot();

-- ---------- Segurança (Row Level Security) ---------------------------

alter table public.profiles enable row level security;
alter table public.events   enable row level security;
alter table public.rsvps    enable row level security;
alter table public.team_slots enable row level security;
alter table public.member_contacts enable row level security;
alter table public.attendance enable row level security;
alter table public.profile_history enable row level security;
alter table public.event_types enable row level security;
alter table public.member_notes enable row level security;
alter table public.membership_log enable row level security;
alter table public.news_posts enable row level security;

-- Malah News: membros veem; oficiais e líder publicam, editam e apagam.
drop policy if exists "news_select" on public.news_posts;
create policy "news_select" on public.news_posts
  for select to authenticated using (public.is_member());

drop policy if exists "news_insert" on public.news_posts;
create policy "news_insert" on public.news_posts
  for insert to authenticated with check (public.is_officer() and author_id = auth.uid());

drop policy if exists "news_update" on public.news_posts;
create policy "news_update" on public.news_posts
  for update to authenticated using (public.is_officer()) with check (public.is_officer());

drop policy if exists "news_delete" on public.news_posts;
create policy "news_delete" on public.news_posts
  for delete to authenticated using (public.is_officer());

-- Imagens do bucket "news": só membros veem; só oficiais e líder enviam/apagam.
drop policy if exists "news_images_select" on storage.objects;
create policy "news_images_select" on storage.objects
  for select to authenticated using (bucket_id = 'news' and public.is_member());

drop policy if exists "news_images_insert" on storage.objects;
create policy "news_images_insert" on storage.objects
  for insert to authenticated with check (bucket_id = 'news' and public.is_officer());

drop policy if exists "news_images_delete" on storage.objects;
create policy "news_images_delete" on storage.objects
  for delete to authenticated using (bucket_id = 'news' and public.is_officer());

-- Histórico no clã: oficiais e líder veem de todos; cada pessoa vê o próprio. Só o banco escreve.
drop policy if exists "membership_log_select" on public.membership_log;
create policy "membership_log_select" on public.membership_log
  for select to authenticated using (user_id = auth.uid() or public.is_officer());

-- Anotações internas: só oficiais e líder. Ninguém vê (nem escreve) anotações sobre si mesmo.
-- Cada um apaga as próprias; o líder pode apagar qualquer uma.
drop policy if exists "notes_select" on public.member_notes;
create policy "notes_select" on public.member_notes
  for select to authenticated
  using (public.is_officer() and member_id <> auth.uid());

drop policy if exists "notes_insert" on public.member_notes;
create policy "notes_insert" on public.member_notes
  for insert to authenticated
  with check (public.is_officer() and author_id = auth.uid() and member_id <> auth.uid());

drop policy if exists "notes_delete" on public.member_notes;
create policy "notes_delete" on public.member_notes
  for delete to authenticated
  using (public.is_officer() and member_id <> auth.uid()
         and (author_id = auth.uid() or public.my_role() = 'leader'));

-- Tipos de evento: todos que fizeram login veem; só o líder cadastra/edita pelo site.
-- (No Table Editor do Supabase você edita direto, como dono do projeto.)
drop policy if exists "event_types_select" on public.event_types;
create policy "event_types_select" on public.event_types
  for select to authenticated using (true);

drop policy if exists "event_types_write" on public.event_types;
create policy "event_types_write" on public.event_types
  for all to authenticated
  using (public.my_role() = 'leader') with check (public.my_role() = 'leader');

-- Histórico: oficiais e líder veem de todos; cada membro vê o próprio. Só o banco escreve.
drop policy if exists "history_select" on public.profile_history;
create policy "history_select" on public.profile_history
  for select to authenticated using (user_id = auth.uid() or public.is_officer());

-- Presença real: oficiais e líder veem e registram; cada membro vê só a própria.
drop policy if exists "attendance_select" on public.attendance;
create policy "attendance_select" on public.attendance
  for select to authenticated using (user_id = auth.uid() or public.is_officer());

drop policy if exists "attendance_write" on public.attendance;
create policy "attendance_write" on public.attendance
  for all to authenticated using (public.is_officer()) with check (public.is_officer());

-- Telefone: o próprio membro vê e edita; oficiais e líder só veem.
drop policy if exists "contacts_select" on public.member_contacts;
create policy "contacts_select" on public.member_contacts
  for select to authenticated using (user_id = auth.uid() or public.is_officer());

drop policy if exists "contacts_insert_own" on public.member_contacts;
create policy "contacts_insert_own" on public.member_contacts
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists "contacts_update_own" on public.member_contacts;
create policy "contacts_update_own" on public.member_contacts
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Em qual time eu estou neste evento (usado pela regra abaixo)
create or replace function public.my_team(p_event bigint) returns text
language sql stable security definer set search_path = public as $$
  select team from public.team_slots where event_id = p_event and user_id = auth.uid()
$$;

-- Times: oficiais e líder veem todos e montam; cada membro vê só o próprio time.
drop policy if exists "team_slots_select" on public.team_slots;
create policy "team_slots_select" on public.team_slots
  for select to authenticated
  using (public.is_officer() or (public.is_member() and team = public.my_team(event_id)));

drop policy if exists "team_slots_write" on public.team_slots;
create policy "team_slots_write" on public.team_slots
  for all to authenticated using (public.is_officer()) with check (public.is_officer());

-- Perfis: cada um vê o próprio; membros aprovados veem todos.
drop policy if exists "profiles_select" on public.profiles;
create policy "profiles_select" on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.is_member());

-- Cada um só altera o próprio nome no jogo, classe e atributos (o cargo muda só pela função acima).
revoke update on public.profiles from anon, authenticated;
grant  update (game_name, char_class, armor, armor_pen, potency, resistance, resonance)
  on public.profiles to authenticated;
drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own" on public.profiles
  for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Eventos: membros veem; oficiais e líder criam, editam e apagam.
drop policy if exists "events_select" on public.events;
create policy "events_select" on public.events
  for select to authenticated using (public.is_member());

drop policy if exists "events_insert" on public.events;
create policy "events_insert" on public.events
  for insert to authenticated with check (public.is_officer());

drop policy if exists "events_update" on public.events;
create policy "events_update" on public.events
  for update to authenticated using (public.is_officer()) with check (public.is_officer());

drop policy if exists "events_delete" on public.events;
create policy "events_delete" on public.events
  for delete to authenticated using (public.is_officer());

-- Respostas: oficiais e líder veem todas. O membro comum vê a própria e a dos
-- colegas do mesmo time (para mostrar o time dele); cada um só cria/altera/apaga a própria.
drop policy if exists "rsvps_select" on public.rsvps;
create policy "rsvps_select" on public.rsvps
  for select to authenticated using (
    user_id = auth.uid()
    or public.is_officer()
    or (public.is_member() and exists (
          select 1 from public.team_slots ts
           where ts.event_id = rsvps.event_id
             and ts.user_id  = rsvps.user_id
             and ts.team     = public.my_team(rsvps.event_id)))
  );

-- Mudar a própria resposta: só dentro do prazo e se não estiver escalado num time travado
-- (oficiais e líder podem sempre).
drop policy if exists "rsvps_insert" on public.rsvps;
create policy "rsvps_insert" on public.rsvps
  for insert to authenticated
  with check (user_id = auth.uid() and public.is_member()
              and (public.is_officer() or public.can_change_rsvp(event_id)));

drop policy if exists "rsvps_update" on public.rsvps;
create policy "rsvps_update" on public.rsvps
  for update to authenticated
  using (user_id = auth.uid() and (public.is_officer() or public.can_change_rsvp(event_id)))
  with check (user_id = auth.uid() and public.is_member());

drop policy if exists "rsvps_delete" on public.rsvps;
create policy "rsvps_delete" on public.rsvps
  for delete to authenticated
  using (user_id = auth.uid() and (public.is_officer() or public.can_change_rsvp(event_id)));


-- =====================================================================
--  Contas pilotadas
--  Um "piloto" joga com mais de uma conta do jogo. Cada conta do jogo é um membro no site:
--    • conta com login próprio (o dono entra com o Discord dele), que pode ter pilotos autorizados;
--    • conta sem login (managed = true), cadastrada por um piloto e respondida só pelos pilotos dela.
--  (Esta seção fica no fim porque substitui algumas regras definidas acima.)
-- =====================================================================

-- Perfis sem login próprio: o id deixa de precisar existir em auth.users (nenhum dado é alterado)
alter table public.profiles drop constraint if exists profiles_id_fkey;
alter table public.profiles alter column id set default gen_random_uuid();
alter table public.profiles add column if not exists managed boolean not null default false;

-- Quem registrou a resposta (útil quando um piloto responde pela conta)
alter table public.rsvps add column if not exists answered_by uuid references public.profiles(id) on delete set null;

-- Quem pode pilotar qual conta
create table if not exists public.account_pilots (
  account_id   uuid not null references public.profiles(id) on delete cascade,
  pilot_id     uuid not null references public.profiles(id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending', 'approved')),
  reason       text check (reason is null or char_length(reason) <= 300),
  requested_at timestamptz not null default now(),
  decided_at   timestamptz,
  decided_by   uuid references public.profiles(id) on delete set null,
  primary key (account_id, pilot_id),
  check (account_id <> pilot_id)
);
create index if not exists account_pilots_pilot_idx on public.account_pilots (pilot_id);

-- Posso agir por esta conta? (é a minha, ou sou piloto aprovado dela e membro ativo)
create or replace function public.can_act_as(p_account uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_account = auth.uid()
      or (public.is_member() and exists (
            select 1 from public.account_pilots
             where account_id = p_account and pilot_id = auth.uid() and status = 'approved'))
$$;

-- A conta está ativa no clã?
create or replace function public.is_active_account(p_account uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role in ('member', 'officer', 'leader') from public.profiles where id = p_account), false)
$$;

-- A resposta desta conta ainda pode mudar? (prazo aberto e ela não está num time travado)
create or replace function public.can_change_rsvp_for(p_event bigint, p_account uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.rsvp_open(p_event) and not exists (
    select 1 from public.events e
      join public.team_slots ts on ts.event_id = e.id
     where e.id = p_event and e.teams_locked and ts.user_id = p_account)
$$;

-- Times de todas as contas que eu controlo neste evento
create or replace function public.my_teams(p_event bigint) returns setof text
language sql stable security definer set search_path = public as $$
  select ts.team from public.team_slots ts
   where ts.event_id = p_event
     and (ts.user_id = auth.uid()
          or exists (select 1 from public.account_pilots a
                      where a.account_id = ts.user_id and a.pilot_id = auth.uid() and a.status = 'approved'))
$$;

-- Registra quem respondeu (Vou / Não vou)
create or replace function public.set_answered_by() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null then
    new.answered_by := auth.uid();
  end if;
  return new;
end $$;

drop trigger if exists rsvps_answered_by on public.rsvps;
create trigger rsvps_answered_by
  before insert or update of going on public.rsvps
  for each row execute function public.set_answered_by();

-- Piloto cadastra uma conta do jogo sem login (fica aguardando aprovação de um oficial)
create or replace function public.create_piloted_account(
  p_game_name text, p_char_class text,
  p_armor integer, p_armor_pen integer, p_potency integer, p_resistance integer, p_resonance integer
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  new_id     uuid := gen_random_uuid();
  pilot_name text;
begin
  if not public.is_member() then
    raise exception 'Só membros aprovados podem cadastrar contas pilotadas';
  end if;
  if coalesce(trim(p_game_name), '') = '' then
    raise exception 'Informe o nome do personagem';
  end if;
  select coalesce(nullif(game_name, ''), discord_name) into pilot_name from public.profiles where id = auth.uid();
  perform set_config('infernum.reason', 'Conta pilotada cadastrada por ' || coalesce(pilot_name, '?'), true);
  insert into public.profiles (id, discord_name, game_name, role, managed,
                               char_class, armor, armor_pen, potency, resistance, resonance)
  values (new_id, '', left(trim(p_game_name), 40), 'pending', true,
          p_char_class, p_armor, p_armor_pen, p_potency, p_resistance, p_resonance);
  insert into public.account_pilots (account_id, pilot_id, status, decided_at, decided_by)
  values (new_id, auth.uid(), 'approved', now(), auth.uid());
  return new_id;
end $$;

-- Piloto pede acesso a uma conta que já existe
create or replace function public.request_pilot_access(p_account uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member() then
    raise exception 'Só membros aprovados podem pedir acesso';
  end if;
  if p_account = auth.uid() then
    raise exception 'Esta já é a sua conta';
  end if;
  if not public.is_active_account(p_account) then
    raise exception 'Conta não encontrada ou fora do clã';
  end if;
  if exists (select 1 from public.account_pilots
              where account_id = p_account and pilot_id = auth.uid() and status = 'approved') then
    raise exception 'Você já pilota esta conta';
  end if;
  insert into public.account_pilots (account_id, pilot_id, status, reason, requested_at)
  values (p_account, auth.uid(), 'pending', left(nullif(trim(p_reason), ''), 300), now())
  on conflict (account_id, pilot_id) do update
     set status = 'pending', reason = excluded.reason, requested_at = now(), decided_at = null, decided_by = null;
end $$;

-- O dono da conta (ou um oficial/líder) aprova ou recusa o pedido
create or replace function public.decide_pilot_access(p_account uuid, p_pilot uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (p_account = auth.uid() or public.is_officer()) then
    raise exception 'Só o dono da conta ou um oficial pode decidir este pedido';
  end if;
  if p_approve then
    update public.account_pilots
       set status = 'approved', decided_at = now(), decided_by = auth.uid()
     where account_id = p_account and pilot_id = p_pilot;
  else
    delete from public.account_pilots
     where account_id = p_account and pilot_id = p_pilot and status = 'pending';
  end if;
end $$;

-- Tirar um piloto (o dono da conta, o próprio piloto ou um oficial/líder)
create or replace function public.remove_pilot(p_account uuid, p_pilot uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (p_account = auth.uid() or p_pilot = auth.uid() or public.is_officer()) then
    raise exception 'Sem permissão para tirar este piloto';
  end if;
  delete from public.account_pilots where account_id = p_account and pilot_id = p_pilot;
end $$;

-- Oficial/líder autoriza um piloto diretamente
create or replace function public.add_pilot(p_account uuid, p_pilot uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_officer() then
    raise exception 'Só oficiais e o líder podem adicionar pilotos';
  end if;
  if p_account = p_pilot then
    raise exception 'A conta não pode pilotar a si mesma';
  end if;
  if not public.is_active_account(p_pilot) then
    raise exception 'O piloto precisa ser um membro ativo do clã';
  end if;
  insert into public.account_pilots (account_id, pilot_id, status, decided_at, decided_by)
  values (p_account, p_pilot, 'approved', now(), auth.uid())
  on conflict (account_id, pilot_id) do update
     set status = 'approved', decided_at = now(), decided_by = auth.uid();
end $$;

revoke execute on function public.create_piloted_account(text, text, integer, integer, integer, integer, integer) from public, anon;
revoke execute on function public.request_pilot_access(uuid, text)          from public, anon;
revoke execute on function public.decide_pilot_access(uuid, uuid, boolean)  from public, anon;
revoke execute on function public.remove_pilot(uuid, uuid)                  from public, anon;
revoke execute on function public.add_pilot(uuid, uuid)                     from public, anon;
grant  execute on function public.create_piloted_account(text, text, integer, integer, integer, integer, integer) to authenticated;
grant  execute on function public.request_pilot_access(uuid, text)          to authenticated;
grant  execute on function public.decide_pilot_access(uuid, uuid, boolean)  to authenticated;
grant  execute on function public.remove_pilot(uuid, uuid)                  to authenticated;
grant  execute on function public.add_pilot(uuid, uuid)                     to authenticated;

-- Quem vê os vínculos de piloto: oficiais e líder (todos); cada um vê os seus. Só as funções acima escrevem.
alter table public.account_pilots enable row level security;
drop policy if exists "pilots_select" on public.account_pilots;
create policy "pilots_select" on public.account_pilots
  for select to authenticated
  using (public.is_officer() or pilot_id = auth.uid() or account_id = auth.uid());

-- ----- Regras atualizadas para considerar as contas que cada um pilota -----

-- Respostas: as contas que eu controlo, oficiais (todas) e colegas dos meus times
drop policy if exists "rsvps_select" on public.rsvps;
create policy "rsvps_select" on public.rsvps
  for select to authenticated using (
    public.can_act_as(user_id)
    or public.is_officer()
    or (public.is_member() and exists (
          select 1 from public.team_slots ts
           where ts.event_id = rsvps.event_id
             and ts.user_id  = rsvps.user_id
             and ts.team in (select public.my_teams(rsvps.event_id))))
  );

drop policy if exists "rsvps_insert" on public.rsvps;
create policy "rsvps_insert" on public.rsvps
  for insert to authenticated
  with check (public.can_act_as(user_id) and public.is_active_account(user_id)
              and (public.is_officer() or public.can_change_rsvp_for(event_id, user_id)));

drop policy if exists "rsvps_update" on public.rsvps;
create policy "rsvps_update" on public.rsvps
  for update to authenticated
  using (public.can_act_as(user_id) and (public.is_officer() or public.can_change_rsvp_for(event_id, user_id)))
  with check (public.can_act_as(user_id) and public.is_active_account(user_id));

drop policy if exists "rsvps_delete" on public.rsvps;
create policy "rsvps_delete" on public.rsvps
  for delete to authenticated
  using (public.can_act_as(user_id) and (public.is_officer() or public.can_change_rsvp_for(event_id, user_id)));

-- Times: cada membro vê os times das contas que controla
drop policy if exists "team_slots_select" on public.team_slots;
create policy "team_slots_select" on public.team_slots
  for select to authenticated
  using (public.is_officer() or (public.is_member() and team in (select public.my_teams(event_id))));

-- Perfil: o dono e os pilotos aprovados podem atualizar classe e atributos da conta
drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own" on public.profiles
  for update to authenticated
  using (public.can_act_as(id)) with check (public.can_act_as(id));

-- Presença real, histórico de alterações e histórico no clã das contas que eu controlo
drop policy if exists "attendance_select" on public.attendance;
create policy "attendance_select" on public.attendance
  for select to authenticated using (public.can_act_as(user_id) or public.is_officer());

drop policy if exists "history_select" on public.profile_history;
create policy "history_select" on public.profile_history
  for select to authenticated using (public.can_act_as(user_id) or public.is_officer());

drop policy if exists "membership_log_select" on public.membership_log;
create policy "membership_log_select" on public.membership_log
  for select to authenticated using (public.can_act_as(user_id) or public.is_officer());

-- Anotações internas: ninguém vê anotações sobre contas que ele mesmo controla
drop policy if exists "notes_select" on public.member_notes;
create policy "notes_select" on public.member_notes
  for select to authenticated
  using (public.is_officer() and not public.can_act_as(member_id));

drop policy if exists "notes_insert" on public.member_notes;
create policy "notes_insert" on public.member_notes
  for insert to authenticated
  with check (public.is_officer() and author_id = auth.uid() and not public.can_act_as(member_id));

drop policy if exists "notes_delete" on public.member_notes;
create policy "notes_delete" on public.member_notes
  for delete to authenticated
  using (public.is_officer() and not public.can_act_as(member_id)
         and (author_id = auth.uid() or public.my_role() = 'leader'));

-- =====================================================================
--  Novembro/2026: foto de perfil própria, nomes dos times (formato
--  "Outros") e tipo "Torre Amaldiçoada". Só ADICIONA coisas: nenhum
--  dado existente é alterado ou apagado.
-- =====================================================================

-- ---------- Foto de perfil enviada pelo membro ----------------------
-- custom_avatar_url: foto enviada pelo site (tem prioridade sobre a do Discord)
-- avatar_hidden:     o membro removeu a foto (mostra só a inicial do nome)
alter table public.profiles add column if not exists custom_avatar_url text;
alter table public.profiles add column if not exists avatar_hidden boolean not null default false;
grant update (custom_avatar_url, avatar_hidden) on public.profiles to authenticated;

-- Espaço PÚBLICO para as fotos (até 2 MB; o site já envia reduzida para 256×256)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 2097152, array['image/webp', 'image/jpeg', 'image/png'])
on conflict (id) do nothing;

-- Cada pessoa só envia/troca/apaga arquivos dentro da própria pasta (avatars/<seu id>/...)
drop policy if exists "avatars_insert" on storage.objects;
create policy "avatars_insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "avatars_update" on storage.objects;
create policy "avatars_update" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "avatars_delete" on storage.objects;
create policy "avatars_delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------- Nomes dos times no formato "Outros" ----------------------
-- (no banco o formato continua se chamando 'rito'; no site aparece como "Outros")
-- team_names[i] = nome do time i; vazio/nulo = "Time i"
alter table public.events add column if not exists team_names text[];

-- Renomeia um time e leva junto quem já está nele, numa única transação
create or replace function public.rename_team(p_event bigint, p_index integer, p_name text) returns void
language plpgsql security invoker set search_path = public as $$
declare
  ev       public.events;
  names    text[];
  old_name text;
  new_name text := nullif(btrim(coalesce(p_name, '')), '');
begin
  if not public.is_officer() then
    raise exception 'Sem permissão para renomear times';
  end if;
  select * into ev from public.events where id = p_event for update;
  if ev.id is null then raise exception 'Evento não encontrado'; end if;
  if ev.team_format is distinct from 'rito' then
    raise exception 'Só é possível renomear times no formato Outros';
  end if;
  if p_index < 1 or p_index > ev.team_count then raise exception 'Time inválido'; end if;
  if char_length(new_name) > 30 then raise exception 'O nome do time pode ter até 30 caracteres'; end if;

  -- Lista sempre com 10 posições (evita índices "pulados" no array)
  names := array(select ev.team_names[i] from generate_series(1, 10) i);
  old_name := coalesce(nullif(btrim(names[p_index]), ''), 'Time ' || p_index);
  if exists (select 1 from generate_series(1, ev.team_count) i
              where i <> p_index
                and lower(coalesce(nullif(btrim(names[i]), ''), 'Time ' || i))
                  = lower(coalesce(new_name, 'Time ' || p_index))) then
    raise exception 'Já existe um time com esse nome';
  end if;

  names[p_index] := new_name;
  update public.events set team_names = names where id = p_event;
  update public.team_slots set team = coalesce(new_name, 'Time ' || p_index)
   where event_id = p_event and team = old_name;
end $$;

revoke execute on function public.rename_team(bigint, integer, text) from public, anon;
grant  execute on function public.rename_team(bigint, integer, text) to authenticated;

-- ---------- Novo tipo de evento --------------------------------------
insert into public.event_types (name, sort_order) values ('Torre Amaldiçoada', 40)
on conflict (name) do nothing;

-- =====================================================================
--  Configurações do líder: permissões dos oficiais e aprovações
--  Para cada função, o líder escolhe: allow (Permitido), approval
--  (Precisa de aprovação) ou deny (Bloqueado). Sem nada configurado,
--  tudo fica "Permitido", igual ao funcionamento anterior.
--  Só ADICIONA tabelas, funções e gatilhos e ajusta 3 regras de leitura;
--  nenhum dado existente é alterado ou apagado.
-- =====================================================================

create table if not exists public.officer_permissions (
  perm_key   text primary key check (perm_key ~ '^[a-z_]{2,40}$'),
  mode       text not null default 'allow' check (mode in ('allow', 'approval', 'deny')),
  updated_by uuid default auth.uid() references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

-- Fila de ações de oficiais que aguardam o líder.
-- method/args: a operação do site que o líder executa ao aprovar.
create table if not exists public.officer_requests (
  id           bigint generated always as identity primary key,
  perm_key     text not null,
  method       text not null check (char_length(method) <= 60),
  args         jsonb not null default '[]'::jsonb,
  summary      text not null check (char_length(summary) between 1 and 500),
  requested_by uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  requested_at timestamptz not null default now(),
  status       text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'failed')),
  decided_by   uuid references public.profiles(id) on delete set null,
  decided_at   timestamptz,
  note         text check (note is null or char_length(note) <= 300)
);
create index if not exists officer_requests_status_idx on public.officer_requests (status, requested_at desc);

-- Modo configurado para uma função (padrão: allow)
create or replace function public.officer_perm(p_key text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select mode from public.officer_permissions where perm_key = p_key), 'allow')
$$;

-- O usuário atual pode fazer isso diretamente? (líder sempre; oficial só se "allow")
create or replace function public.officer_can(p_key text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() = 'leader'
              or (public.my_role() = 'officer' and public.officer_perm(p_key) = 'allow'), false)
$$;

-- Usado pelos gatilhos: barra o oficial quando a função não está "Permitida"
create or replace function public.require_perm(p_key text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if public.my_role() = 'officer' and public.officer_perm(p_key) <> 'allow' then
    raise exception 'O líder não permite esta ação para oficiais (%)', p_key using errcode = '42501';
  end if;
end $$;

revoke execute on function public.officer_perm(text)  from public, anon;
revoke execute on function public.officer_can(text)   from public, anon;
revoke execute on function public.require_perm(text)  from public, anon;
grant  execute on function public.officer_perm(text)  to authenticated;
grant  execute on function public.officer_can(text)   to authenticated;
grant  execute on function public.require_perm(text)  to authenticated;

-- ---------- Gatilhos que garantem as regras no banco ----------

-- Eventos: criar, editar, apagar, travar times e formato/nomes dos times
create or replace function public.perm_events() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() is distinct from 'officer' then return coalesce(new, old); end if;
  if tg_op = 'INSERT' then perform public.require_perm('event_create'); return new; end if;
  if tg_op = 'DELETE' then perform public.require_perm('event_delete'); return old; end if;
  if (new.title, new.description, new.starts_at, new.type_id, new.rsvp_close_minutes)
     is distinct from (old.title, old.description, old.starts_at, old.type_id, old.rsvp_close_minutes) then
    perform public.require_perm('event_edit');
  end if;
  if new.teams_locked is distinct from old.teams_locked then perform public.require_perm('teams_lock'); end if;
  if (new.team_format, new.team_count, new.team_names) is distinct from (old.team_format, old.team_count, old.team_names) then
    perform public.require_perm('teams_build');
  end if;
  return new;
end $$;
drop trigger if exists events_perm on public.events;
create trigger events_perm before insert or update or delete on public.events
  for each row execute function public.perm_events();

-- Times: montar/salvar/limpar. Saídas automáticas (desmarcou presença, evento apagado) passam.
create or replace function public.perm_team_slots() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() is distinct from 'officer' then return coalesce(new, old); end if;
  if tg_op = 'DELETE' and (
       not exists (select 1 from public.rsvps where event_id = old.event_id and user_id = old.user_id and going)
       or not exists (select 1 from public.events where id = old.event_id)) then
    return old;
  end if;
  perform public.require_perm('teams_build');
  return coalesce(new, old);
end $$;
drop trigger if exists team_slots_perm on public.team_slots;
create trigger team_slots_perm before insert or update or delete on public.team_slots
  for each row execute function public.perm_team_slots();

-- Presença real
create or replace function public.perm_attendance() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() is distinct from 'officer' then return coalesce(new, old); end if;
  if tg_op = 'DELETE' and not exists (select 1 from public.events where id = old.event_id) then return old; end if;
  perform public.require_perm('attendance');
  return coalesce(new, old);
end $$;
drop trigger if exists attendance_perm on public.attendance;
create trigger attendance_perm before insert or update or delete on public.attendance
  for each row execute function public.perm_attendance();

-- Pedidos de saída (oficial decide pela conta de outra pessoa)
create or replace function public.perm_rsvps() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() = 'officer'
     and old.withdraw_requested_at is not null and new.withdraw_requested_at is null
     and not public.can_act_as(new.user_id) then
    perform public.require_perm('withdraw_decide');
  end if;
  return new;
end $$;
drop trigger if exists rsvps_perm on public.rsvps;
create trigger rsvps_perm before update on public.rsvps
  for each row execute function public.perm_rsvps();

-- Membros: aprovar novos e remover/recusar
create or replace function public.perm_profiles_role() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() = 'officer' and new.id <> auth.uid() and new.role is distinct from old.role then
    if old.role = 'pending' and new.role = 'member' then
      perform public.require_perm('member_approve');
    elsif new.role = 'former' or (old.role = 'member' and new.role = 'pending') then
      perform public.require_perm('member_remove');
    end if;
  end if;
  return new;
end $$;
drop trigger if exists profiles_perm_role on public.profiles;
create trigger profiles_perm_role before update of role on public.profiles
  for each row execute function public.perm_profiles_role();

-- Pilotos: o oficial mexendo em contas de outras pessoas
create or replace function public.perm_pilots() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  acc uuid;
  pil uuid;
begin
  if public.my_role() is distinct from 'officer' then return coalesce(new, old); end if;
  if tg_op = 'DELETE' then acc := old.account_id; pil := old.pilot_id; else acc := new.account_id; pil := new.pilot_id; end if;
  if acc = auth.uid() or pil = auth.uid() then return coalesce(new, old); end if;
  -- Quem saiu do clã deixa de pilotar (parte de "remover membro")
  if tg_op = 'DELETE' and exists (select 1 from public.profiles where id in (acc, pil) and role = 'former') then
    return old;
  end if;
  perform public.require_perm('pilots');
  return coalesce(new, old);
end $$;
drop trigger if exists pilots_perm on public.account_pilots;
create trigger pilots_perm before insert or update or delete on public.account_pilots
  for each row execute function public.perm_pilots();

-- Malah News
create or replace function public.perm_news() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() is distinct from 'officer' then return coalesce(new, old); end if;
  perform public.require_perm(case when tg_op = 'DELETE' then 'news_delete' else 'news_publish' end);
  return coalesce(new, old);
end $$;
drop trigger if exists news_perm on public.news_posts;
create trigger news_perm before insert or update or delete on public.news_posts
  for each row execute function public.perm_news();

-- Anotações internas e telefones (a leitura também depende da permissão)
drop policy if exists "notes_select" on public.member_notes;
create policy "notes_select" on public.member_notes
  for select to authenticated
  using (public.is_officer() and not public.can_act_as(member_id) and public.officer_can('notes'));

drop policy if exists "notes_insert" on public.member_notes;
create policy "notes_insert" on public.member_notes
  for insert to authenticated
  with check (public.is_officer() and author_id = auth.uid() and not public.can_act_as(member_id) and public.officer_can('notes'));

drop policy if exists "contacts_select" on public.member_contacts;
create policy "contacts_select" on public.member_contacts
  for select to authenticated using (user_id = auth.uid() or public.officer_can('view_phone'));

-- ---------- Quem vê e quem altera as configurações ----------
alter table public.officer_permissions enable row level security;
alter table public.officer_requests    enable row level security;

drop policy if exists "operm_select" on public.officer_permissions;
create policy "operm_select" on public.officer_permissions
  for select to authenticated using (public.is_officer());

drop policy if exists "operm_write" on public.officer_permissions;
create policy "operm_write" on public.officer_permissions
  for all to authenticated
  using (public.my_role() = 'leader') with check (public.my_role() = 'leader');

-- O oficial vê os próprios pedidos; o líder vê e decide todos
drop policy if exists "oreq_select" on public.officer_requests;
create policy "oreq_select" on public.officer_requests
  for select to authenticated using (requested_by = auth.uid() or public.my_role() = 'leader');

-- Só dá para pedir aprovação do que o líder marcou como "Precisa de aprovação"
drop policy if exists "oreq_insert" on public.officer_requests;
create policy "oreq_insert" on public.officer_requests
  for insert to authenticated
  with check (public.my_role() = 'officer' and requested_by = auth.uid() and status = 'pending'
              and decided_by is null and public.officer_perm(perm_key) = 'approval');

drop policy if exists "oreq_update" on public.officer_requests;
create policy "oreq_update" on public.officer_requests
  for update to authenticated
  using (public.my_role() = 'leader') with check (public.my_role() = 'leader');

-- =====================================================================
--  Recrutamentos e Tickets
--  Só ADICIONA tabelas, funções, regras e um espaço privado para as
--  imagens dos tickets. Nenhum dado existente é alterado ou apagado.
--  Depende do trecho "Configurações do líder" (officer_perm/require_perm).
-- =====================================================================

-- ---------- Recrutamentos ----------
create table if not exists public.recruitments (
  id          bigint generated always as identity primary key,
  title       text not null check (char_length(title) between 1 and 80),
  category    text not null default 'other' check (category in ('pvp', 'warband', 'other')),
  description text check (description is null or char_length(description) <= 1000),
  slots       integer not null check (slots between 1 and 50),
  activity_at timestamptz,
  deadline_at timestamptz,
  wanted      jsonb not null default '{}'::jsonb,
  created_by  uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  status      text not null default 'pending' check (status in ('pending', 'open', 'closed', 'rejected')),
  decided_by  uuid references public.profiles(id) on delete set null,
  decided_at  timestamptz,
  note        text check (note is null or char_length(note) <= 300),
  closed_by   uuid references public.profiles(id) on delete set null,
  closed_at   timestamptz
);
create index if not exists recruitments_status_idx on public.recruitments (status, created_at desc);

create table if not exists public.recruit_applications (
  recruit_id  bigint not null references public.recruitments(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  status      text not null default 'applied' check (status in ('applied', 'accepted', 'declined')),
  applied_at  timestamptz not null default now(),
  decided_at  timestamptz,
  primary key (recruit_id, user_id)
);

alter table public.recruitments enable row level security;
alter table public.recruit_applications enable row level security;

-- Abertos: todos os membros. Pendentes/recusados/encerrados: quem criou e a liderança.
drop policy if exists "recruit_select" on public.recruitments;
create policy "recruit_select" on public.recruitments
  for select to authenticated
  using (public.is_member() and (status = 'open' or created_by = auth.uid() or public.is_officer()));

-- Candidaturas: visíveis junto com o recrutamento (as escritas são só pelas funções abaixo)
drop policy if exists "recruit_apps_select" on public.recruit_applications;
create policy "recruit_apps_select" on public.recruit_applications
  for select to authenticated
  using (public.is_member() and exists (select 1 from public.recruitments r where r.id = recruit_id));

-- Limpa os campos recebidos do site
create or replace function public.recruit_clean_wanted(p jsonb) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_object_agg(k, least(50, (v #>> '{}')::int)), '{}'::jsonb)
  from jsonb_each(coalesce(p, '{}'::jsonb)) as e(k, v)
  where k in ('dh', 'cruzado', 'mago', 'bk', 'monge', 'druida', 'barbaro', 'necromante', 'bruxo', 'tempest')
    and jsonb_typeof(v) = 'number' and (v #>> '{}')::numeric >= 1
$$;

-- Quem criou pode tudo no próprio recrutamento; oficial depende das Configurações; líder pode tudo
create or replace function public.recruit_guard(p_creator uuid, p_key text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if p_creator = auth.uid() or public.my_role() = 'leader' then return; end if;
  if public.my_role() = 'officer' then perform public.require_perm(p_key); return; end if;
  raise exception 'Sem permissão para alterar este recrutamento' using errcode = '42501';
end $$;

create or replace function public.create_recruit(p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_id bigint;
  v_status text := case when public.my_role() = 'leader' then 'open' else 'pending' end;
begin
  if not public.is_member() then raise exception 'Só membros do clã podem criar recrutamentos' using errcode = '42501'; end if;
  insert into public.recruitments (title, category, description, slots, activity_at, deadline_at, wanted, created_by, status, decided_by, decided_at)
  values (trim(p->>'title'), coalesce(p->>'category', 'other'), nullif(trim(p->>'description'), ''), (p->>'slots')::int,
          (p->>'activity_at')::timestamptz, (p->>'deadline_at')::timestamptz, public.recruit_clean_wanted(p->'wanted'), auth.uid(), v_status,
          case when v_status = 'open' then auth.uid() end, case when v_status = 'open' then now() end)
  returning id into v_id;
  return json_build_object('id', v_id, 'status', v_status);
end $$;

create or replace function public.update_recruit(p_id bigint, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare r public.recruitments; v_acc int;
begin
  select * into r from public.recruitments where id = p_id for update;
  if not found then raise exception 'O recrutamento não existe mais'; end if;
  perform public.recruit_guard(r.created_by, 'recruit_edit');
  select count(*) into v_acc from public.recruit_applications where recruit_id = p_id and status = 'accepted';
  if (p->>'slots')::int < v_acc then raise exception 'Já há % aceitos; as vagas não podem ser menos que isso', v_acc; end if;
  update public.recruitments set
    title = trim(p->>'title'), category = coalesce(p->>'category', 'other'), description = nullif(trim(p->>'description'), ''),
    slots = (p->>'slots')::int, activity_at = (p->>'activity_at')::timestamptz, deadline_at = (p->>'deadline_at')::timestamptz,
    wanted = public.recruit_clean_wanted(p->'wanted'),
    -- recusado e corrigido por quem criou: volta para a aprovação
    status = case when r.status = 'rejected' and r.created_by = auth.uid() then 'pending' else r.status end,
    note = case when r.status = 'rejected' and r.created_by = auth.uid() then null else r.note end,
    decided_by = case when r.status = 'rejected' and r.created_by = auth.uid() then null else r.decided_by end,
    decided_at = case when r.status = 'rejected' and r.created_by = auth.uid() then null else r.decided_at end
  where id = p_id;
end $$;

create or replace function public.delete_recruit(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare r public.recruitments;
begin
  select * into r from public.recruitments where id = p_id;
  if not found then return; end if;
  perform public.recruit_guard(r.created_by, 'recruit_delete');
  delete from public.recruitments where id = p_id;
end $$;

create or replace function public.decide_recruit(p_id bigint, p_approve boolean, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare r public.recruitments;
begin
  select * into r from public.recruitments where id = p_id for update;
  if not found or r.status <> 'pending' then raise exception 'Este recrutamento não está aguardando aprovação'; end if;
  if not public.is_officer() then raise exception 'Só oficiais e o líder aprovam recrutamentos' using errcode = '42501'; end if;
  if public.my_role() <> 'leader' then
    if r.created_by = auth.uid() then raise exception 'Você não pode aprovar o próprio recrutamento' using errcode = '42501'; end if;
    perform public.require_perm('recruit_approve');
  end if;
  update public.recruitments set status = case when p_approve then 'open' else 'rejected' end,
    decided_by = auth.uid(), decided_at = now(), note = case when p_approve then null else left(nullif(trim(p_note), ''), 300) end
  where id = p_id;
end $$;

create or replace function public.close_recruit(p_id bigint, p_reopen boolean) returns void
language plpgsql security definer set search_path = public as $$
declare r public.recruitments;
begin
  select * into r from public.recruitments where id = p_id for update;
  if not found then raise exception 'O recrutamento não existe mais'; end if;
  perform public.recruit_guard(r.created_by, 'recruit_close');
  if p_reopen then
    if r.status <> 'closed' then raise exception 'Este recrutamento não está encerrado'; end if;
    update public.recruitments set status = 'open', closed_by = null, closed_at = null where id = p_id;
  else
    if r.status <> 'open' then raise exception 'Este recrutamento não está aberto'; end if;
    update public.recruitments set status = 'closed', closed_by = auth.uid(), closed_at = now() where id = p_id;
  end if;
end $$;

create or replace function public.apply_recruit(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare r public.recruitments;
begin
  if not public.is_member() then raise exception 'Só membros do clã podem se candidatar' using errcode = '42501'; end if;
  select * into r from public.recruitments where id = p_id;
  if not found or r.status <> 'open' then raise exception 'Este recrutamento não está aberto'; end if;
  if r.created_by = auth.uid() then raise exception 'Você criou este recrutamento'; end if;
  insert into public.recruit_applications (recruit_id, user_id, status, applied_at, decided_at)
  values (p_id, auth.uid(), 'applied', now(), null)
  on conflict (recruit_id, user_id) do update set status = 'applied', applied_at = now(), decided_at = null;
end $$;

create or replace function public.withdraw_recruit(p_id bigint) returns void
language sql security definer set search_path = public as $$
  delete from public.recruit_applications where recruit_id = p_id and user_id = auth.uid()
$$;

create or replace function public.decide_application(p_id bigint, p_user uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare r public.recruitments; a public.recruit_applications; v_acc int;
begin
  select * into r from public.recruitments where id = p_id for update;
  if not found or r.created_by <> auth.uid() then raise exception 'Só quem criou o recrutamento escolhe os participantes' using errcode = '42501'; end if;
  if p_status not in ('applied', 'accepted', 'declined') then raise exception 'Situação inválida'; end if;
  select * into a from public.recruit_applications where recruit_id = p_id and user_id = p_user for update;
  if not found then raise exception 'Esta candidatura não existe mais'; end if;
  if p_status = 'accepted' and a.status <> 'accepted' then
    select count(*) into v_acc from public.recruit_applications where recruit_id = p_id and status = 'accepted';
    if v_acc >= r.slots then raise exception 'Todas as vagas já foram preenchidas'; end if;
  end if;
  update public.recruit_applications set status = p_status, decided_at = case when p_status = 'applied' then null else now() end
  where recruit_id = p_id and user_id = p_user;
end $$;

-- ---------- Tickets ----------
create table if not exists public.tickets (
  id          bigint generated always as identity primary key,
  title       text not null check (char_length(title) between 1 and 100),
  category    text not null check (category in ('suggestion', 'improvement', 'report', 'question', 'site', 'other')),
  anonymous   boolean not null default false,
  author_id   uuid not null references public.profiles(id) on delete cascade,
  status      text not null default 'open' check (status in ('open', 'progress', 'resolved')),
  assigned_to uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);
create table if not exists public.ticket_messages (
  id          bigint generated always as identity primary key,
  ticket_id   bigint not null references public.tickets(id) on delete cascade,
  author_id   uuid references public.profiles(id) on delete set null,
  body        text not null default '' check (char_length(body) <= 2000),
  internal    boolean not null default false,
  images      text[] not null default '{}' check (cardinality(images) <= 3),
  created_at  timestamptz not null default now()
);
create index if not exists ticket_messages_ticket_idx on public.ticket_messages (ticket_id, created_at);

-- Sem regras de leitura direta: tudo passa pelas funções abaixo,
-- que escondem o autor dos tickets anônimos e as notas internas.
alter table public.tickets enable row level security;
alter table public.ticket_messages enable row level security;

-- A liderança pode atender um ticket desta categoria? (líder sempre; oficial conforme as Configurações)
create or replace function public.ticket_staff(p_category text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() = 'leader'
    or (public.my_role() = 'officer' and public.officer_perm('ticket_view') <> 'deny'
        and (p_category <> 'report' or public.officer_perm('ticket_reports') <> 'deny')), false)
$$;

create or replace function public.list_tickets() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(x order by x.created_at desc), '[]'::json) from (
    select t.id, t.title, t.category, t.anonymous, t.status, t.assigned_to, t.created_at,
      (t.author_id = auth.uid()) as mine,
      case when t.anonymous and t.author_id <> auth.uid() then null else t.author_id end as author_id,
      (select coalesce(json_agg(json_build_object(
          'id', m.id, 'body', m.body, 'internal', m.internal, 'images', m.images, 'created_at', m.created_at,
          'from_author', m.author_id is not distinct from t.author_id,
          'author_id', case when t.anonymous and t.author_id <> auth.uid() and m.author_id = t.author_id then null else m.author_id end)
        order by m.created_at), '[]'::json)
       from public.ticket_messages m
       where m.ticket_id = t.id and (not m.internal or t.author_id <> auth.uid())) as messages
    from public.tickets t
    where public.is_member() and (t.author_id = auth.uid() or public.ticket_staff(t.category))
  ) x
$$;

create or replace function public.create_ticket(p_title text, p_category text, p_anonymous boolean, p_body text, p_images text[]) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not public.is_member() then raise exception 'Só membros do clã podem abrir tickets' using errcode = '42501'; end if;
  if char_length(trim(coalesce(p_body, ''))) = 0 then raise exception 'Escreva a mensagem do ticket'; end if;
  insert into public.tickets (title, category, anonymous, author_id) values (trim(p_title), p_category, coalesce(p_anonymous, false), auth.uid())
  returning id into v_id;
  insert into public.ticket_messages (ticket_id, author_id, body, internal, images)
  values (v_id, auth.uid(), trim(p_body), false, coalesce(p_images, '{}'));
  return v_id;
end $$;

create or replace function public.post_ticket_message(p_ticket bigint, p_body text, p_internal boolean, p_images text[]) returns void
language plpgsql security definer set search_path = public as $$
declare t public.tickets; v_mine boolean;
begin
  select * into t from public.tickets where id = p_ticket for update;
  if not found then raise exception 'Este ticket não existe mais'; end if;
  v_mine := t.author_id = auth.uid();
  if not v_mine then
    if not public.ticket_staff(t.category) then raise exception 'Sem permissão para responder este ticket' using errcode = '42501'; end if;
    if public.my_role() = 'officer' then perform public.require_perm('ticket_reply'); end if;
  elsif p_internal then raise exception 'Notas internas são só para quem atende';
  end if;
  if char_length(trim(coalesce(p_body, ''))) = 0 and cardinality(coalesce(p_images, '{}')) = 0 then raise exception 'Mensagem vazia'; end if;
  insert into public.ticket_messages (ticket_id, author_id, body, internal, images)
  values (p_ticket, auth.uid(), trim(coalesce(p_body, '')), coalesce(p_internal, false), coalesce(p_images, '{}'));
  -- membro escrevendo num resolvido reabre; resposta da liderança põe "Em atendimento"
  if v_mine and t.status = 'resolved' then update public.tickets set status = 'open' where id = p_ticket; end if;
  if not v_mine and not coalesce(p_internal, false) and t.status = 'open' then update public.tickets set status = 'progress' where id = p_ticket; end if;
end $$;

create or replace function public.set_ticket_status(p_ticket bigint, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare t public.tickets;
begin
  if p_status not in ('open', 'progress', 'resolved') then raise exception 'Status inválido'; end if;
  select * into t from public.tickets where id = p_ticket for update;
  if not found then raise exception 'Este ticket não existe mais'; end if;
  if t.author_id = auth.uid() then
    if p_status not in ('open', 'resolved') then raise exception 'Você só pode resolver ou reabrir o seu ticket'; end if;
  else
    if not public.ticket_staff(t.category) then raise exception 'Sem permissão' using errcode = '42501'; end if;
    if public.my_role() = 'officer' then perform public.require_perm('ticket_resolve'); end if;
  end if;
  update public.tickets set status = p_status where id = p_ticket;
end $$;

create or replace function public.assign_ticket(p_ticket bigint, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t public.tickets;
begin
  select * into t from public.tickets where id = p_ticket for update;
  if not found or t.author_id = auth.uid() or not public.ticket_staff(t.category) then raise exception 'Sem permissão' using errcode = '42501'; end if;
  if public.my_role() = 'officer' then perform public.require_perm('ticket_reply'); end if;
  if p_user is not null and p_user <> auth.uid() then raise exception 'Você só pode assumir o ticket para você mesmo'; end if;
  update public.tickets set assigned_to = p_user,
    status = case when p_user is not null and t.status = 'open' then 'progress' else t.status end
  where id = p_ticket;
end $$;

-- Só o líder: mostra quem abriu um ticket anônimo (nada fica registrado no ticket)
create or replace function public.reveal_ticket_author(p_ticket bigint) returns uuid
language plpgsql stable security definer set search_path = public as $$
begin
  if public.my_role() is distinct from 'leader' then raise exception 'Só o líder pode ver o autor de um ticket anônimo' using errcode = '42501'; end if;
  return (select author_id from public.tickets where id = p_ticket);
end $$;

-- Imagens dos tickets: espaço PRIVADO (até 5 MB cada; só imagens)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('tickets', 'tickets', false, 5242880, array['image/png', 'image/jpeg', 'image/webp', 'image/gif'])
on conflict (id) do nothing;

-- Quem pode ver uma imagem: quem vê a mensagem em que ela está
create or replace function public.can_read_ticket_image(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.ticket_messages m join public.tickets t on t.id = m.ticket_id
    where p_name = any(m.images)
      and (t.author_id = auth.uid() or public.ticket_staff(t.category))
      and (not m.internal or t.author_id <> auth.uid()))
$$;

drop policy if exists "ticket_images_insert" on storage.objects;
create policy "ticket_images_insert" on storage.objects
  for insert to authenticated with check (bucket_id = 'tickets' and public.is_member());

drop policy if exists "ticket_images_select" on storage.objects;
create policy "ticket_images_select" on storage.objects
  for select to authenticated using (bucket_id = 'tickets' and public.can_read_ticket_image(name));

-- Quem chama cada função
revoke execute on function public.recruit_clean_wanted(jsonb), public.recruit_guard(uuid, text), public.create_recruit(jsonb),
  public.update_recruit(bigint, jsonb), public.delete_recruit(bigint), public.decide_recruit(bigint, boolean, text),
  public.close_recruit(bigint, boolean), public.apply_recruit(bigint), public.withdraw_recruit(bigint),
  public.decide_application(bigint, uuid, text), public.ticket_staff(text), public.list_tickets(),
  public.create_ticket(text, text, boolean, text, text[]), public.post_ticket_message(bigint, text, boolean, text[]),
  public.set_ticket_status(bigint, text), public.assign_ticket(bigint, uuid), public.reveal_ticket_author(bigint),
  public.can_read_ticket_image(text) from public, anon;
grant execute on function public.recruit_clean_wanted(jsonb), public.recruit_guard(uuid, text), public.create_recruit(jsonb),
  public.update_recruit(bigint, jsonb), public.delete_recruit(bigint), public.decide_recruit(bigint, boolean, text),
  public.close_recruit(bigint, boolean), public.apply_recruit(bigint), public.withdraw_recruit(bigint),
  public.decide_application(bigint, uuid, text), public.ticket_staff(text), public.list_tickets(),
  public.create_ticket(text, text, boolean, text, text[]), public.post_ticket_message(bigint, text, boolean, text[]),
  public.set_ticket_status(bigint, text), public.assign_ticket(bigint, uuid), public.reveal_ticket_author(bigint),
  public.can_read_ticket_image(text) to authenticated;

-- =====================================================================
--  Login por e-mail: mostra o nome do perfil só parcialmente
--  ("Sangrento" -> "Sa******o"). O nome completo nunca sai do banco.
--  Só SUBSTITUI a função login_lookup. Não altera nem apaga nenhum dado.
-- =====================================================================
create or replace function public.login_lookup(p_email text) returns text
language sql stable security definer set search_path = public as $$
  select (
    select string_agg(
             case
               when char_length(w) <= 2 then left(w, 1) || repeat('*', char_length(w) - 1)
               when char_length(w) <= 4 then left(w, 1) || repeat('*', char_length(w) - 2) || right(w, 1)
               else left(w, 2) || repeat('*', char_length(w) - 3) || right(w, 1)
             end, ' ' order by i)
      from unnest(string_to_array(trim(n.nome), ' ')) with ordinality as t(w, i)
     where w <> ''
  )
  from (
    select coalesce(nullif(p.game_name, ''), nullif(p.discord_name, ''), 'Sem nome') as nome
      from auth.users u
      join public.profiles p on p.id = u.id
     where lower(u.email) = lower(trim(p_email))
       and length(trim(coalesce(p_email, ''))) between 3 and 254
     limit 1
  ) n;
$$;

revoke execute on function public.login_lookup(text) from public;
grant  execute on function public.login_lookup(text) to anon, authenticated;

-- =====================================================================
--  Privacidade dos membros (Novembro/2026)
--  1) Membro comum deixa de receber ex-membros, quem aguarda aprovação,
--     a data de cadastro dos outros e a foto que a pessoa removeu.
--  2) "Não selecionados" dos recrutamentos: só a própria pessoa, quem
--     criou e os oficiais/líder.
--  Só troca 2 regras de leitura e cria 1 visão. Nenhum dado é alterado
--  ou apagado. Oficiais e líder continuam vendo tudo como antes.
-- =====================================================================

-- Visão limitada dos perfis para membros comuns (só membros ativos)
create or replace view public.member_directory
with (security_barrier = true) as
select p.id, p.discord_name, p.game_name, p.role, p.managed,
       p.char_class, p.armor, p.armor_pen, p.potency, p.resistance, p.resonance,
       case when p.avatar_hidden then null else p.avatar_url end        as avatar_url,
       case when p.avatar_hidden then null else p.custom_avatar_url end as custom_avatar_url,
       p.avatar_hidden
  from public.profiles p
 where public.is_member() and p.role in ('member', 'officer', 'leader');

revoke all    on public.member_directory from public, anon;
grant  select on public.member_directory to authenticated;

-- Tabela completa de perfis: o próprio, as contas que pilota e a liderança
drop policy if exists "profiles_select" on public.profiles;
create policy "profiles_select" on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.can_act_as(id) or public.is_officer());

-- Candidaturas recusadas ficam só para a pessoa, quem criou e a liderança
drop policy if exists "recruit_apps_select" on public.recruit_applications;
create policy "recruit_apps_select" on public.recruit_applications
  for select to authenticated
  using (public.is_member() and exists (
    select 1 from public.recruitments r
     where r.id = recruit_applications.recruit_id
       and (recruit_applications.status <> 'declined'
            or recruit_applications.user_id = auth.uid()
            or r.created_by = auth.uid()
            or public.is_officer())));

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

-- =====================================================================
--  Ausência programada (Novembro/2026)
--  O membro (ou quem pilota a conta, ou a liderança) informa um período
--  em que não vai jogar. Todos os eventos do período ficam "Não vou"
--  automaticamente, inclusive os criados depois. A pessoa pode trocar
--  para "Vou" num evento específico. Eventos da ausência não contam
--  como falta na frequência nem nas medalhas.
--  O motivo é obrigatório e só a própria pessoa e a liderança veem.
--  Só ADICIONA tabela, coluna, funções e gatilhos. Nenhum dado existente
--  é alterado ou apagado.
-- =====================================================================

create table if not exists public.absences (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  starts_on  date not null,
  ends_on    date not null,
  reason     text not null check (char_length(btrim(reason)) between 1 and 300),
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  check (ends_on >= starts_on and ends_on - starts_on <= 180)
);
create index if not exists absences_user_idx on public.absences (user_id, starts_on);

-- Resposta "Não vou" criada pela ausência (guarda o número da ausência)
alter table public.rsvps add column if not exists absence_id bigint;

alter table public.absences enable row level security;
-- Ver: a própria pessoa, quem pilota a conta e a liderança. Escrever: só pelas funções abaixo.
drop policy if exists "absences_select" on public.absences;
create policy "absences_select" on public.absences
  for select to authenticated using (public.can_act_as(user_id) or public.is_officer());

-- Data do evento no horário de Brasília
create or replace function public.event_day(p_ts timestamptz) returns date
language sql immutable as $$ select (p_ts at time zone 'America/Sao_Paulo')::date $$;

-- Aplica uma ausência nos eventos futuros do período.
-- Sem resposta → "Não vou". "Vou" → "Não vou" se ainda dá para mudar (prazo aberto e sem time travado);
-- oficiais e líder mudam sempre. Devolve quantos eventos foram alterados.
create or replace function public.apply_absence(p_id bigint) returns integer
language plpgsql security definer set search_path = public as $$
declare a public.absences; n integer := 0; k integer;
begin
  select * into a from public.absences where id = p_id;
  if not found then return 0; end if;
  insert into public.rsvps (event_id, user_id, going, absence_id, updated_at)
  select e.id, a.user_id, false, a.id, now()
    from public.events e
   where e.starts_at > now() and public.event_day(e.starts_at) between a.starts_on and a.ends_on
     and not exists (select 1 from public.rsvps r where r.event_id = e.id and r.user_id = a.user_id);
  get diagnostics k = row_count; n := n + k;
  update public.rsvps r set going = false, discord = null, absence_id = a.id, updated_at = now(),
         withdraw_reason = null, withdraw_requested_at = null
    from public.events e
   where r.event_id = e.id and r.user_id = a.user_id and r.going
     and e.starts_at > now() and public.event_day(e.starts_at) between a.starts_on and a.ends_on
     and (public.is_officer() or public.can_change_rsvp_for(e.id, a.user_id));
  get diagnostics k = row_count; n := n + k;
  return n;
end $$;

-- Cadastra uma ausência. Devolve { id, changed }.
create or replace function public.save_absence(p_user uuid, p_start date, p_end date, p_reason text) returns json
language plpgsql security definer set search_path = public as $$
declare v_id bigint; today date := public.event_day(now());
begin
  if not (public.can_act_as(p_user) or public.is_officer()) then
    raise exception 'Você não pode programar ausência para esta conta' using errcode = '42501';
  end if;
  if not public.is_active_account(p_user) then raise exception 'Esta conta não está ativa no clã'; end if;
  if p_start is null or p_end is null or p_end < p_start then raise exception 'Confira as datas da ausência'; end if;
  if p_start < today then raise exception 'A ausência não pode começar antes de hoje'; end if;
  if p_end - p_start > 180 then raise exception 'A ausência pode ter no máximo 180 dias'; end if;
  if char_length(btrim(coalesce(p_reason, ''))) = 0 then raise exception 'Informe o motivo da ausência'; end if;
  if exists (select 1 from public.absences where user_id = p_user and starts_on <= p_end and ends_on >= p_start) then
    raise exception 'Já existe uma ausência neste período';
  end if;
  insert into public.absences (user_id, starts_on, ends_on, reason)
  values (p_user, p_start, p_end, left(btrim(p_reason), 300)) returning id into v_id;
  return json_build_object('id', v_id, 'changed', public.apply_absence(v_id));
end $$;

-- Encerra (em andamento) ou cancela (futura) uma ausência.
-- (Os eventos que já passaram continuam fora da frequência.)
create or replace function public.delete_absence(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare a public.absences;
begin
  select * into a from public.absences where id = p_id;
  if not found then return; end if;
  if not (public.can_act_as(a.user_id) or public.is_officer()) then
    raise exception 'Sem permissão para cancelar esta ausência' using errcode = '42501';
  end if;
  -- Em andamento (Encerrar): a data final passa a ser hoje e só os eventos depois de hoje são liberados.
  -- Ainda não começou (Cancelar): libera todos os eventos e a ausência sai da lista.
  delete from public.rsvps r using public.events e
   where r.event_id = e.id and r.absence_id = a.id and not r.going and e.starts_at > now()
     and (a.starts_on > public.event_day(now()) or public.event_day(e.starts_at) > public.event_day(now()));
  if a.starts_on <= public.event_day(now()) then
    update public.absences set ends_on = least(ends_on, public.event_day(now())) where id = a.id;
  else
    delete from public.absences where id = a.id;
  end if;
end $$;

-- Evento criado ou com data alterada: aplica as ausências que cobrem a nova data
create or replace function public.events_absences() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    if new.starts_at is not distinct from old.starts_at then return new; end if;
    delete from public.rsvps where event_id = new.id and absence_id is not null and not going;
  end if;
  if new.starts_at > now() then
    insert into public.rsvps (event_id, user_id, going, absence_id, updated_at)
    select new.id, a.user_id, false, a.id, now()
      from public.absences a
     where public.event_day(new.starts_at) between a.starts_on and a.ends_on
       and public.is_active_account(a.user_id)
    on conflict (event_id, user_id) do nothing;
  end if;
  return new;
end $$;
drop trigger if exists events_absences on public.events;
create trigger events_absences after insert or update of starts_at on public.events
  for each row execute function public.events_absences();

-- Quem troca para "Vou" deixa de estar marcado como ausente naquele evento
create or replace function public.rsvps_clear_absence() returns trigger
language plpgsql as $$
begin
  if new.going and new.absence_id is not null then new.absence_id := null; end if;
  return new;
end $$;
drop trigger if exists rsvps_clear_absence on public.rsvps;
create trigger rsvps_clear_absence before update on public.rsvps
  for each row execute function public.rsvps_clear_absence();

revoke execute on function public.apply_absence(bigint) from public, anon, authenticated;
revoke execute on function public.save_absence(uuid, date, date, text) from public, anon;
revoke execute on function public.delete_absence(bigint) from public, anon;
grant  execute on function public.save_absence(uuid, date, date, text) to authenticated;
grant  execute on function public.delete_absence(bigint) to authenticated;

-- Medalhas: eventos de ausência (sem presença) não quebram a sequência nem o mês perfeito
create or replace function public.member_badges()
returns table (user_id uuid, streak integer, perfect_months integer, res_gain integer)
language sql stable security definer set search_path = public as $$
  with mem as (
    select p.id, p.created_at, p.resonance
      from public.profiles p
     where public.is_member() and p.role in ('member', 'officer', 'leader')
  ),
  reg as (
    select e.id, e.starts_at
      from public.events e
     where e.starts_at <= now() and exists (select 1 from public.attendance a where a.event_id = e.id)
  ),
  hist0 as (
    select m.id as uid, r.id as event_id, r.starts_at,
           coalesce((select a.present from public.attendance a where a.event_id = r.id and a.user_id = m.id), false) as was
      from mem m join reg r on r.starts_at >= m.created_at
  ),
  hist as (
    select h.uid, h.starts_at, h.was from hist0 h
     where h.was or not exists (select 1 from public.rsvps v
                                 where v.event_id = h.event_id and v.user_id = h.uid and v.absence_id is not null)
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

-- =====================================================================
--  Resultado das Guerras (Novembro/2026)
--  Oficiais e líder registram o resultado de um evento que já começou:
--  Vitória ou Derrota, clã adversário, placar (Nós × Eles, opcional)
--  e observações. Todos os membros veem o resultado na página do evento;
--  as observações ficam numa tabela separada que só a liderança lê.
--  Permissão nova em Configurações: "results" (Registrar resultados).
--  Só ADICIONA tabelas e funções. Nenhum dado existente é alterado ou apagado.
-- =====================================================================

create table if not exists public.event_results (
  event_id   bigint primary key references public.events(id) on delete cascade,
  outcome    text not null check (outcome in ('win', 'loss')),
  opponent   text check (opponent is null or char_length(opponent) between 1 and 60),
  score_us   integer check (score_us is null or score_us between 0 and 1000000000),
  score_them integer check (score_them is null or score_them between 0 and 1000000000),
  updated_by uuid default auth.uid() references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

-- Observações: só oficiais e líder
create table if not exists public.event_result_notes (
  event_id bigint primary key references public.event_results(event_id) on delete cascade,
  notes    text not null check (char_length(notes) between 1 and 1000)
);

alter table public.event_results      enable row level security;
alter table public.event_result_notes enable row level security;

-- Ler: resultado para todos os membros; observações só para a liderança.
-- Escrever: só pelas funções abaixo.
drop policy if exists "results_select" on public.event_results;
create policy "results_select" on public.event_results
  for select to authenticated using (public.is_member());

drop policy if exists "result_notes_select" on public.event_result_notes;
create policy "result_notes_select" on public.event_result_notes
  for select to authenticated using (public.is_officer());

-- Registra ou altera o resultado de um evento
create or replace function public.save_event_result(
  p_event bigint, p_outcome text, p_opponent text, p_us integer, p_them integer, p_notes text
) returns void
language plpgsql security definer set search_path = public as $$
declare v_notes text := nullif(btrim(coalesce(p_notes, '')), '');
begin
  if not public.is_officer() then
    raise exception 'Só oficiais e o líder registram resultados' using errcode = '42501';
  end if;
  perform public.require_perm('results');
  if not exists (select 1 from public.events where id = p_event and starts_at <= now()) then
    raise exception 'O resultado só pode ser registrado depois que o evento começar';
  end if;
  if p_outcome not in ('win', 'loss') then raise exception 'Escolha Vitória ou Derrota'; end if;
  insert into public.event_results (event_id, outcome, opponent, score_us, score_them, updated_by, updated_at)
  values (p_event, p_outcome, nullif(left(btrim(coalesce(p_opponent, '')), 60), ''), p_us, p_them, auth.uid(), now())
  on conflict (event_id) do update
    set outcome = excluded.outcome, opponent = excluded.opponent, score_us = excluded.score_us,
        score_them = excluded.score_them, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  if v_notes is null then
    delete from public.event_result_notes where event_id = p_event;
  else
    insert into public.event_result_notes (event_id, notes) values (p_event, left(v_notes, 1000))
    on conflict (event_id) do update set notes = excluded.notes;
  end if;
end $$;

-- Tira o resultado de um evento (as observações saem junto)
create or replace function public.delete_event_result(p_event bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_officer() then
    raise exception 'Só oficiais e o líder alteram resultados' using errcode = '42501';
  end if;
  perform public.require_perm('results');
  delete from public.event_results where event_id = p_event;
end $$;

revoke execute on function public.save_event_result(bigint, text, text, integer, integer, text) from public, anon;
revoke execute on function public.delete_event_result(bigint) from public, anon;
grant  execute on function public.save_event_result(bigint, text, text, integer, integer, text) to authenticated;
grant  execute on function public.delete_event_result(bigint) to authenticated;

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

-- =====================================================================
--  Pedido para sair do clã (Novembro/2026)
--  O membro (ou quem pilota a conta) pede para sair, com motivo obrigatório.
--  A liderança aprova ou recusa. Aprovado: a conta vira "Ex-membro", igual
--  ao "Remover do clã" (o histórico é mantido e dá para readmitir depois).
--  Quem aprova: o líder sempre; oficiais conforme a nova permissão
--  "leave_approve" (Configurações → Membros → Aprovar saída do clã).
--  Oficiais só aprovam pedidos de membros comuns; o de oficiais fica com o líder.
--  Só ADICIONA tabela e funções, e atualiza o gatilho de permissões de cargo
--  para aceitar a saída aprovada. Nenhum dado existente é alterado ou apagado.
-- =====================================================================

create table if not exists public.leave_requests (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  reason       text not null check (char_length(btrim(reason)) between 1 and 300),
  requested_by uuid default auth.uid() references public.profiles(id) on delete set null,
  requested_at timestamptz not null default now(),
  status       text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  decided_by   uuid references public.profiles(id) on delete set null,
  decided_at   timestamptz,
  note         text check (note is null or char_length(note) <= 300)
);
-- No máximo um pedido em aberto por conta
create unique index if not exists leave_requests_one_pending on public.leave_requests (user_id) where status = 'pending';

alter table public.leave_requests enable row level security;
-- Ver: a própria pessoa, quem pilota a conta e a liderança. Escrever: só pelas funções abaixo.
drop policy if exists "leave_select" on public.leave_requests;
create policy "leave_select" on public.leave_requests
  for select to authenticated using (public.can_act_as(user_id) or public.is_officer());

-- Pedir para sair
create or replace function public.request_leave(p_user uuid, p_reason text) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_role text; v_id bigint;
begin
  if not public.can_act_as(p_user) then
    raise exception 'Você não pode pedir a saída desta conta' using errcode = '42501';
  end if;
  select role into v_role from public.profiles where id = p_user;
  if v_role = 'leader' then raise exception 'O líder não pode sair do clã por aqui'; end if;
  if v_role is null or v_role not in ('member', 'officer') then raise exception 'Esta conta não está ativa no clã'; end if;
  if char_length(btrim(coalesce(p_reason, ''))) = 0 then raise exception 'Informe o motivo da saída'; end if;
  if exists (select 1 from public.leave_requests where user_id = p_user and status = 'pending') then
    raise exception 'Já existe um pedido de saída em aberto para esta conta';
  end if;
  insert into public.leave_requests (user_id, reason) values (p_user, left(btrim(p_reason), 300)) returning id into v_id;
  return v_id;
end $$;

-- Desistir do pedido
create or replace function public.cancel_leave(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare r public.leave_requests;
begin
  select * into r from public.leave_requests where id = p_id for update;
  if not found or r.status <> 'pending' then raise exception 'Este pedido não está mais em aberto'; end if;
  if not public.can_act_as(r.user_id) then raise exception 'Sem permissão' using errcode = '42501'; end if;
  update public.leave_requests set status = 'cancelled', decided_by = auth.uid(), decided_at = now() where id = p_id;
end $$;

-- Aprovar ou recusar
create or replace function public.decide_leave(p_id bigint, p_approve boolean, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare r public.leave_requests; v_cur text; v_me text := public.my_role();
begin
  select * into r from public.leave_requests where id = p_id for update;
  if not found or r.status <> 'pending' then raise exception 'Este pedido já foi decidido'; end if;
  if public.can_act_as(r.user_id) then raise exception 'Você não pode decidir o pedido da sua própria conta'; end if;
  select role into v_cur from public.profiles where id = r.user_id;
  if v_me = 'leader' then
    null;
  elsif v_me = 'officer' and v_cur in ('member', 'former') then
    perform public.require_perm('leave_approve');
  else
    raise exception 'Sem permissão para decidir este pedido' using errcode = '42501';
  end if;
  if p_approve and v_cur is distinct from 'former' then
    -- Mesmo efeito do "Remover do clã"
    perform set_config('infernum.leave_ok', '1', true);
    perform set_config('infernum.reason', left('Pediu para sair do clã: ' || r.reason, 300), true);
    update public.profiles set role = 'former' where id = r.user_id;
    delete from public.rsvps v using public.events e
     where v.event_id = e.id and v.user_id = r.user_id and e.starts_at > now();
    delete from public.member_contacts where user_id = r.user_id;
    delete from public.account_pilots where pilot_id = r.user_id;
    perform set_config('infernum.leave_ok', '', true);
  end if;
  update public.leave_requests
     set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = auth.uid(), decided_at = now(),
         note = nullif(left(btrim(coalesce(p_note, '')), 300), '')
   where id = p_id;
end $$;

revoke execute on function public.request_leave(uuid, text) from public, anon;
revoke execute on function public.cancel_leave(bigint) from public, anon;
revoke execute on function public.decide_leave(bigint, boolean, text) from public, anon;
grant  execute on function public.request_leave(uuid, text) to authenticated;
grant  execute on function public.cancel_leave(bigint) to authenticated;
grant  execute on function public.decide_leave(bigint, boolean, text) to authenticated;

-- Gatilho de permissões de cargo: a saída aprovada por decide_leave usa a permissão
-- "leave_approve" (já conferida lá), e não "Remover membros".
create or replace function public.perm_profiles_role() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if current_setting('infernum.leave_ok', true) = '1' then return new; end if;
  if public.my_role() = 'officer' and new.id <> auth.uid() and new.role is distinct from old.role then
    if old.role = 'pending' and new.role = 'member' then
      perform public.require_perm('member_approve');
    elsif new.role = 'former' or (old.role = 'member' and new.role = 'pending') then
      perform public.require_perm('member_remove');
    end if;
  end if;
  return new;
end $$;

-- =====================================================================
--  Histórico de alterações dos eventos (quem mexeu no evento e em cada sala)
--  Só ADICIONA uma tabela, funções e gatilhos, e troca a função save_teams
--  por uma versão que também registra o histórico (mesmo funcionamento).
--  Nenhum dado existente é alterado ou apagado. Pode ser executado de novo.
--  O histórico começa a contar a partir de quando este arquivo for executado.
-- =====================================================================

create table if not exists public.event_log (
  id       bigint generated always as identity primary key,
  event_id bigint not null references public.events(id) on delete cascade,
  at       timestamptz not null default now(),
  actor    uuid references public.profiles(id) on delete set null,
  kind     text not null check (kind in ('created', 'edit', 'format', 'rename', 'lock', 'unlock', 'room')),
  room     text,
  detail   jsonb not null default '{}'::jsonb
);
create index if not exists event_log_event_idx on public.event_log (event_id, at desc);

alter table public.event_log enable row level security;

-- Só líder e oficiais leem; as escritas são só pelos gatilhos abaixo
drop policy if exists "event_log_select" on public.event_log;
create policy "event_log_select" on public.event_log
  for select to authenticated using (public.is_officer());

-- ---------- Alterações no próprio evento ----------
create or replace function public.log_event_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  d jsonb := '{}'::jsonb;
  i int;
  o text;
  n text;
begin
  if tg_op = 'INSERT' then
    insert into public.event_log (event_id, actor, kind) values (new.id, auth.uid(), 'created');
    return new;
  end if;

  if new.title is distinct from old.title then d := d || jsonb_build_object('title', jsonb_build_array(old.title, new.title)); end if;
  if new.description is distinct from old.description then d := d || jsonb_build_object('description', true); end if;
  if new.starts_at is distinct from old.starts_at then d := d || jsonb_build_object('starts_at', jsonb_build_array(old.starts_at, new.starts_at)); end if;
  if new.type_id is distinct from old.type_id then d := d || jsonb_build_object('type_id', jsonb_build_array(old.type_id, new.type_id)); end if;
  if new.rsvp_close_minutes is distinct from old.rsvp_close_minutes then
    d := d || jsonb_build_object('rsvp_close_minutes', jsonb_build_array(old.rsvp_close_minutes, new.rsvp_close_minutes));
  end if;
  if d <> '{}'::jsonb then
    insert into public.event_log (event_id, actor, kind, detail) values (new.id, auth.uid(), 'edit', d);
  end if;

  if (new.team_format, new.team_count) is distinct from (old.team_format, old.team_count) then
    insert into public.event_log (event_id, actor, kind, detail)
    values (new.id, auth.uid(), 'format', jsonb_build_object(
      'format', jsonb_build_array(old.team_format, new.team_format),
      'count',  jsonb_build_array(old.team_count, new.team_count)));
  elsif new.team_names is distinct from old.team_names then
    -- Renomear time (formato Outros): uma linha por time renomeado
    for i in 1..10 loop
      o := coalesce(nullif(btrim(old.team_names[i]), ''), 'Time ' || i);
      n := coalesce(nullif(btrim(new.team_names[i]), ''), 'Time ' || i);
      if o <> n then
        insert into public.event_log (event_id, actor, kind, room, detail)
        values (new.id, auth.uid(), 'rename', n, jsonb_build_object('from', o, 'to', n));
      end if;
    end loop;
  end if;

  if new.teams_locked is distinct from old.teams_locked then
    insert into public.event_log (event_id, actor, kind)
    values (new.id, auth.uid(), case when new.teams_locked then 'lock' else 'unlock' end);
  end if;
  return new;
end $$;

drop trigger if exists events_log on public.events;
create trigger events_log after insert or update on public.events
  for each row execute function public.log_event_change();

-- ---------- Salas (times) ----------
-- Registra, por sala, quem entrou e quem saiu (comparando antes e depois)
create or replace function public.log_room_diff(p_event bigint, p_old jsonb, p_new jsonb) returns void
language sql security definer set search_path = public as $$
  with o as (select x ->> 'team' as team, (x ->> 'user_id')::uuid as uid from jsonb_array_elements(coalesce(p_old, '[]'::jsonb)) x),
       n as (select x ->> 'team' as team, (x ->> 'user_id')::uuid as uid from jsonb_array_elements(coalesce(p_new, '[]'::jsonb)) x),
       a as (select team, uid from n except select team, uid from o),
       r as (select team, uid from o except select team, uid from n),
       rooms as (select team from a union select team from r)
  insert into public.event_log (event_id, actor, kind, room, detail)
  select p_event, auth.uid(), 'room', rooms.team, jsonb_build_object(
           'added',   coalesce((select jsonb_agg(a.uid) from a where a.team = rooms.team), '[]'::jsonb),
           'removed', coalesce((select jsonb_agg(r.uid) from r where r.team = rooms.team), '[]'::jsonb))
  from rooms
$$;

-- Salvar os times (painel "Montar times"): mesmo funcionamento de antes + histórico por sala
create or replace function public.save_teams(p_event bigint, p_slots jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_old jsonb;
begin
  if not public.is_officer() then
    raise exception 'Sem permissão para montar times';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('user_id', user_id, 'team', team)), '[]'::jsonb) into v_old
    from public.team_slots where event_id = p_event;
  -- os gatilhos de sala não registram nada aqui: o resumo é feito abaixo
  perform set_config('infernum.slots_logged', '1', true);
  delete from public.team_slots where event_id = p_event;
  insert into public.team_slots (event_id, user_id, team)
  select p_event, (s ->> 'user_id')::uuid, s ->> 'team'
    from jsonb_array_elements(coalesce(p_slots, '[]'::jsonb)) as s;
  perform set_config('infernum.slots_logged', '', true);
  perform public.log_room_diff(p_event, v_old, coalesce(p_slots, '[]'::jsonb));
end $$;

-- Outras saídas de sala: "Não vou", saída aceita, times removidos ao trocar o formato, membro removido do clã
create or replace function public.log_slots_deleted() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('infernum.slots_logged', true), '') = '1' then return null; end if;
  insert into public.event_log (event_id, actor, kind, room, detail)
  select x.event_id, auth.uid(), 'room', x.team,
         jsonb_build_object('added', '[]'::jsonb, 'removed', jsonb_agg(x.user_id), 'auto', bool_and(x.auto))
  from (
    select o.event_id, o.team, o.user_id,
           not exists (select 1 from public.rsvps r where r.event_id = o.event_id and r.user_id = o.user_id and r.going) as auto
    from old_rows o
    where exists (select 1 from public.events e where e.id = o.event_id)
  ) x
  group by x.event_id, x.team;
  return null;
end $$;

drop trigger if exists team_slots_log_del on public.team_slots;
create trigger team_slots_log_del after delete on public.team_slots
  referencing old table as old_rows
  for each statement execute function public.log_slots_deleted();

-- Entradas em sala fora do painel (raro)
create or replace function public.log_slots_inserted() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('infernum.slots_logged', true), '') = '1' then return null; end if;
  insert into public.event_log (event_id, actor, kind, room, detail)
  select n.event_id, auth.uid(), 'room', n.team, jsonb_build_object('added', jsonb_agg(n.user_id), 'removed', '[]'::jsonb)
  from new_rows n
  group by n.event_id, n.team;
  return null;
end $$;

drop trigger if exists team_slots_log_ins on public.team_slots;
create trigger team_slots_log_ins after insert on public.team_slots
  referencing new table as new_rows
  for each statement execute function public.log_slots_inserted();

-- Quem chama cada função
revoke execute on function public.log_room_diff(bigint, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.save_teams(bigint, jsonb) from public, anon;
grant  execute on function public.save_teams(bigint, jsonb) to authenticated;

-- =====================================================================
--  Histórico de status dos tickets (quem encerrou, reabriu ou pôs em atendimento)
--  Só ADICIONA uma tabela e um gatilho, e troca a função list_tickets por uma
--  versão que também devolve esse histórico (mesmo funcionamento).
--  Nenhum dado existente é alterado ou apagado. Pode ser executado de novo.
--  O histórico começa a contar a partir de quando este arquivo for executado.
-- =====================================================================

create table if not exists public.ticket_log (
  id          bigint generated always as identity primary key,
  ticket_id   bigint not null references public.tickets(id) on delete cascade,
  at          timestamptz not null default now(),
  actor       uuid references public.profiles(id) on delete set null,
  by_author   boolean not null default false,   -- true = foi quem abriu o ticket (o jogador)
  from_status text,
  to_status   text not null
);
create index if not exists ticket_log_ticket_idx on public.ticket_log (ticket_id, at);

-- Sem leitura direta: o histórico sai pela list_tickets, que esconde o autor dos anônimos
alter table public.ticket_log enable row level security;

-- Toda mudança de status fica registrada (pelo botão, por uma resposta ou ao assumir)
create or replace function public.log_ticket_status() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status then
    insert into public.ticket_log (ticket_id, actor, by_author, from_status, to_status)
    values (new.id, auth.uid(), auth.uid() is not distinct from new.author_id, old.status, new.status);
  end if;
  return null;
end $$;

drop trigger if exists ticket_status_log on public.tickets;
create trigger ticket_status_log after update of status on public.tickets
  for each row execute function public.log_ticket_status();

-- Mesma list_tickets de antes, agora com o campo "log"
create or replace function public.list_tickets() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(x order by x.created_at desc), '[]'::json) from (
    select t.id, t.title, t.category, t.anonymous, t.status, t.assigned_to, t.created_at,
      (t.author_id = auth.uid()) as mine,
      case when t.anonymous and t.author_id <> auth.uid() then null else t.author_id end as author_id,
      (select coalesce(json_agg(json_build_object(
          'id', m.id, 'body', m.body, 'internal', m.internal, 'images', m.images, 'created_at', m.created_at,
          'from_author', m.author_id is not distinct from t.author_id,
          'author_id', case when t.anonymous and t.author_id <> auth.uid() and m.author_id = t.author_id then null else m.author_id end)
        order by m.created_at), '[]'::json)
       from public.ticket_messages m
       where m.ticket_id = t.id and (not m.internal or t.author_id <> auth.uid())) as messages,
      (select coalesce(json_agg(json_build_object(
          'at', l.at, 'from_status', l.from_status, 'to_status', l.to_status, 'by_author', l.by_author,
          'actor', case when l.by_author and t.anonymous and t.author_id <> auth.uid() then null else l.actor end)
        order by l.at, l.id), '[]'::json)
       from public.ticket_log l where l.ticket_id = t.id) as log
    from public.tickets t
    where public.is_member() and (t.author_id = auth.uid() or public.ticket_staff(t.category))
  ) x
$$;

revoke all on function public.list_tickets() from public, anon;
grant execute on function public.list_tickets() to authenticated;

-- =====================================================================
--  Oficiais e líder editam o nick (nome do personagem) dos membros
--  Só ADICIONA uma função. Nenhum dado existente é alterado ou apagado.
--  Pode ser executado de novo. A troca entra no histórico do membro,
--  com quem trocou (coluna changed_by do profile_history).
-- =====================================================================

create or replace function public.set_member_name(p_user uuid, p_name text) returns void
language plpgsql security definer set search_path = public as $$
declare
  me  text := public.my_role();
  cur text;
  v   text := trim(coalesce(p_name, ''));
begin
  if me is distinct from 'leader' and me is distinct from 'officer' then
    raise exception 'Só oficiais e o líder podem editar o nick dos membros' using errcode = '42501';
  end if;
  if char_length(v) = 0 then raise exception 'Escreva o nick'; end if;
  if char_length(v) > 40 then raise exception 'O nick pode ter no máximo 40 caracteres'; end if;
  select role into cur from public.profiles where id = p_user;
  if cur is null then raise exception 'Membro não encontrado'; end if;
  if me = 'officer' then
    perform public.require_perm('member_rename');
    -- Oficial edita o próprio nick e o dos membros; o de outros oficiais e do líder, só o líder
    if p_user <> auth.uid() and cur not in ('pending', 'member', 'former') then
      raise exception 'Só o líder pode editar o nick de oficiais e do líder' using errcode = '42501';
    end if;
  end if;
  update public.profiles set game_name = v where id = p_user;
end $$;

revoke execute on function public.set_member_name(uuid, text) from public, anon;
grant  execute on function public.set_member_name(uuid, text) to authenticated;
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

-- =====================================================================
--  Codinome dos membros (Novembro/2026)
--  Nome simplificado (ex.: para nicks com símbolos ou letras chinesas) que
--  só oficiais e o líder atribuem. Não aparece no site: serve só para
--  encontrar o membro nas buscas (Membros, presença, seletor de membros e
--  pedido de piloto).
--  Quem edita: o líder sempre; oficiais conforme a nova permissão
--  "member_alias" (Configurações → Membros → Editar codinome). Oficiais
--  editam o próprio codinome e o de membros, de quem aguarda aprovação e de
--  ex-membros; o de outros oficiais e do líder, só o líder.
--  A troca entra no histórico do membro, com quem trocou.
--  Só ADICIONA uma coluna (vazia) e funções, e atualiza o registro de
--  histórico e a busca de contas para considerar o codinome.
--  Nenhum dado existente é alterado ou apagado. Pode ser executado de novo.
-- =====================================================================

alter table public.profiles add column if not exists alias text;
do $$ begin
  alter table public.profiles add constraint profiles_alias_len check (alias is null or char_length(alias) <= 40);
exception when duplicate_object then null; end $$;
-- Ninguém escreve direto na coluna (o "update" dos perfis é liberado só coluna a coluna);
-- a troca é feita pela função abaixo.

create or replace function public.set_member_alias(p_user uuid, p_alias text) returns void
language plpgsql security definer set search_path = public as $$
declare
  me  text := public.my_role();
  cur text;
  v   text := nullif(trim(coalesce(p_alias, '')), '');
begin
  if me is distinct from 'leader' and me is distinct from 'officer' then
    raise exception 'Só oficiais e o líder podem editar o codinome' using errcode = '42501';
  end if;
  if char_length(v) > 40 then raise exception 'O codinome pode ter no máximo 40 caracteres'; end if;
  select role into cur from public.profiles where id = p_user;
  if cur is null then raise exception 'Membro não encontrado'; end if;
  if me = 'officer' then
    perform public.require_perm('member_alias');
    if p_user <> auth.uid() and cur not in ('pending', 'member', 'former') then
      raise exception 'Só o líder pode editar o codinome de oficiais e do líder' using errcode = '42501';
    end if;
  end if;
  update public.profiles set alias = v where id = p_user;
end $$;

revoke execute on function public.set_member_alias(uuid, text) from public, anon;
grant  execute on function public.set_member_alias(uuid, text) to authenticated;

-- Histórico do perfil: passa a registrar também o codinome
create or replace function public.log_profile_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  diff jsonb := '{}'::jsonb;
  f    text;
  o    jsonb := to_jsonb(old);
  n    jsonb := to_jsonb(new);
begin
  foreach f in array array['discord_name', 'game_name', 'char_class', 'alias',
                           'armor', 'armor_pen', 'potency', 'resistance', 'resonance'] loop
    if (o -> f) is distinct from (n -> f) then
      diff := diff || jsonb_build_object(f, jsonb_build_array(o -> f, n -> f));
    end if;
  end loop;
  if diff <> '{}'::jsonb then
    insert into public.profile_history (user_id, changes) values (new.id, diff);
  end if;
  return new;
end $$;

-- Pedido de piloto: a busca de contas também encontra pelo codinome
-- (o resultado continua mostrando só o nick e a classe)
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
         and (coalesce(nullif(trim(p.game_name), ''), p.discord_name) ilike '%' || (select s from q) || '%'
              or coalesce(p.alias, '') ilike '%' || (select s from q) || '%')
       order by 2 limit 8) x), '[]'::json) end
$$;

revoke execute on function public.find_accounts(text) from public, anon;
grant  execute on function public.find_accounts(text) to authenticated;

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
