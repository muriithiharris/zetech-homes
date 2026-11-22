-- =====================================================================
-- ZETECH HOMES  |  Step 4 of 6  |  Counties, sub-counties, property types
-- Safe to run more than once.
-- =====================================================================

insert into public.counties (name) values
  ('Nairobi'), ('Kiambu'), ('Mombasa'), ('Nakuru'), ('Kisumu'), ('Machakos'), ('Kajiado'),
  ('Uasin Gishu'), ('Nyeri'), ('Kilifi')
on conflict (name) do nothing;

insert into public.sub_counties (county_id, name)
select c.id, s.name
from (values
  ('Nairobi', 'Westlands'), ('Nairobi', 'Dagoretti North'), ('Nairobi', 'Kasarani'),
  ('Nairobi', 'Langata'), ('Nairobi', 'Embakasi East'), ('Nairobi', 'Roysambu'),
  ('Kiambu', 'Kikuyu'), ('Kiambu', 'Ruiru'), ('Kiambu', 'Juja'), ('Kiambu', 'Limuru'),
  ('Mombasa', 'Nyali'), ('Mombasa', 'Kisauni'), ('Mombasa', 'Likoni'),
  ('Nakuru', 'Nakuru Town East'), ('Nakuru', 'Naivasha'),
  ('Kisumu', 'Kisumu Central'), ('Kisumu', 'Kisumu East'),
  ('Machakos', 'Mavoko'), ('Machakos', 'Machakos Town'),
  ('Kajiado', 'Kajiado North'), ('Kajiado', 'Kajiado Central'),
  ('Uasin Gishu', 'Kapseret'), ('Uasin Gishu', 'Turbo'),
  ('Nyeri', 'Nyeri Central'), ('Kilifi', 'Malindi')
) as s (county, name)
join public.counties c on c.name = s.county
on conflict (county_id, name) do nothing;

insert into public.property_types (name) values
  ('Apartment'), ('Maisonette'), ('Villa'), ('Bungalow'), ('Townhouse'), ('Studio')
on conflict (name) do nothing;
