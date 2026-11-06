-- =====================================================================
--  Irregular Verbs · esquema de base de datos (Supabase / PostgreSQL)
--  Ejecutar en: Supabase > SQL Editor > New query > Run
--  Se puede ejecutar varias veces: crea lo que falta y actualiza lo que
--  ya existe (versión 3: inicio de sesión con Supabase Auth).
-- =====================================================================

-- Las vistas se recrean al final
drop schema if exists informes cascade;

-- ---------------------------------------------------------------------
-- 0. Perfiles: datos de cada usuario de Supabase Auth (alumno o profe)
--    Los usuarios se crean en Authentication > Users (ver usuarios.sql)
-- ---------------------------------------------------------------------
create table if not exists public.perfiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  usuario    text not null unique check (usuario ~ '^[a-z0-9._-]{2,30}$'),
  nombre     text not null check (char_length(nombre) between 1 and 40),
  rol        text not null default 'alumno' check (rol in ('alumno','profe')),
  creado_en  timestamptz not null default now()
);

-- ¿El usuario conectado es profe? (security definer para no entrar en bucle con RLS)
create or replace function public.es_profe() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfiles where id = auth.uid() and rol = 'profe');
$$;
revoke execute on function public.es_profe() from public, anon;
grant execute on function public.es_profe() to authenticated;

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
alter table public.sesiones add column if not exists user_id uuid default auth.uid() references auth.users(id) on delete set null;
alter table public.sesiones drop column if exists total;
alter table public.sesiones drop column if exists aciertos;
alter table public.sesiones drop column if exists duracion_seg;
alter table public.sesiones drop column if exists completa;

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
alter table public.respuestas add column if not exists user_id uuid default auth.uid() references auth.users(id) on delete set null;

create unique index if not exists respuestas_sesion_orden_uq on public.respuestas (sesion_id, orden);
create index if not exists respuestas_alumno_verbo_idx on public.respuestas (alumno, verbo);
create index if not exists sesiones_alumno_fecha_idx on public.sesiones (alumno, creada_en desc);

-- ---------------------------------------------------------------------
-- 3. Seguridad
--    · Sin iniciar sesión (anon): nada de nada.
--    · Alumno: inserta solo filas suyas y puede leer solo lo suyo.
--    · Profe: además puede leer todo.
-- ---------------------------------------------------------------------
alter table public.perfiles   enable row level security;
alter table public.sesiones   enable row level security;
alter table public.respuestas enable row level security;

revoke all on public.perfiles, public.sesiones, public.respuestas from anon, authenticated;
grant select on public.perfiles to authenticated;
grant select, insert on public.sesiones, public.respuestas to authenticated;

drop policy if exists "app inserta sesiones"   on public.sesiones;
drop policy if exists "app inserta respuestas" on public.respuestas;

drop policy if exists "ver perfiles" on public.perfiles;
create policy "ver perfiles" on public.perfiles
  for select to authenticated using (id = auth.uid() or public.es_profe());

drop policy if exists "insertar mis sesiones" on public.sesiones;
create policy "insertar mis sesiones" on public.sesiones
  for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "ver sesiones" on public.sesiones;
create policy "ver sesiones" on public.sesiones
  for select to authenticated using (user_id = auth.uid() or public.es_profe());

drop policy if exists "insertar mis respuestas" on public.respuestas;
create policy "insertar mis respuestas" on public.respuestas
  for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "ver respuestas" on public.respuestas;
create policy "ver respuestas" on public.respuestas
  for select to authenticated using (user_id = auth.uid() or public.es_profe());

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
       s.modo, s.grupo,
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
