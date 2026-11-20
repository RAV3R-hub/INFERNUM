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
