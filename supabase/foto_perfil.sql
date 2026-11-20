-- =====================================================================
--  Foto de perfil: só endereços do espaço de fotos do próprio Supabase
--  (impede apontar para servidores de fora e rastrear quem vê a foto).
--  Se trocar o projeto do Supabase, troque o endereço abaixo também.
--  Pode ser executado de novo.
-- =====================================================================

-- Remove endereços que não são do espaço de fotos do site
update public.profiles
   set custom_avatar_url = null
 where custom_avatar_url is not null
   and custom_avatar_url not like 'https://xvqxggkmrurvcbaxyifh.supabase.co/storage/v1/object/public/avatars/' || id::text || '/%';

alter table public.profiles drop constraint if exists profiles_custom_avatar_url_check;
alter table public.profiles add constraint profiles_custom_avatar_url_check check (
  custom_avatar_url is null
  or custom_avatar_url like 'https://xvqxggkmrurvcbaxyifh.supabase.co/storage/v1/object/public/avatars/' || id::text || '/%'
);
