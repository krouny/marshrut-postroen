-- ============================================================
--  МАРШРУТ ПОСТРОЕН — совместные поездки (архив/текущие/будущие),
--  участники, приглашения по ссылке, общие билеты/отели/экскурсии и чат.
--
--  КАК ВЫПОЛНИТЬ:
--  Supabase → SQL Editor → New query → вставить весь файл → Run.
--  Безопасно запускать повторно (используется IF NOT EXISTS / OR REPLACE).
-- ============================================================

-- ---------- ТАБЛИЦЫ ----------

-- Поездка. Статус (архив/текущая/будущая) НЕ храним — вычисляем из дат.
create table if not exists public.trips (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references auth.users(id) on delete cascade,
  title       text not null,
  city        text,
  country     text,
  start_date  date,
  end_date    date,
  cover       text,                       -- URL обложки (фото города)
  created_at  timestamptz not null default now()
);

-- Участники поездки (совместная поездка). Владелец добавляется автоматически.
create table if not exists public.trip_members (
  trip_id   uuid not null references public.trips(id) on delete cascade,
  user_id   uuid not null references auth.users(id) on delete cascade,
  role      text not null default 'member',  -- 'owner' | 'member'
  joined_at timestamptz not null default now(),
  primary key (trip_id, user_id)
);

-- Приглашения по ссылке (в т.ч. для ещё не зарегистрированных).
create table if not exists public.trip_invites (
  id         uuid primary key default gen_random_uuid(),
  trip_id    uuid not null references public.trips(id) on delete cascade,
  token      text not null unique,
  email      text,                        -- необязательно
  invited_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

-- Вещи поездки: билеты (авиа/жд), отели, экскурсии, заметки, позже фото/видео.
create table if not exists public.trip_items (
  id         uuid primary key default gen_random_uuid(),
  trip_id    uuid not null references public.trips(id) on delete cascade,
  type       text not null,               -- 'flight'|'train'|'hotel'|'excursion'|'note'|'photo'
  title      text,
  details    text,
  file_url   text,                        -- ссылка на загруженный файл (билет/фото)
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

-- Чат поездки.
create table if not exists public.trip_messages (
  id         uuid primary key default gen_random_uuid(),
  trip_id    uuid not null references public.trips(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  text       text not null,
  created_at timestamptz not null default now()
);

create index if not exists idx_members_user  on public.trip_members(user_id);
create index if not exists idx_items_trip     on public.trip_items(trip_id);
create index if not exists idx_messages_trip  on public.trip_messages(trip_id, created_at);

-- ---------- ХЕЛПЕРЫ (SECURITY DEFINER — чтобы RLS не зациклился) ----------

create or replace function public.is_trip_member(t uuid)
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (
    select 1 from public.trip_members m
    where m.trip_id = t and m.user_id = auth.uid()
  );
$$;

create or replace function public.is_trip_owner(t uuid)
returns boolean language sql security definer stable
set search_path = public as $$
  select exists (
    select 1 from public.trips tr
    where tr.id = t and tr.owner_id = auth.uid()
  );
$$;

-- Владелец автоматически становится участником своей поездки.
create or replace function public.add_owner_as_member()
returns trigger language plpgsql security definer
set search_path = public as $$
begin
  insert into public.trip_members(trip_id, user_id, role)
  values (new.id, new.owner_id, 'owner')
  on conflict (trip_id, user_id) do nothing;
  return new;
end; $$;

drop trigger if exists trg_add_owner on public.trips;
create trigger trg_add_owner
  after insert on public.trips
  for each row execute function public.add_owner_as_member();

-- Принять приглашение по токену (вызывается с сайта после входа).
create or replace function public.accept_invite(invite_token text)
returns uuid language plpgsql security definer
set search_path = public as $$
declare tid uuid;
begin
  select trip_id into tid from public.trip_invites where token = invite_token;
  if tid is null then
    raise exception 'Приглашение не найдено или устарело';
  end if;
  insert into public.trip_members(trip_id, user_id, role)
  values (tid, auth.uid(), 'member')
  on conflict (trip_id, user_id) do nothing;
  return tid;
end; $$;

-- ---------- RLS (защита данных) ----------

alter table public.trips         enable row level security;
alter table public.trip_members  enable row level security;
alter table public.trip_invites  enable row level security;
alter table public.trip_items    enable row level security;
alter table public.trip_messages enable row level security;

-- trips: видит участник; создаёт залогиненный; правит/удаляет владелец.
drop policy if exists trips_select on public.trips;
create policy trips_select on public.trips for select
  using (owner_id = auth.uid() or public.is_trip_member(id));

drop policy if exists trips_insert on public.trips;
create policy trips_insert on public.trips for insert
  with check (owner_id = auth.uid());

drop policy if exists trips_update on public.trips;
create policy trips_update on public.trips for update
  using (owner_id = auth.uid());

drop policy if exists trips_delete on public.trips;
create policy trips_delete on public.trips for delete
  using (owner_id = auth.uid());

-- trip_members: видят участники поездки. Вставка — только через функции
-- (триггер владельца и accept_invite, они SECURITY DEFINER). Удаление — сам себя или владелец.
drop policy if exists members_select on public.trip_members;
create policy members_select on public.trip_members for select
  using (public.is_trip_member(trip_id));

drop policy if exists members_delete on public.trip_members;
create policy members_delete on public.trip_members for delete
  using (user_id = auth.uid() or public.is_trip_owner(trip_id));

-- trip_invites: приглашения создаёт/видит/удаляет владелец поездки.
drop policy if exists invites_all on public.trip_invites;
create policy invites_all on public.trip_invites for all
  using (public.is_trip_owner(trip_id))
  with check (public.is_trip_owner(trip_id));

-- trip_items: полный доступ участникам поездки.
drop policy if exists items_select on public.trip_items;
create policy items_select on public.trip_items for select
  using (public.is_trip_member(trip_id));

drop policy if exists items_write on public.trip_items;
create policy items_write on public.trip_items for insert
  with check (public.is_trip_member(trip_id) and created_by = auth.uid());

drop policy if exists items_delete on public.trip_items;
create policy items_delete on public.trip_items for delete
  using (public.is_trip_member(trip_id));

-- trip_messages (чат): участники читают и пишут; правит нельзя, удаляет автор.
drop policy if exists messages_select on public.trip_messages;
create policy messages_select on public.trip_messages for select
  using (public.is_trip_member(trip_id));

drop policy if exists messages_insert on public.trip_messages;
create policy messages_insert on public.trip_messages for insert
  with check (public.is_trip_member(trip_id) and user_id = auth.uid());

drop policy if exists messages_delete on public.trip_messages;
create policy messages_delete on public.trip_messages for delete
  using (user_id = auth.uid());

-- ---------- REALTIME (живой чат) ----------
-- Включаем трансляцию изменений для чата (и участников — чтобы список обновлялся).
alter publication supabase_realtime add table public.trip_messages;
alter publication supabase_realtime add table public.trip_members;

-- ============================================================
--  ГОТОВО. Дальше в сайте: создание поездки, приглашение по ссылке,
--  общие билеты/отели, чат в реальном времени.
-- ============================================================
