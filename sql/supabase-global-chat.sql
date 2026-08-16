-- ============================================================
--  МАРШРУТ ПОСТРОЕН — общий чат для всех пользователей
--  Читать могут все, писать — только вошедшие. Модерация: автор
--  удаляет своё, админ удаляет любое.
--  ЗАПУСК: Supabase → SQL Editor → вставить → Run. Безопасно повторно.
-- ============================================================

create table if not exists public.global_messages (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  name       text,
  text       text not null,
  created_at timestamptz not null default now()
);
create index if not exists idx_gm_created on public.global_messages(created_at);

alter table public.global_messages enable row level security;

-- Читать могут все (даже гости) — чат публичный.
drop policy if exists gm_select on public.global_messages;
create policy gm_select on public.global_messages for select using (true);

-- Писать — только вошедшие, от своего имени.
drop policy if exists gm_insert on public.global_messages;
create policy gm_insert on public.global_messages for insert
  with check (user_id = auth.uid());

-- Удалять — автор своё, либо АДМИН (владелец сайта) любое.
-- Замените email ниже на свой, если он другой.
drop policy if exists gm_delete on public.global_messages;
create policy gm_delete on public.global_messages for delete
  using (
    user_id = auth.uid()
    or lower(coalesce(auth.jwt()->>'email','')) = 'chuklajyegor@gmail.com'
  );

-- Realtime (живой чат)
do $$ begin
  alter publication supabase_realtime add table public.global_messages;
exception when duplicate_object then null; end $$;

-- ============================================================
--  ГОТОВО. Общий чат появится в левом нижнем углу сайта.
-- ============================================================
