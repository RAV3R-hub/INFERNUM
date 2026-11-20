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
