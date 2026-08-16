-- ============================================================
--  Маршрут Построен — схема базы данных для Supabase
--  Как применить: Supabase → SQL Editor → New query →
--  вставить ВЕСЬ этот текст → Run. Один раз.
-- ============================================================

-- 1. Профили пользователей (дополняет встроенную авторизацию Supabase)
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text,
  email      text,
  tier       text default 'free',        -- free | traveler | premium
  tier_since date,
  searches   int  default 0,
  created_at timestamptz default now()
);

-- 2. Сохранённые маршруты пользователей
create table if not exists public.routes (
  id         bigint generated always as identity primary key,
  user_id    uuid references auth.users(id) on delete cascade,
  city       text not null,
  category   text,
  created_at timestamptz default now()
);

-- 3. Автоматически создавать профиль при регистрации нового пользователя
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email);
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 4. Безопасность (Row Level Security) — включаем защиту строк
alter table public.profiles enable row level security;
alter table public.routes   enable row level security;

-- Профиль: читать может любой (нужно для рейтинга), менять — только свой
drop policy if exists "profiles_read"       on public.profiles;
drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_read"       on public.profiles for select using (true);
create policy "profiles_update_own" on public.profiles for update using (auth.uid() = id);

-- Маршруты: пользователь видит / добавляет / удаляет только свои
drop policy if exists "routes_own" on public.routes;
create policy "routes_own" on public.routes for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- 5. Рейтинг: готовое представление (очки = поиски*2 + маршруты*5)
create or replace view public.leaderboard as
select
  p.id,
  coalesce(p.name, split_part(p.email,'@',1)) as name,
  p.searches,
  count(r.id)                    as routes,
  p.searches*2 + count(r.id)*5   as points,
  p.tier
from public.profiles p
left join public.routes r on r.user_id = p.id
group by p.id
order by points desc;

-- Готово. В разделе Table Editor появятся таблицы profiles и routes.
-- Там же ты всегда видишь, кто оплатил: колонка tier (free / traveler / premium).
