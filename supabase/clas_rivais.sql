-- =====================================================================
--  Clãs rivais (Novembro/2026)
--  A liderança importa a planilha de mapeamento dos outros clãs (Scout).
--  Cada clã de cada planilha vira uma "leitura" com data; as leituras
--  antigas ficam guardadas para ver a evolução do rival.
--  Ver: líder e oficiais (a tela respeita a permissão "rivals_view").
--  Importar e apagar leituras: líder sempre; oficiais conforme a nova
--  permissão "rivals_import" (Configurações → Clãs rivais).
--  Só ADICIONA tabelas e funções. Nenhum dado existente é alterado ou
--  apagado. Pode ser executado de novo.
-- =====================================================================

create table if not exists public.rival_scans (
  id          bigint generated always as identity primary key,
  clan_name   text not null check (char_length(clan_name) between 1 and 60),
  clan_number bigint,
  scanned_on  date not null,
  source      text check (char_length(source) <= 200),
  created_by  uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);

create table if not exists public.rival_players (
  id          bigint generated always as identity primary key,
  scan_id     bigint not null references public.rival_scans(id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 60),
  armor       integer check (armor >= 0),
  armor_pen   integer check (armor_pen >= 0),
  potency     integer check (potency >= 0),
  resistance  integer check (resistance >= 0),
  resonance   integer check (resonance >= 0),
  note        text check (char_length(note) <= 200)
);
create index if not exists rival_players_scan_idx on public.rival_players (scan_id);

alter table public.rival_scans   enable row level security;
alter table public.rival_players enable row level security;
-- Ver: só a liderança. Escrever: só pelas funções abaixo.
drop policy if exists "rival_scans_select" on public.rival_scans;
create policy "rival_scans_select" on public.rival_scans
  for select to authenticated using (public.is_officer());
drop policy if exists "rival_players_select" on public.rival_players;
create policy "rival_players_select" on public.rival_players
  for select to authenticated using (public.is_officer());

-- Importa a leitura de um clã (o site já tira os repetidos antes):
-- p_players = [{name, armor, armor_pen, potency, resistance, resonance, note}]
create or replace function public.import_rival_scan(p_clan_name text, p_clan_number bigint, p_scanned_on date,
  p_source text, p_players jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_n int;
begin
  if not public.is_officer() then raise exception 'Só oficiais e o líder importam clãs rivais' using errcode = '42501'; end if;
  perform public.require_perm('rivals_import');
  if nullif(trim(p_clan_name), '') is null then raise exception 'Informe o nome do clã'; end if;
  if p_scanned_on is null or p_scanned_on > (now() at time zone 'America/Sao_Paulo')::date then raise exception 'Data da leitura inválida'; end if;
  if p_players is null or jsonb_typeof(p_players) <> 'array' then raise exception 'Lista de jogadores inválida'; end if;
  v_n := jsonb_array_length(p_players);
  if v_n = 0 or v_n > 150 then raise exception 'A leitura precisa ter de 1 a 150 jogadores'; end if;

  insert into public.rival_scans (clan_name, clan_number, scanned_on, source)
  values (left(trim(p_clan_name), 60), p_clan_number, p_scanned_on, left(nullif(trim(p_source), ''), 200))
  returning id into v_id;

  insert into public.rival_players (scan_id, name, armor, armor_pen, potency, resistance, resonance, note)
  select v_id, left(trim(p->>'name'), 60),
         nullif(p->>'armor', '')::int, nullif(p->>'armor_pen', '')::int, nullif(p->>'potency', '')::int,
         nullif(p->>'resistance', '')::int, nullif(p->>'resonance', '')::int, left(nullif(trim(p->>'note'), ''), 200)
  from jsonb_array_elements(p_players) p
  where nullif(trim(p->>'name'), '') is not null;
  return v_id;
end $$;

create or replace function public.delete_rival_scan(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_officer() then raise exception 'Só oficiais e o líder apagam leituras' using errcode = '42501'; end if;
  perform public.require_perm('rivals_import');
  delete from public.rival_scans where id = p_id;
end $$;

revoke execute on function public.import_rival_scan(text, bigint, date, text, jsonb) from public, anon;
revoke execute on function public.delete_rival_scan(bigint) from public, anon;
grant  execute on function public.import_rival_scan(text, bigint, date, text, jsonb) to authenticated;
grant  execute on function public.delete_rival_scan(bigint) to authenticated;
