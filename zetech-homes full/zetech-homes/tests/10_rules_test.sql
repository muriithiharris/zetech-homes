-- Rule tests. Run with: psql -v ON_ERROR_STOP=1 -f tests/10_rules_test.sql
-- Every check prints PASS or aborts the script with FAIL.
create schema if not exists test;
grant usage on schema test to public;

create or replace function test.ok(cond boolean, msg text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', msg; end if;
  raise notice 'PASS: %', msg;
end $$;

create or replace function test.login(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.headers', '{"x-forwarded-for":"41.80.1.9, 10.0.0.1"}', true);
  execute 'set local role authenticated';
end $$;

create or replace function test.anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';
end $$;

-- expects the statement to fail with the given SQLSTATE
create or replace function test.fails(stmt text, expected_state text, msg text) returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    if sqlstate = expected_state then
      raise notice 'PASS: % (%)', msg, sqlerrm; return;
    end if;
    raise exception 'FAIL: % - expected SQLSTATE % but got % (%)', msg, expected_state, sqlstate, sqlerrm;
  end;
  raise exception 'FAIL: % - statement succeeded but should have failed', msg;
end $$;

create or replace function test.prop(p_lr text) returns jsonb language sql as $$
  select jsonb_build_object('lr_number', p_lr, 'title', 'Executive 3-Bed Villa in Kileleshwa',
    'property_type_id', (select id from public.property_types where name = 'Villa'),
    'price', 24500000, 'county_id', (select id from public.counties where name = 'Nairobi'),
    'sub_county_id', (select id from public.sub_counties where name = 'Westlands'),
    'location', 'Mandera Road, Plot 14B', 'description', 'Spacious with open kitchen',
    'bedrooms', 3, 'bathrooms', 3)
$$;

-- ------------------------------------------------------------ setup
insert into auth.users (id, email, raw_user_meta_data) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'mary@zetech.test',  '{"full_name":"Mary Wairimu"}'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'brian@zetech.test', '{"full_name":"Brian Ochieng"}'),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'lucy@zetech.test',  '{"full_name":"Lucy Mwende"}');
update public.staff set role = 'MANAGER' where id = 'aaaaaaaa-0000-0000-0000-000000000001';

do $$ begin
  perform test.ok((select count(*) from public.staff) = 3, 'signing up an auth user creates a staff profile');
  perform test.ok((select role from public.staff where email = 'brian@zetech.test') = 'AGENT', 'new accounts are agents by default');
end $$;

-- ------------------------------------------------------------ 1. duplicates
do $$
declare r jsonb; mgr uuid := 'aaaaaaaa-0000-0000-0000-000000000001'; ag1 uuid := 'aaaaaaaa-0000-0000-0000-000000000002';
begin
  perform test.login(ag1);
  r := public.rpc_create_property(test.prop('LR/2026/00148'));
  perform test.ok((r ->> 'ok')::boolean, 'agent creates a listing');

  r := public.rpc_create_property(test.prop(' lr/2026/00148 '));
  perform test.ok(r ->> 'code' = 'duplicate', 'duplicate LR (even with sloppy typing) is blocked');
  r := public.rpc_create_property(test.prop('LR/2026/00148'));
  r := public.rpc_create_property(test.prop('LR/2026/00148'));
  r := public.rpc_create_property(test.prop('bad-lr'));
  perform test.ok(r ->> 'code' = 'invalid_lr', 'badly formatted LR is rejected');

  reset role;
  perform test.ok((select count(*) from public.audit_log where action = 'DUPLICATE_BLOCKED') = 3,
                  'blocked duplicates are written to the audit log (not rolled back)');
  perform test.ok((select count(*) from public.notifications where user_id = mgr and message like '%duplicate%') = 1,
                  'managers are alerted after 3 duplicate attempts');
  perform test.ok((select action || '/' || user_id::text from public.audit_log where action = 'INSERT_ENTRY')
                  = 'INSERT_ENTRY/' || ag1::text, 'trigger recorded the INSERT_ENTRY with the right user');
  perform test.ok((select host(ip_address) from public.audit_log where action = 'INSERT_ENTRY') = '41.80.1.9',
                  'caller IP address is captured from the request header');
end $$;

-- ------------------------------------------------------------ 2. version conflict
do $$
declare r jsonb; mgr uuid := 'aaaaaaaa-0000-0000-0000-000000000001'; ag1 uuid := 'aaaaaaaa-0000-0000-0000-000000000002';
        v_id bigint; v_ver int;
begin
  select id, version into v_id, v_ver from public.properties where lr_number = 'LR/2026/00148';
  perform test.login(ag1);
  r := public.rpc_update_property(v_id, v_ver, '{"price": 23000000}');
  perform test.ok((r ->> 'ok')::boolean and (r ->> 'version')::int = v_ver + 1, 'agent edit succeeds and bumps the version');

  perform test.login('aaaaaaaa-0000-0000-0000-000000000001');       -- manager, still holding the OLD version
  r := public.rpc_update_property(v_id, v_ver, '{"price": 1000}');
  perform test.ok(r ->> 'code' = 'conflict', 'stale edit is rejected as a conflict');

  reset role;
  perform test.ok((select price from public.properties where id = v_id) = 23000000, 'stale write did NOT overwrite the price');
  perform test.ok((select count(*) from public.audit_log where action = 'MVCC_CONFLICT') = 1, 'conflict is recorded in the audit log');
  perform test.ok((select count(*) from public.notifications where user_id = ag1 and message like '%conflict%') = 1,
                  'listing agent is notified of the conflict');
  perform test.ok((select count(*) from public.audit_log where action = 'PRICE_EDIT' and old_value = '24500000.00' and new_value = '23000000.00') = 1,
                  'trigger recorded the price change old -> new');
end $$;

-- ------------------------------------------------------------ 3. status workflow + encryption
do $$
declare r jsonb; v_id bigint; v_ver int; ag1 uuid := 'aaaaaaaa-0000-0000-0000-000000000002';
        ag2 uuid := 'aaaaaaaa-0000-0000-0000-000000000003';
        client jsonb := '{"name":"Wanjiku Kamau","phone":"0712345678","id_number":"12345678"}';
begin
  select id, version into v_id, v_ver from public.properties where lr_number = 'LR/2026/00148';

  perform test.login(ag2);
  r := public.rpc_change_status(v_id, v_ver, 'RESERVED', client, 500000);
  perform test.ok(r ->> 'code' = 'forbidden', 'an agent cannot change another agent''s listing');

  perform test.login(ag1);
  r := public.rpc_change_status(v_id, v_ver, 'SOLD');
  perform test.ok(r ->> 'code' = 'illegal_transition', 'Available -> Sold is refused');
  r := public.rpc_change_status(v_id, v_ver, 'RESERVED', '{"name":"X"}', 1);
  perform test.ok(r ->> 'code' = 'invalid', 'reserving without full client details is refused');
  r := public.rpc_change_status(v_id, v_ver, 'RESERVED', client, 500000);
  perform test.ok((r ->> 'ok')::boolean, 'agent reserves the property');
  v_ver := (r ->> 'version')::int;

  r := public.rpc_reservation_details(v_id);
  perform test.ok(r -> 'reservation' ->> 'client_phone' = '0712345678', 'authorised staff see the decrypted client phone');

  reset role;
  perform test.ok((select position('0712345678' in encode(phone_enc, 'escape')) from public.clients limit 1) = 0,
                  'client phone is stored encrypted at rest');
  perform test.ok((select count(*) from public.reservations where property_id = v_id and status = 'ACTIVE') = 1, 'one active reservation');

  perform test.login(ag1);
  r := public.rpc_archive_property(v_id, v_ver);
  perform test.ok(r ->> 'code' = 'illegal_transition', 'a reserved listing cannot be archived');
  r := public.rpc_change_status(v_id, v_ver, 'SOLD');
  perform test.ok((r ->> 'ok')::boolean, 'Reserved -> Sold');
  v_ver := (r ->> 'version')::int;
  r := public.rpc_change_status(v_id, v_ver, 'AVAILABLE');
  perform test.ok(r ->> 'code' = 'illegal_transition', 'Sold is final (function)');

  reset role;
  perform test.ok((select status from public.reservations where property_id = v_id) = 'COMPLETED', 'sale completes the reservation');
  perform test.fails(format('update public.properties set status = %L, version = version + 1 where id = %s', 'AVAILABLE', v_id),
                     'ZH422', 'Sold is final (database trigger, raw SQL)');
  perform test.ok((select count(*) from public.audit_log where action = 'STATUS_UPDATE') = 2, 'both status changes were audited by trigger');
end $$;

-- ------------------------------------------------------------ 4. the database refuses bad data on its own
do $$
declare v_id bigint; v_ver int; ag1 uuid := 'aaaaaaaa-0000-0000-0000-000000000002';
begin
  select id, version into v_id, v_ver from public.properties where lr_number = 'LR/2026/00148';
  perform test.fails(format('update public.properties set price = 5, version = %s where id = %s', v_ver + 5, v_id),
                     'ZH409', 'raw UPDATE with a wrong version is rejected by the trigger');
  perform test.fails(format('update public.properties set lr_number = %L, version = version + 1 where id = %s', 'LR/2026/99999', v_id),
                     'ZH403', 'LR number cannot be changed');
  perform test.fails(format('delete from public.properties where id = %s', v_id),
                     'ZH403', 'properties cannot be hard-deleted');
  perform test.fails('update public.audit_log set new_value = ''tampered''', 'ZH403', 'audit log rows cannot be updated');
  perform test.fails('delete from public.audit_log', 'ZH403', 'audit log rows cannot be deleted');
  perform test.fails('truncate public.audit_log', 'ZH403', 'audit log cannot be truncated');
  perform test.fails(format($f$insert into public.properties (lr_number,title,property_type_id,price,county_id,sub_county_id,location,description,agent_id)
      values ('LR/2026/00148','Duplicate title',1,100,1,1,'x loc','some text','%s')$f$, ag1),
      '23505', 'UNIQUE constraint blocks a duplicate LR number even for raw SQL');
  perform test.fails(format($f$insert into public.properties (lr_number,title,property_type_id,price,county_id,sub_county_id,location,description,agent_id)
      values ('LR/2026/00300','Mismatched county',1,100,(select id from public.counties where name='Kiambu'),
              (select id from public.sub_counties where name='Westlands'),'x loc','some text','%s')$f$, ag1),
      '23503', 'a sub-county must belong to the chosen county');
  perform test.fails(format($f$insert into public.properties (lr_number,title,property_type_id,price,county_id,sub_county_id,location,description,agent_id)
      values ('LR/2026/00301','Free house',1,0,1,1,'x loc','some text','%s')$f$, ag1),
      '23514', 'price must be greater than zero');
  perform test.fails(format($f$insert into public.properties (lr_number,title,property_type_id,price,county_id,sub_county_id,location,description,agent_id)
      values ('lr/2026/00302','Lowercase LR',1,10,1,1,'x loc','some text','%s')$f$, ag1),
      '23514', 'LR numbers must be stored in canonical uppercase format');
end $$;

-- ------------------------------------------------------------ 5. customers (anon) and row-level security
do $$
declare r jsonb; v_avail bigint; v_res bigint; v_sold bigint; n int;
        ag1 uuid := 'aaaaaaaa-0000-0000-0000-000000000002'; ag2 uuid := 'aaaaaaaa-0000-0000-0000-000000000003';
        mgr uuid := 'aaaaaaaa-0000-0000-0000-000000000001';
begin
  -- more listings in each state
  perform test.login(ag1);
  r := public.rpc_create_property(test.prop('LR/2026/00201')); v_avail := (r ->> 'id')::bigint;
  r := public.rpc_create_property(test.prop('LR/2026/00202')); v_res := (r ->> 'id')::bigint;
  r := public.rpc_change_status(v_res, 1, 'RESERVED', '{"name":"Amina Hassan","phone":"+254733000111","id_number":"29111222"}', 100000);
  perform test.ok((r ->> 'ok')::boolean, 'second reservation (international phone format)');
  select id into v_sold from public.properties where lr_number = 'LR/2026/00148';

  perform test.anon();
  select count(*) into n from public.public_listings;
  perform test.ok(n = 3, 'customers can read the public listing view (3 live listings)');
  perform test.fails('select * from public.properties', '42501', 'customers cannot read the properties table');
  perform test.fails('select * from public.audit_log', '42501', 'customers cannot read the audit log');
  perform test.fails('select * from public.clients', '42501', 'customers cannot read client data');
  perform test.fails('select * from public.staff', '42501', 'customers cannot read staff');
  perform test.fails($q$select agent_id from public.public_listings$q$, '42703', 'public view exposes no agent id / IP / version');
  perform test.fails($q$select public.rpc_create_property('{}')$q$, '42501', 'customers cannot call staff functions');
  perform test.fails($q$select public.audit_write(null,'x','LOGIN','','',null)$q$, '42501', 'internal helper functions are not callable');
  perform test.fails($q$insert into public.viewing_requests (property_id,name,phone) values (1,'Hacker','0712345678')$q$, '42501', 'customers cannot insert rows directly');

  r := public.rpc_submit_viewing_request(v_avail, 'Esther Wambui', '0711223344', '', (current_date + 3), 'Hi');
  perform test.ok(r ->> 'kind' = 'VISIT', 'available property: viewing request accepted as a VISIT');
  r := public.rpc_submit_viewing_request(v_res, 'Kevin Otieno', '0722334455', 'k@example.com', null, '');
  perform test.ok(r ->> 'kind' = 'WAITLIST', 'reserved property: becomes a waiting-list inquiry');
  r := public.rpc_submit_viewing_request(v_sold, 'Mercy Chebet', '0733445566', '', null, '');
  perform test.ok(r ->> 'code' = 'sold', 'sold property: request refused');
  r := public.rpc_submit_viewing_request(v_avail, 'Bad Phone', '123', '', (current_date + 3), '');
  perform test.ok(r ->> 'code' = 'invalid', 'invalid phone number refused');
  r := public.rpc_submit_viewing_request(v_avail, 'Past Date', '0711223355', '', (current_date - 3), '');
  perform test.ok(r ->> 'code' = 'invalid', 'visit date in the past refused');
  perform public.rpc_submit_viewing_request(v_avail, 'Esther Wambui', '0711223344', '', (current_date + 4), 'again');
  perform public.rpc_submit_viewing_request(v_avail, 'Esther Wambui', '0711223344', '', (current_date + 5), 'again');
  r := public.rpc_submit_viewing_request(v_avail, 'Esther Wambui', '0711223344', '', (current_date + 6), 'again');
  perform test.ok(r ->> 'code' = 'rate_limited', 'spamming the same property is rate limited');

  -- agents
  perform test.login(ag2);
  select count(*) into n from public.properties;
  perform test.ok(n = 3, 'any active staff member can read all listings');
  select count(*) into n from public.audit_log;
  perform test.ok(n = 0, 'agents see no audit log rows (row-level security)');
  select count(*) into n from public.viewing_requests;
  perform test.ok(n = 0, 'agent2 does not see agent1''s viewing requests');
  perform test.fails($q$update public.properties set price = 1$q$, '42501', 'agents cannot UPDATE tables directly');
  perform test.fails($q$delete from public.properties$q$, '42501', 'agents cannot DELETE directly');
  perform test.fails($q$select * from public.clients$q$, '42501', 'agents cannot read the clients table');
  r := public.rpc_dashboard_stats();
  perform test.ok(r ->> 'code' = 'forbidden', 'agents cannot open the manager dashboard');

  perform test.login(ag1);
  select count(*) into n from public.viewing_requests;
  perform test.ok(n >= 3, 'agent1 sees the viewing requests for their own listings');
  select count(*) into n from public.notifications;
  perform test.ok(n >= 3, 'agent1 receives notifications');

  -- manager
  perform test.login(mgr);
  select count(*) into n from public.audit_log;
  perform test.ok(n > 5, 'the manager can read the audit log');
  r := public.rpc_dashboard_stats();
  perform test.ok((r ->> 'ok')::boolean and (r ->> 'total')::int = 3 and (r ->> 'triggers_found')::int = 5,
                  'manager dashboard returns counts and confirms all 5 triggers are active');
  perform test.ok((r ->> 'conflicts_today')::int = 1 and (r ->> 'duplicates_today')::int = 3, 'dashboard counts today''s conflicts and blocked duplicates');
  r := public.rpc_report_agent_performance(null, null);
  perform test.ok(jsonb_array_length(r -> 'rows') = 3, 'agent performance report returns one row per staff member');
  r := public.rpc_set_staff(mgr, 'AGENT', true);
  perform test.ok(r ->> 'code' = 'invalid', 'a manager cannot demote themselves');
  r := public.rpc_set_staff(ag2, 'MANAGER', true);
  perform test.ok((r ->> 'ok')::boolean, 'a manager can promote another account');
  r := public.rpc_set_staff(ag2, 'AGENT', false);
  perform test.ok((r ->> 'ok')::boolean, 'a manager can deactivate an account');

  perform test.login(ag2);
  r := public.rpc_create_property(test.prop('LR/2026/00999'));
  perform test.ok(r ->> 'code' = 'forbidden', 'a deactivated account loses access immediately');
  reset role;
end $$;

-- ------------------------------------------------------------ 6. integrity check catches corruption
do $$
declare r jsonb; mgr uuid := 'aaaaaaaa-0000-0000-0000-000000000001'; v_id bigint;
begin
  perform test.login(mgr);
  r := public.rpc_dashboard_stats();
  perform test.ok((select sum((e ->> 'count')::int) from jsonb_array_elements(r -> 'issues') e) = 0, 'no integrity issues after normal use');
  reset role;
  select id into v_id from public.properties where lr_number = 'LR/2026/00202';
  update public.reservations set status = 'CANCELLED', closed_at = now() where property_id = v_id;   -- simulate corruption
  perform test.login(mgr);
  r := public.rpc_dashboard_stats();
  perform test.ok((r -> 'issues' -> 0 ->> 'count')::int = 1, 'integrity check detects a Reserved listing with no reservation');
  reset role;
  update public.reservations set status = 'ACTIVE', closed_at = null where property_id = v_id;       -- repair
end $$;

-- ------------------------------------------------------------ 7. archive (soft delete)
do $$
declare r jsonb; v_id bigint; v_ver int; ag1 uuid := 'aaaaaaaa-0000-0000-0000-000000000002'; n int;
begin
  select id, version into v_id, v_ver from public.properties where lr_number = 'LR/2026/00201';
  perform test.login(ag1);
  r := public.rpc_archive_property(v_id, v_ver);
  perform test.ok((r ->> 'ok')::boolean, 'an available listing can be archived');
  select count(*) into n from public.public_listings where id = v_id;
  perform test.ok(n = 0, 'archived listings vanish from the customer portal');
  r := public.rpc_update_property(v_id, v_ver + 1, '{"price": 5}');
  perform test.ok(r ->> 'code' = 'not_found', 'archived listings cannot be edited');
  reset role;
  perform test.ok((select count(*) from public.properties where id = v_id) = 1, 'the archived row still exists');
  perform test.ok((select count(*) from public.audit_log where action = 'ARCHIVE') = 1, 'archiving was audited');
end $$;
