-- =====================================================================
--  Alta de perfiles. ANTES crea los usuarios en:
--  Supabase > Authentication > Users > Add user > Create new user
--    · jonas@example.com    (marca "Auto Confirm User")
--    · llarcas@example.com  (marca "Auto Confirm User")
--  En la app se entra solo con el usuario (jonas / llarcas): el
--  "@example.com" lo añade la app. Luego ejecuta esto en SQL Editor.
-- =====================================================================
insert into public.perfiles (id, usuario, nombre, rol)
select id, 'jonas', 'Jonas', 'alumno' from auth.users where email = 'jonas@example.com'
on conflict (id) do update set usuario = excluded.usuario, nombre = excluded.nombre, rol = excluded.rol;

insert into public.perfiles (id, usuario, nombre, rol)
select id, 'llarcas', 'Lucía', 'profe' from auth.users where email = 'llarcas@example.com'
on conflict (id) do update set usuario = excluded.usuario, nombre = excluded.nombre, rol = excluded.rol;

-- Comprobación: deben salir los dos
select p.usuario, p.nombre, p.rol, u.email, u.email_confirmed_at is not null as confirmado
from public.perfiles p join auth.users u on u.id = p.id;
