-- =====================================================================
-- ZETECH HOMES  |  Step 6 of 6  |  Photo storage (Supabase Storage)
-- Creates a public bucket for listing photos. Customers can VIEW photos;
-- only active staff can upload; only managers can delete.
-- =====================================================================

insert into storage.buckets (id, name, public)
values ('property-images', 'property-images', true)
on conflict (id) do nothing;

drop policy if exists "property images are public" on storage.objects;
create policy "property images are public" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'property-images');

drop policy if exists "staff can upload property images" on storage.objects;
create policy "staff can upload property images" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'property-images' and public.is_staff());

drop policy if exists "managers can delete property images" on storage.objects;
create policy "managers can delete property images" on storage.objects
  for delete to authenticated
  using (bucket_id = 'property-images' and public.is_manager());
