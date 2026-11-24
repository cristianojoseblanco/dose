-- SUPORTE · migração 004: PDFs das bulas (armazenamento privado da casa)
insert into storage.buckets (id, name, public)
values ('bulas', 'bulas', false)
on conflict (id) do nothing;

drop policy if exists "bulas: ler" on storage.objects;
drop policy if exists "bulas: enviar" on storage.objects;
drop policy if exists "bulas: trocar" on storage.objects;
drop policy if exists "bulas: apagar" on storage.objects;

create policy "bulas: ler" on storage.objects for select
  using (bucket_id = 'bulas' and public.is_member(((storage.foldername(name))[1])::uuid));
create policy "bulas: enviar" on storage.objects for insert
  with check (bucket_id = 'bulas' and public.is_member(((storage.foldername(name))[1])::uuid));
create policy "bulas: trocar" on storage.objects for update
  using (bucket_id = 'bulas' and public.is_member(((storage.foldername(name))[1])::uuid));
create policy "bulas: apagar" on storage.objects for delete
  using (bucket_id = 'bulas' and public.is_member(((storage.foldername(name))[1])::uuid));
