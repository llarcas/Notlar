-- =====================================================================
--  Irregular Verbs · esquema de base de datos (Supabase / PostgreSQL)
--  Ejecutar en: Supabase > SQL Editor > New query > Run
--  Se puede ejecutar varias veces: crea lo que falta y actualiza lo que
--  ya existe (versión 5: módulo Writing con ejercicios y redacciones).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- Las vistas se recrean al final
drop schema if exists informes cascade;

-- Limpieza de la versión con Supabase Auth (si se llegó a ejecutar)
drop policy if exists "insertar mis sesiones"   on public.sesiones;
drop policy if exists "ver sesiones"            on public.sesiones;
drop policy if exists "insertar mis respuestas" on public.respuestas;
drop policy if exists "ver respuestas"          on public.respuestas;
drop table    if exists public.perfiles cascade;
drop function if exists public.es_profe();

-- ---------------------------------------------------------------------
-- 0. Usuarios de la app (control ligero, no es autenticación fuerte)
-- ---------------------------------------------------------------------
create table if not exists public.usuarios (
  usuario        text primary key check (usuario ~ '^[a-z0-9._-]{2,30}$'),
  nombre         text not null check (char_length(nombre) between 1 and 40),
  rol            text not null default 'alumno' check (rol in ('alumno','profe')),
  password_hash  text not null,
  activo         boolean not null default true,
  creado_en      timestamptz not null default now()
);
alter table public.usuarios enable row level security;     -- sin políticas: nadie la lee desde la app
revoke all on public.usuarios from anon, authenticated;

-- Alta o cambio de contraseña:  select public.crear_usuario('ana', 'Ana', 'alumno', 'clave');
create or replace function public.crear_usuario(p_usuario text, p_nombre text, p_rol text, p_password text)
returns void language sql security definer set search_path = public, extensions as $$
  insert into public.usuarios (usuario, nombre, rol, password_hash)
  values (lower(p_usuario), p_nombre, p_rol, crypt(p_password, gen_salt('bf')))
  on conflict (usuario) do update
     set nombre = excluded.nombre, rol = excluded.rol, password_hash = excluded.password_hash, activo = true;
$$;
revoke execute on function public.crear_usuario(text,text,text,text) from public, anon, authenticated;

-- La app llama a esto para entrar: devuelve el usuario si la contraseña es correcta, o nada
create or replace function public.entrar(p_usuario text, p_password text)
returns table (usuario text, nombre text, rol text)
language sql security definer set search_path = public, extensions as $$
  select u.usuario, u.nombre, u.rol
  from public.usuarios u
  where u.usuario = lower(trim(p_usuario))
    and u.activo
    and u.password_hash = crypt(p_password, u.password_hash);
$$;
revoke execute on function public.entrar(text,text) from public;
grant execute on function public.entrar(text,text) to anon;

-- Usuarios iniciales
select public.crear_usuario('jonas',   'Jonas', 'alumno', 'jonas');
select public.crear_usuario('llarcas', 'Lucía', 'profe',  'admin');

-- ---------------------------------------------------------------------
-- 1. Sesiones: una fila por ronda, se crea al contestar la primera
--    pregunta. Lo que pasó dentro de la ronda está en "respuestas".
-- ---------------------------------------------------------------------
create table if not exists public.sesiones (
  id              uuid primary key,                     -- lo genera la app
  alumno          text not null check (char_length(alumno) between 1 and 40),
  dispositivo     uuid not null,                        -- id anónimo del móvil
  app             text not null default 'irregular-verbs' check (char_length(app) <= 40),
  modo            text not null check (modo in ('tarjetas','elige','escribe','frases','escucha')),
  grupo           text not null check (char_length(grupo) <= 60),
  total_previsto  int  check (total_previsto between 0 and 200),
  iniciada_en     timestamptz,                          -- hora del móvil
  creada_en       timestamptz not null default now()    -- hora de llegada
);
alter table public.sesiones add column if not exists total_previsto int check (total_previsto between 0 and 200);
alter table public.sesiones add column if not exists iniciada_en timestamptz;
alter table public.sesiones drop column if exists total;
alter table public.sesiones drop column if exists aciertos;
alter table public.sesiones drop column if exists duracion_seg;
alter table public.sesiones drop column if exists completa;
alter table public.sesiones drop column if exists user_id;
alter table public.sesiones drop constraint if exists sesiones_modo_check;
alter table public.sesiones add constraint sesiones_modo_check check (modo in
  ('tarjetas','elige','escribe','frases','escucha','w-ordena','w-error','w-transforma','w-conecta'));

-- ---------------------------------------------------------------------
-- 2. Respuestas: una fila por pregunta, se envía al contestarla
-- ---------------------------------------------------------------------
create table if not exists public.respuestas (
  id             bigint generated always as identity primary key,
  sesion_id      uuid not null references public.sesiones(id) on delete cascade,
  alumno         text not null check (char_length(alumno) between 1 and 40),
  orden          int  check (orden between 1 and 500),  -- nº de pregunta en la ronda
  verbo          text not null check (char_length(verbo) <= 30),
  forma          text not null check (forma in ('pasado','participio','pasado+participio','tres','tarjeta')),
  respuesta      text check (char_length(respuesta) <= 120),
  correcta       boolean not null,
  respondida_en  timestamptz,                           -- hora del móvil
  creada_en      timestamptz not null default now()
);
alter table public.respuestas add column if not exists orden int check (orden between 1 and 500);
alter table public.respuestas add column if not exists respondida_en timestamptz;
alter table public.respuestas drop column if exists user_id;
alter table public.respuestas drop constraint if exists respuestas_forma_check;
alter table public.respuestas add constraint respuestas_forma_check check (forma in
  ('pasado','participio','pasado+participio','tres','tarjeta','frase'));
comment on column public.respuestas.verbo is 'Verbo, o id del ejercicio en Writing (p. ej. error-3)';

-- ---------------------------------------------------------------------
-- 2b. Redacciones del módulo Writing
-- ---------------------------------------------------------------------
create table if not exists public.redacciones (
  id           uuid primary key,                        -- lo genera la app
  alumno       text not null check (char_length(alumno) between 1 and 40),
  dispositivo  uuid,
  tarea        text not null check (char_length(tarea) <= 80),
  texto        text not null check (char_length(texto) <= 4000),
  palabras     int  check (palabras between 0 and 2000),
  conectores   int  check (conectores between 0 and 100),
  pistas       int  check (pistas between 0 and 100),     -- avisos automáticos que quedaban al terminar
  minutos      numeric(6,1) check (minutos between 0 and 1440),
  escrita_en   timestamptz,                              -- hora del móvil
  creada_en    timestamptz not null default now()
);

create unique index if not exists respuestas_sesion_orden_uq on public.respuestas (sesion_id, orden);
create index if not exists respuestas_alumno_verbo_idx on public.respuestas (alumno, verbo);
create index if not exists sesiones_alumno_fecha_idx on public.sesiones (alumno, creada_en desc);

-- ---------------------------------------------------------------------
-- 3. Seguridad: la app (rol anon) SOLO puede insertar en sesiones y
--    respuestas, y llamar a entrar(). Nada más.
-- ---------------------------------------------------------------------
alter table public.sesiones    enable row level security;
alter table public.respuestas  enable row level security;
alter table public.redacciones enable row level security;

revoke all on public.sesiones, public.respuestas, public.redacciones from anon, authenticated;
grant insert on public.sesiones, public.respuestas, public.redacciones to anon;

drop policy if exists "app inserta redacciones" on public.redacciones;
create policy "app inserta redacciones" on public.redacciones
  for insert to anon with check (true);

drop policy if exists "app inserta sesiones" on public.sesiones;
create policy "app inserta sesiones" on public.sesiones
  for insert to anon with check (true);

drop policy if exists "app inserta respuestas" on public.respuestas;
create policy "app inserta respuestas" on public.respuestas
  for insert to anon with check (true);

-- ---------------------------------------------------------------------
-- 4. Informes para ti (esquema aparte, NO expuesto a la app)
-- ---------------------------------------------------------------------
create schema informes;
revoke all on schema informes from anon, authenticated;

-- Cada ronda con sus números, terminada o no
create view informes.rondas as
select s.id,
       s.alumno,
       (coalesce(s.iniciada_en, s.creada_en) at time zone 'Europe/Madrid') as inicio,
       s.app, s.modo, s.grupo,
       s.total_previsto,
       count(r.id)                                  as contestadas,
       count(r.id) filter (where r.correcta)        as aciertos,
       round(100.0 * count(r.id) filter (where r.correcta) / nullif(count(r.id),0)) as pct_acierto,
       (count(r.id) >= coalesce(s.total_previsto, 0)) as terminada,
       round(extract(epoch from max(coalesce(r.respondida_en, r.creada_en))
                                - coalesce(s.iniciada_en, s.creada_en)) / 60.0, 1) as minutos
from public.sesiones s
left join public.respuestas r on r.sesion_id = s.id
group by s.id
order by inicio desc;

create view informes.resumen_diario as
select alumno,
       inicio::date                                  as dia,
       count(*)                                      as rondas,
       count(*) filter (where terminada)             as terminadas,
       count(*) filter (where not terminada)         as a_medias,
       sum(contestadas)                              as preguntas,
       sum(aciertos)                                 as aciertos,
       round(100.0 * sum(aciertos) / nullif(sum(contestadas),0)) as pct_acierto,
       sum(coalesce(minutos,0))                      as minutos
from informes.rondas
group by alumno, dia
order by dia desc, alumno;

create view informes.verbos_mas_fallados as
select alumno, verbo,
       count(*)                                   as intentos,
       count(*) filter (where not correcta)       as fallos,
       round(100.0 * count(*) filter (where correcta) / count(*)) as pct_acierto,
       max(coalesce(respondida_en, creada_en)) at time zone 'Europe/Madrid' as ultima_vez
from public.respuestas
group by alumno, verbo
having count(*) filter (where not correcta) > 0
order by fallos desc, pct_acierto asc;

create view informes.ultimas_respuestas_mal as
select coalesce(r.respondida_en, r.creada_en) at time zone 'Europe/Madrid' as cuando,
       r.alumno, s.modo, r.verbo, r.forma, r.respuesta
from public.respuestas r
join public.sesiones s on s.id = r.sesion_id
where not r.correcta
order by cuando desc
limit 200;

create view informes.por_modo as
select alumno, modo,
       count(*)                                        as rondas,
       count(*) filter (where not terminada)           as a_medias,
       round(100.0 * sum(aciertos) / nullif(sum(contestadas),0)) as pct_acierto
from informes.rondas
group by alumno, modo
order by alumno, rondas desc;

-- Redacciones, de la más reciente a la más antigua
create view informes.redacciones as
select coalesce(escrita_en, creada_en) at time zone 'Europe/Madrid' as cuando,
       alumno, tarea, palabras, conectores, pistas, minutos, texto
from public.redacciones
order by cuando desc;

-- Ejercicios de Writing: aciertos por tipo
create view informes.writing_por_tipo as
select alumno, modo, grupo as ejercicio,
       count(*) as rondas,
       sum(contestadas) as frases,
       round(100.0 * sum(aciertos) / nullif(sum(contestadas),0)) as pct_acierto
from informes.rondas
where app = 'writing'
group by alumno, modo, grupo
order by alumno, rondas desc;
