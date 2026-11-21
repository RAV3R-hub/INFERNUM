-- =====================================================================
--  Clãs rivais compartilhados com a FOR HONOR (Novembro/2026)
--  As leituras continuam guardadas aqui, no Supabase do INFERNUM. O site da
--  FOR HONOR lê, importa e apaga pela Edge Function "rivals-share", que
--  confere no Supabase de lá se a pessoa é líder ou oficial com permissão.
--  Guarda o clã e o nome de quem importou cada leitura, e um registro de
--  quem importou e quem apagou (o registro fica mesmo depois de apagar).
--  Só ADICIONA colunas e uma tabela e troca as duas funções de importar e
--  apagar. Nenhum dado existente é alterado ou apagado (as leituras que já
--  existem ficam como importadas pelo INFERNUM). Pode ser executado de novo.
-- =====================================================================

alter table public.rival_scans add column if not exists imported_by text not null default 'INFERNUM'
  check (char_length(imported_by) between 1 and 30);
alter table public.rival_scans add column if not exists imported_by_name text
  check (char_length(imported_by_name) <= 60);

-- Registro: quem importou e quem apagou cada leitura
create table if not exists public.rival_scan_log (
  id          bigint generated always as identity primary key,
  scan_id     bigint,                -- a leitura pode já ter sido apagada
  action      text not null check (action in ('import', 'delete')),
  clan_name   text not null,
  scanned_on  date,
  players     int,
  actor_clan  text not null check (char_length(actor_clan) between 1 and 30),
  actor_name  text check (char_length(actor_name) <= 60),
  created_at  timestamptz not null default now()
);
create index if not exists rival_scan_log_created_idx on public.rival_scan_log (created_at desc);
alter table public.rival_scan_log enable row level security;
drop policy if exists "rival_scan_log_select" on public.rival_scan_log;
create policy "rival_scan_log_select" on public.rival_scan_log
  for select to authenticated using (public.is_officer());

-- Nome de quem está logado aqui no INFERNUM
create or replace function public.rival_actor_name() returns text
language sql stable security definer set search_path = public as $$
  select left(coalesce(nullif(trim(game_name), ''), nullif(trim(discord_name), ''), 'Desconhecido'), 60)
  from public.profiles where id = auth.uid()
$$;
revoke execute on function public.rival_actor_name() from public, anon, authenticated;

create or replace function public.import_rival_scan(p_clan_name text, p_clan_number bigint, p_scanned_on date,
  p_source text, p_players jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_n int; v_name text := public.rival_actor_name(); v_count int;
begin
  if not public.is_officer() then raise exception 'Só oficiais e o líder importam clãs rivais' using errcode = '42501'; end if;
  perform public.require_perm('rivals_import');
  if nullif(trim(p_clan_name), '') is null then raise exception 'Informe o nome do clã'; end if;
  if p_scanned_on is null or p_scanned_on > (now() at time zone 'America/Sao_Paulo')::date then raise exception 'Data da leitura inválida'; end if;
  if p_players is null or jsonb_typeof(p_players) <> 'array' then raise exception 'Lista de jogadores inválida'; end if;
  v_n := jsonb_array_length(p_players);
  if v_n = 0 or v_n > 150 then raise exception 'A leitura precisa ter de 1 a 150 jogadores'; end if;

  insert into public.rival_scans (clan_name, clan_number, scanned_on, source, imported_by, imported_by_name)
  values (left(trim(p_clan_name), 60), p_clan_number, p_scanned_on, left(nullif(trim(p_source), ''), 200), 'INFERNUM', v_name)
  returning id into v_id;

  insert into public.rival_players (scan_id, name, armor, armor_pen, potency, resistance, resonance, note)
  select v_id, left(trim(p->>'name'), 60),
         nullif(p->>'armor', '')::int, nullif(p->>'armor_pen', '')::int, nullif(p->>'potency', '')::int,
         nullif(p->>'resistance', '')::int, nullif(p->>'resonance', '')::int, left(nullif(trim(p->>'note'), ''), 200)
  from jsonb_array_elements(p_players) p
  where nullif(trim(p->>'name'), '') is not null;
  get diagnostics v_count = row_count;

  insert into public.rival_scan_log (scan_id, action, clan_name, scanned_on, players, actor_clan, actor_name)
  values (v_id, 'import', left(trim(p_clan_name), 60), p_scanned_on, v_count, 'INFERNUM', v_name);
  return v_id;
end $$;

create or replace function public.delete_rival_scan(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare s public.rival_scans;
begin
  if not public.is_officer() then raise exception 'Só oficiais e o líder apagam leituras' using errcode = '42501'; end if;
  perform public.require_perm('rivals_import');
  select * into s from public.rival_scans where id = p_id;
  if not found then return; end if;
  insert into public.rival_scan_log (scan_id, action, clan_name, scanned_on, players, actor_clan, actor_name)
  values (s.id, 'delete', s.clan_name, s.scanned_on, (select count(*) from public.rival_players where scan_id = s.id),
          'INFERNUM', public.rival_actor_name());
  delete from public.rival_scans where id = p_id;
end $$;

revoke execute on function public.import_rival_scan(text, bigint, date, text, jsonb) from public, anon;
revoke execute on function public.delete_rival_scan(bigint) from public, anon;
grant  execute on function public.import_rival_scan(text, bigint, date, text, jsonb) to authenticated;
grant  execute on function public.delete_rival_scan(bigint) to authenticated;
