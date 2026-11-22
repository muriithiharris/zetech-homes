-- =====================================================================
-- ZETECH HOMES  |  Step 5 of 6  |  OPTIONAL demo data (30 Kenyan listings)
-- Needs at least one staff account (see the setup guide). Skips itself if
-- listings already exist. Everything goes through the real triggers, so the
-- audit trail, versions and reservations look exactly like real use.
-- Delete the demo rows before your final presentation if you prefer.
-- =====================================================================
do $$
declare
  v_agents uuid[];
  v_ids bigint[] := '{}';
  v_roads text[] := array['Rhapta Road', 'Waiyaki Way', 'Mandera Road', 'Karen Road', 'Thika Road',
                          'Links Road', 'Kimbo Road', 'Milimani Road', 'Athi River Road', 'Kitengela Road'];
  v_adj text[]   := array['Executive', 'Modern', 'Spacious', 'Elegant', 'Cosy'];
  v_feat text[]  := array['an open-plan kitchen', 'all-ensuite bedrooms', 'borehole water', 'a backup generator',
                          'fibre internet', 'a gated compound', '24-hour security', 'ample parking',
                          'a swimming pool', 'fitted wardrobes', 'a rooftop terrace', 'solar water heating'];
  v_names text[] := array['Wanjiku Kamau', 'Otieno Odhiambo', 'Amina Hassan', 'Brian Mutua', 'Grace Njeri',
                          'Peter Kiprop', 'Faith Achieng', 'Daniel Mwangi'];
  v_vis_names text[] := array['Esther Wambui', 'Kevin Otieno', 'Mercy Chebet', 'Samuel Kariuki',
                              'Zainab Ali', 'John Karanja', 'Lilian Moraa', 'Hassan Noor'];
  i int; v_sub record; v_type record; v_agent uuid; v_beds int; v_baths int; v_base numeric;
  v_price numeric; v_id bigint; v_client bigint; v_status text;
begin
  if exists (select 1 from public.properties) then
    raise notice 'Listings already exist: demo data skipped.';
    return;
  end if;
  select array_agg(id order by staff_no) into v_agents from public.staff where is_active;
  if v_agents is null then
    raise exception 'Create at least one staff account first (Authentication > Users), then run this file again.';
  end if;
  if (select count(*) from public.sub_counties) = 0 then
    raise exception 'Run 04_lookup_data.sql first.';
  end if;

  perform setseed(0.2026);

  for i in 1..30 loop
    select * into v_sub  from public.sub_counties  order by random() limit 1;
    select * into v_type from public.property_types order by random() limit 1;
    v_agent := v_agents[1 + (i % array_length(v_agents, 1))];
    v_beds  := case when v_type.name = 'Studio' then 0 else 1 + floor(random() * 5)::int end;
    if v_type.name = 'Villa' then v_beds := greatest(v_beds, 3); end if;
    v_baths := greatest(1, v_beds - floor(random() * 2)::int);
    v_base  := case v_type.name when 'Studio' then 2400000 when 'Apartment' then 6000000
                 when 'Townhouse' then 14000000 when 'Maisonette' then 16000000
                 when 'Bungalow' then 18000000 else 32000000 end;
    v_price := round(v_base * (0.75 + random() * 1.15) / 50000) * 50000;

    insert into public.properties
      (lr_number, title, property_type_id, price, county_id, sub_county_id, location, description,
       bedrooms, bathrooms, agent_id, updated_by, updated_ip)
    values (
      'LR/2026/' || lpad((100 + i * 7)::text, 5, '0'),
      v_adj[1 + floor(random() * 5)::int] || ' ' ||
        case when v_type.name = 'Studio' then 'Studio' else v_beds || '-Bed ' || v_type.name end || ' in ' || v_sub.name,
      v_type.id, v_price, v_sub.county_id, v_sub.id,
      v_roads[1 + floor(random() * 10)::int] || ', Plot ' || (2 + floor(random() * 88))::int ||
        (array['A', 'B', 'C', 'D'])[1 + floor(random() * 4)::int],
      format('Well-finished %s with %s, %s and %s. Close to schools, shops and public transport.',
             lower(v_type.name), v_feat[1 + floor(random() * 12)::int],
             v_feat[1 + floor(random() * 12)::int], v_feat[1 + floor(random() * 12)::int]),
      v_beds, v_baths, v_agent, v_agent, '127.0.0.1')
    returning id into v_id;
    v_ids := v_ids || v_id;
  end loop;

  -- first 12 listings get reserved; 5 of those are sold; one reservation is cancelled
  for i in 1..12 loop
    v_id := v_ids[i];
    update public.properties
       set status = 'RESERVED', version = version + 1, updated_by = agent_id, updated_at = now()
     where id = v_id;
    insert into public.clients (full_name, phone_enc, id_number_enc)
    values (v_names[1 + (i % 8)],
            private.pii_encrypt('07' || lpad((12000000 + i * 3571093 % 79999999)::text, 8, '0')),
            private.pii_encrypt((30000000 + i * 91357)::text))
    returning id into v_client;
    insert into public.reservations (property_id, client_id, fee, created_by)
    select v_id, v_client, (array[100000, 250000, 500000])[1 + (i % 3)], agent_id from public.properties where id = v_id;

    if i <= 5 then
      update public.properties set status = 'SOLD', version = version + 1, updated_by = agent_id, updated_at = now() where id = v_id;
      update public.reservations set status = 'COMPLETED', closed_at = now() where property_id = v_id and status = 'ACTIVE';
    elsif i = 12 then
      update public.properties set status = 'AVAILABLE', version = version + 1, updated_by = agent_id, updated_at = now() where id = v_id;
      update public.reservations set status = 'CANCELLED', closed_at = now() where property_id = v_id and status = 'ACTIVE';
    end if;
  end loop;

  -- a price drop, so it shows up in the audit trail
  update public.properties set price = price - 500000, version = version + 1, updated_by = agent_id, updated_at = now()
   where id = v_ids[21];

  -- customer viewing requests on open listings
  for i in 1..8 loop
    select id, status into v_id, v_status from public.properties
     where status in ('AVAILABLE', 'RESERVED') order by id offset (i * 2) limit 1;
    exit when v_id is null;
    insert into public.viewing_requests (property_id, kind, name, phone, preferred_date, message)
    values (v_id, case when v_status = 'AVAILABLE' then 'VISIT' else 'WAITLIST' end,
            v_vis_names[i], '07' || lpad((11000000 + i * 4129031)::text, 8, '0'),
            case when v_status = 'AVAILABLE' then (now() at time zone 'Africa/Nairobi')::date + (i + 1) end,
            'I would like to see the property this week.');
  end loop;

  raise notice 'Demo data created: 30 listings, 12 reservations, 5 sales, 8 viewing requests.';
end $$;
