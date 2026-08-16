-- ============================================================
--  МАРШРУТ ПОСТРОЕН — хранилище файлов поездок
--  (билеты, брони, фото и видео внутри совместной поездки).
--
--  ЗАПУСК: Supabase → SQL Editor → New query → вставить весь файл → Run.
--  Требует, чтобы уже была выполнена схема supabase-trips.sql
--  (используется функция public.is_trip_member).
--  Безопасно запускать повторно.
-- ============================================================

-- Приватный бакет (доступ только участникам поездки), лимит файла 50 МБ.
insert into storage.buckets (id, name, public, file_size_limit)
values ('trip-files', 'trip-files', false, 52428800)
on conflict (id) do update set file_size_limit = excluded.file_size_limit;

-- В таблице вещей поездки — путь к загруженному файлу.
alter table public.trip_items add column if not exists file_path text;

-- Политики доступа к файлам. Путь файла = "<trip_id>/<имя>",
-- поэтому первый сегмент папки = id поездки, и проверяем участие в ней.

drop policy if exists "trip files read"   on storage.objects;
create policy "trip files read" on storage.objects for select
  using (
    bucket_id = 'trip-files'
    and public.is_trip_member( ((storage.foldername(name))[1])::uuid )
  );

drop policy if exists "trip files insert" on storage.objects;
create policy "trip files insert" on storage.objects for insert
  with check (
    bucket_id = 'trip-files'
    and public.is_trip_member( ((storage.foldername(name))[1])::uuid )
  );

drop policy if exists "trip files delete" on storage.objects;
create policy "trip files delete" on storage.objects for delete
  using (
    bucket_id = 'trip-files'
    and public.is_trip_member( ((storage.foldername(name))[1])::uuid )
  );

-- ============================================================
--  ГОТОВО. Теперь в поездке можно загружать билеты, фото и видео —
--  их видят только участники этой поездки.
-- ============================================================
