-- =====================================================================
--  Irregular Verbs · esquema de base de datos (Supabase / PostgreSQL)
--  Ejecutar una sola vez en: Supabase > SQL Editor > New query > Run
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Sesiones: una fila por cada ronda de práctica
-- ---------------------------------------------------------------------
create table if not exists public.sesiones (
  id            uuid primary key,                       -- lo genera la app
  alumno        text not null check (char_length(alumno) between 1 and 40),
  dispositivo   uuid not null,                          -- id anónimo del móvil
  app           text not null default 'irregular-verbs' check (char_length(app) <= 40),
  modo          text not null check (modo in ('tarjetas','elige','escribe','frases','escucha')),
  grupo         text not null check (char_length(grupo) <= 60),
  total         int  not null check (total between 0 and 200),
  aciertos      int  not null check (aciertos between 0 and 200),
  duracion_seg  int  check (duracion_seg between 0 and 86400),
  completa      boolean not null default true,          -- false si salió a mitad de ronda
  creada_en     timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2. Respuestas: una fila por cada pregunta contestada
-- ---------------------------------------------------------------------
create table if not exists public.respuestas (
  id          bigint generated always as identity primary key,
  sesion_id   uuid not null references public.sesiones(id) on delete cascade,
  alumno      text not null check (char_length(alumno) between 1 and 40),
  verbo       text not null check (char_length(verbo) <= 30),
  forma       text not null check (forma in ('pasado','participio','pasado+participio','tres','tarjeta')),
  respuesta   text check (char_length(respuesta) <= 120),
  correcta    boolean not null,
  creada_en   timestamptz not null default now()
);

create index if not exists respuestas_sesion_idx on public.respuestas (sesion_id);
create index if not exists respuestas_alumno_verbo_idx on public.respuestas (alumno, verbo);
create index if not exists sesiones_alumno_fecha_idx on public.sesiones (alumno, creada_en desc);

-- ---------------------------------------------------------------------
-- 3. Seguridad: la app (rol anon) SOLO puede insertar. Nunca leer,
--    modificar ni borrar. Tú lo ves todo desde el panel de Supabase.
-- ---------------------------------------------------------------------
alter table public.sesiones   enable row level security;
alter table public.respuestas enable row level security;

revoke all on public.sesiones, public.respuestas from anon, authenticated;
grant insert on public.sesiones, public.respuestas to anon;

drop policy if exists "app inserta sesiones" on public.sesiones;
create policy "app inserta sesiones" on public.sesiones
  for insert to anon with check (true);

drop policy if exists "app inserta respuestas" on public.respuestas;
create policy "app inserta respuestas" on public.respuestas
  for insert to anon with check (true);

-- ---------------------------------------------------------------------
-- 4. Informes para ti (esquema aparte, NO expuesto a la app)
--    Consúltalos en SQL Editor:  select * from informes.resumen_diario;
-- ---------------------------------------------------------------------
create schema if not exists informes;
revoke all on schema informes from anon, authenticated;

create or replace view informes.resumen_diario as
select alumno,
       (creada_en at time zone 'Europe/Madrid')::date as dia,
       count(*)                                         as rondas,
       sum(total)                                       as preguntas,
       sum(aciertos)                                    as aciertos,
       round(100.0 * sum(aciertos) / nullif(sum(total),0)) as pct_acierto,
       round(sum(coalesce(duracion_seg,0)) / 60.0, 1)   as minutos
from public.sesiones
group by alumno, dia
order by dia desc, alumno;

create or replace view informes.verbos_mas_fallados as
select alumno, verbo,
       count(*)                                   as intentos,
       count(*) filter (where not correcta)       as fallos,
       round(100.0 * count(*) filter (where correcta) / count(*)) as pct_acierto,
       max(creada_en)                             as ultima_vez
from public.respuestas
group by alumno, verbo
having count(*) filter (where not correcta) > 0
order by fallos desc, pct_acierto asc;

create or replace view informes.ultimas_respuestas_mal as
select r.creada_en at time zone 'Europe/Madrid' as cuando,
       r.alumno, s.modo, r.verbo, r.forma, r.respuesta
from public.respuestas r
join public.sesiones s on s.id = r.sesion_id
where not r.correcta
order by r.creada_en desc
limit 200;

create or replace view informes.por_modo as
select alumno, modo,
       count(*) as rondas,
       round(100.0 * sum(aciertos) / nullif(sum(total),0)) as pct_acierto
from public.sesiones
group by alumno, modo
order by alumno, rondas desc;
