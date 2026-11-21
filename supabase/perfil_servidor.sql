-- =====================================================================
--  Meu perfil: comparar os atributos com o servidor (Novembro/2026)
--  Qualquer membro pode ver as MÉDIAS do servidor no perfil: a função abaixo
--  entrega só os 5 atributos de cada jogador rival (sem nome do jogador e sem
--  nome do clã), da leitura mais recente de cada clã. O INFERNUM fica de fora
--  (ele entra pelos próprios membros, com os atributos do perfil).
--  Só CRIA funções novas. Nenhuma tabela ou dado é alterado. Pode ser
--  executado de novo.
-- =====================================================================

-- Nome sem acentos e minúsculo (igual ao site)
create or replace function public.rival_norm(t text) returns text
language sql immutable set search_path = public as $$
  select lower(trim(translate(coalesce(t, ''),
    'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑáàâãäéèêëíìîïóòôõöúùûüçñ',
    'AAAAAEEEEIIIIOOOOOUUUUCNaaaaaeeeeiiiiooooouuuucn')))
$$;

-- Quantas letras precisam mudar para um nome virar o outro
create or replace function public.rival_edit_dist(a text, b text) returns int
language plpgsql immutable set search_path = public as $$
declare prev int[]; cur int[]; la int := char_length(a); lb int := char_length(b);
begin
  if abs(la - lb) > 3 then return 99; end if;
  prev := array(select generate_series(0, lb));
  for i in 1..la loop
    cur := array[i];
    for j in 1..lb loop
      cur := cur || least(prev[j + 1] + 1, cur[j] + 1, prev[j] + case when substr(a, i, 1) = substr(b, j, 1) then 0 else 1 end);
    end loop;
    prev := cur;
  end loop;
  return prev[lb + 1];
end $$;

-- Mesmo clã? Mesmo número, ou nome parecido com número parecido (igual ao site)
create or replace function public.rival_same_clan(an text, anum bigint, bn text, bnum bigint) returns boolean
language plpgsql immutable set search_path = public as $$
declare na text := public.rival_norm(an); nb text := public.rival_norm(bn); sa text; sb text; d int := 0;
begin
  if anum is not null and anum = bnum then return true; end if;
  if not (na = nb or public.rival_edit_dist(na, nb) <= case when least(char_length(na), char_length(nb)) >= 8 then 2 else 1 end) then
    return false;
  end if;
  if anum is null or bnum is null then return true; end if;
  sa := anum::text; sb := bnum::text;
  if char_length(sa) <> char_length(sb) then return false; end if;
  for i in 1..char_length(sa) loop
    if substr(sa, i, 1) <> substr(sb, i, 1) then d := d + 1; end if;
  end loop;
  return d <= 1;
end $$;

-- Atributos dos jogadores rivais (leitura mais recente de cada clã), sem nomes
create or replace function public.rival_server_pool()
returns table (scan_id bigint, armor int, armor_pen int, potency int, resistance int, resonance int)
language sql stable security definer set search_path = public as $$
  select p.scan_id, p.armor, p.armor_pen, p.potency, p.resistance, p.resonance
  from public.rival_players p
  join public.rival_scans s on s.id = p.scan_id
  where public.is_member()
    and not public.rival_same_clan(s.clan_name, s.clan_number, 'INFERNUM', null)
    and not exists (
      select 1 from public.rival_scans t
      where (t.scanned_on > s.scanned_on or (t.scanned_on = s.scanned_on and t.id > s.id))
        and public.rival_same_clan(s.clan_name, s.clan_number, t.clan_name, t.clan_number))
$$;

revoke execute on function public.rival_server_pool() from public, anon;
grant  execute on function public.rival_server_pool() to authenticated;
