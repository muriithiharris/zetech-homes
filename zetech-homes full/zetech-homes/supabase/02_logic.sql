-- =====================================================================
-- ZETECH HOMES  |  Step 2 of 6  |  Integrity triggers + business functions
-- Run after 01_schema.sql.
--
-- Three ideas to explain in your viva:
--   1. The DATABASE refuses bad data (constraints + triggers), so even a bug
--      in the website cannot create duplicates, lost updates or illegal
--      status changes.
--   2. Every update quotes the version it read:
--        UPDATE ... WHERE id = ? AND version = <version I saw>
--      If another agent committed first, 0 rows change and the user is told to
--      refresh (optimistic concurrency on top of PostgreSQL's MVCC).
--   3. The audit log is written by triggers and is append-only.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A. Private schema: the encryption key for client phone / ID numbers
-- ---------------------------------------------------------------------
create schema if not exists private;

create table if not exists private.app_secrets (
  name   text primary key,
  value  text not null
);
insert into private.app_secrets (name, value)
values ('pii_key', encode(extensions.gen_random_bytes(32), 'hex'))
on conflict (name) do nothing;

create or replace function private.pii_encrypt(p text) returns bytea
language sql security definer set search_path = private, extensions as $$
  select extensions.pgp_sym_encrypt(p, (select value from private.app_secrets where name = 'pii_key'));
$$;

create or replace function private.pii_decrypt(p bytea) returns text
language sql security definer set search_path = private, extensions as $$
  select extensions.pgp_sym_decrypt(p, (select value from private.app_secrets where name = 'pii_key'));
$$;

-- ---------------------------------------------------------------------
-- B. Small helpers
-- ---------------------------------------------------------------------
create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff s where s.id = auth.uid() and s.is_active);
$$;

create or replace function public.is_manager() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff s
                 where s.id = auth.uid() and s.is_active and s.role = 'MANAGER');
$$;

-- Caller's IP address (Supabase passes it in the x-forwarded-for request header)
create or replace function public.client_ip() returns inet
language plpgsql stable set search_path = public as $$
declare h text; ip text;
begin
  h := current_setting('request.headers', true);
  if h is null or h = '' then return null; end if;
  ip := trim(split_part(coalesce((h::json) ->> 'x-forwarded-for', ''), ',', 1));
  if ip = '' then return null; end if;
  return ip::inet;
exception when others then
  return null;
end $$;

create or replace function public.zh_err(p_code text, p_message text) returns jsonb
language sql immutable as $$
  select jsonb_build_object('ok', false, 'code', p_code, 'message', p_message);
$$;

create or replace function public.zh_friendly(p_state text, p_msg text) returns text
language sql immutable as $$
  select case
    when p_state = '23514' then 'One of the values is not allowed (' || p_msg || ').'
    when p_state = '23503' then 'The selected county, sub-county or type is not valid together.'
    when p_state = '23502' then 'A required field is missing.'
    when p_state in ('22P02', '22003') then 'A number was typed in the wrong format.'
    when p_state = 'ZH409' then 'This record was changed by another user.'
    when p_state = 'ZH422' then 'That status change is not allowed.'
    else p_msg
  end;
$$;

-- AuditLogger: the one place that writes to the audit trail
create or replace function public.audit_write(
  p_user uuid, p_lr text, p_action text, p_old text, p_new text, p_ip inet) returns void
language sql security definer set search_path = public as $$
  insert into public.audit_log (user_id, target_lr, action, old_value, new_value, ip_address)
  values (p_user, coalesce(p_lr, ''), p_action, coalesce(p_old, ''), coalesce(p_new, ''), p_ip);
$$;

create or replace function public.notify_staff(p_user uuid, p_message text, p_link text default '')
returns void language sql security definer set search_path = public as $$
  insert into public.notifications (user_id, message, link) values (p_user, left(p_message, 255), coalesce(p_link, ''));
$$;

create or replace function public.notify_managers(p_message text, p_link text default '')
returns void language sql security definer set search_path = public as $$
  insert into public.notifications (user_id, message, link)
  select s.id, left(p_message, 255), coalesce(p_link, '')
  from public.staff s where s.is_active and s.role = 'MANAGER';
$$;

-- ---------------------------------------------------------------------
-- C. TRIGGERS: the database enforces the rules itself
-- ---------------------------------------------------------------------

-- C1. Guard: version check, status transitions, permanent LR number, no hard delete
create or replace function public.trg_properties_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Properties cannot be deleted, archive them instead' using errcode = 'ZH403';
  end if;
  if new.lr_number is distinct from old.lr_number then
    raise exception 'LR number cannot be changed' using errcode = 'ZH403';
  end if;
  if new.version <> old.version + 1 then
    raise exception 'Version conflict: record was changed by another user' using errcode = 'ZH409';
  end if;
  if new.status <> old.status and not (
        (old.status = 'AVAILABLE' and new.status = 'RESERVED')
     or (old.status = 'RESERVED'  and new.status in ('AVAILABLE', 'SOLD'))) then
    raise exception 'Illegal status transition (Sold listings are final)' using errcode = 'ZH422';
  end if;
  return new;
end $$;

drop trigger if exists properties_guard_upd on public.properties;
create trigger properties_guard_upd before update on public.properties
  for each row execute function public.trg_properties_guard();

drop trigger if exists properties_guard_del on public.properties;
create trigger properties_guard_del before delete on public.properties
  for each row execute function public.trg_properties_guard();

-- C2. Audit writer: records every create / status / price / details / archive change
create or replace function public.trg_properties_audit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    perform public.audit_write(new.updated_by, new.lr_number, 'INSERT_ENTRY', '',
                               new.title || ' @ KES ' || new.price::text, new.updated_ip);
    return new;
  end if;

  if new.status <> old.status then
    perform public.audit_write(new.updated_by, new.lr_number, 'STATUS_UPDATE', old.status, new.status, new.updated_ip);
  end if;
  if new.price <> old.price then
    perform public.audit_write(new.updated_by, new.lr_number, 'PRICE_EDIT', old.price::text, new.price::text, new.updated_ip);
  end if;
  if (new.title, new.location, new.description, new.bedrooms, new.bathrooms,
      new.property_type_id, new.county_id, new.sub_county_id)
     is distinct from
     (old.title, old.location, old.description, old.bedrooms, old.bathrooms,
      old.property_type_id, old.county_id, old.sub_county_id) then
    perform public.audit_write(new.updated_by, new.lr_number, 'DETAILS_EDIT',
      'title=' || old.title || '; location=' || old.location || '; beds=' || old.bedrooms || '; baths=' || old.bathrooms,
      'title=' || new.title || '; location=' || new.location || '; beds=' || new.bedrooms || '; baths=' || new.bathrooms,
      new.updated_ip);
  end if;
  if old.archived_at is null and new.archived_at is not null then
    perform public.audit_write(new.updated_by, new.lr_number, 'ARCHIVE', 'Active', 'Archived', new.updated_ip);
  end if;
  return new;
end $$;

drop trigger if exists properties_audit_trg on public.properties;
create trigger properties_audit_trg after insert or update on public.properties
  for each row execute function public.trg_properties_audit();

-- C3. The audit log is append-only: nobody can change or erase history
create or replace function public.trg_audit_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'The audit log is immutable' using errcode = 'ZH403';
end $$;

drop trigger if exists audit_no_change on public.audit_log;
create trigger audit_no_change before update or delete on public.audit_log
  for each row execute function public.trg_audit_immutable();

drop trigger if exists audit_no_truncate on public.audit_log;
create trigger audit_no_truncate before truncate on public.audit_log
  for each statement execute function public.trg_audit_immutable();

-- C4. New Supabase Auth user -> staff profile (always an AGENT; a manager promotes later)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.staff (id, full_name, email, role)
  values (new.id,
          coalesce(nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''), split_part(new.email, '@', 1)),
          new.email, 'AGENT')
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- D. Business functions the website calls (RPC). They return JSON:
--    { ok: true, ... }  or  { ok: false, code: '...', message: '...' }
--    Failures are RETURNED (not raised) so the audit entry we write for a
--    blocked duplicate or a conflict is committed instead of rolled back.
-- ---------------------------------------------------------------------

-- D1. DuplicateGuard helper
create or replace function public.zh_duplicate(p_uid uuid, p_lr text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_today date := (now() at time zone 'Africa/Nairobi')::date; v_attempts integer;
begin
  perform public.audit_write(p_uid, p_lr, 'DUPLICATE_BLOCKED', '',
                             'Attempt to create an LR number that already exists', public.client_ip());
  select count(*) into v_attempts from public.audit_log
   where user_id = p_uid and action = 'DUPLICATE_BLOCKED'
     and (created_at at time zone 'Africa/Nairobi')::date = v_today;
  if v_attempts = 3 then   -- repeated attempts: alert the managers once
    perform public.notify_managers('A staff member has tried to create duplicate listings ' || v_attempts || ' times today.', 'audit.html?action=DUPLICATE_BLOCKED');
  end if;
  return public.zh_err('duplicate', p_lr || ' is already registered. The attempt was recorded in the audit log.');
end $$;

-- D2. Conflict helper (version mismatch = someone else saved first)
create or replace function public.zh_conflict(p_uid uuid, p_id bigint, p_seen integer) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_prop public.properties;
begin
  select * into v_prop from public.properties where id = p_id;
  if found then
    perform public.audit_write(p_uid, v_prop.lr_number, 'MVCC_CONFLICT',
      'Edited from version ' || p_seen, 'Current version is ' || v_prop.version, public.client_ip());
    if v_prop.agent_id <> p_uid then
      perform public.notify_staff(v_prop.agent_id,
        'A concurrent update conflict was blocked on ' || v_prop.lr_number || '.', 'status.html?id=' || p_id);
    end if;
  end if;
  return jsonb_build_object('ok', false, 'code', 'conflict',
    'message', 'This record was changed by another user while you were editing it. Nothing was saved. Please refresh to see the latest version and try again.',
    'current_version', v_prop.version);
end $$;

-- D3. Create a listing
create or replace function public.rpc_create_property(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_uid uuid := auth.uid(); v_lr text; v_id bigint;
begin
  if not public.is_staff() then return public.zh_err('forbidden', 'Staff access only.'); end if;

  v_lr := upper(regexp_replace(coalesce(p ->> 'lr_number', ''), '\s+', '', 'g'));
  if v_lr !~ '^LR/[0-9]{4}/[0-9]{3,6}$' then
    return public.zh_err('invalid_lr', 'LR number must look like LR/2026/00148 (LR, year, serial number).');
  end if;

  if exists (select 1 from public.properties where lr_number = v_lr) then
    return public.zh_duplicate(v_uid, v_lr);
  end if;

  begin
    insert into public.properties
      (lr_number, title, property_type_id, price, county_id, sub_county_id, location, description,
       bedrooms, bathrooms, agent_id, updated_by, updated_ip)
    values
      (v_lr, trim(p ->> 'title'), (p ->> 'property_type_id')::integer, (p ->> 'price')::numeric,
       (p ->> 'county_id')::integer, (p ->> 'sub_county_id')::integer, trim(p ->> 'location'),
       trim(p ->> 'description'), coalesce((p ->> 'bedrooms')::smallint, 0),
       coalesce((p ->> 'bathrooms')::smallint, 0), v_uid, v_uid, public.client_ip())
    returning id into v_id;
  exception
    when unique_violation then          -- two agents submitted the same LR at the same instant
      return public.zh_duplicate(v_uid, v_lr);
    when others then
      return public.zh_err('invalid', public.zh_friendly(sqlstate, sqlerrm));
  end;

  return jsonb_build_object('ok', true, 'id', v_id, 'lr_number', v_lr);
end $$;

-- D4. Check an LR number while the agent types
create or replace function public.rpc_check_lr(p_lr text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_lr text := upper(regexp_replace(coalesce(p_lr, ''), '\s+', '', 'g')); v_valid boolean;
begin
  if not public.is_staff() then return public.zh_err('forbidden', 'Staff access only.'); end if;
  v_valid := v_lr ~ '^LR/[0-9]{4}/[0-9]{3,6}$';
  return jsonb_build_object('ok', true, 'lr', v_lr, 'valid', v_valid,
    'exists', v_valid and exists (select 1 from public.properties where lr_number = v_lr));
end $$;

-- D5. Edit listing details (version-checked)
create or replace function public.rpc_update_property(p_id bigint, p_version integer, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_prop public.properties; v_rows integer;
begin
  if not public.is_staff() then return public.zh_err('forbidden', 'Staff access only.'); end if;
  select * into v_prop from public.properties where id = p_id and archived_at is null;
  if not found then return public.zh_err('not_found', 'Listing not found or already archived.'); end if;
  if not (public.is_manager() or v_prop.agent_id = v_uid) then
    return public.zh_err('forbidden', 'You can only change your own listings.');
  end if;

  begin
    update public.properties set
      title            = coalesce(trim(p ->> 'title'), title),
      property_type_id = coalesce((p ->> 'property_type_id')::integer, property_type_id),
      price            = coalesce((p ->> 'price')::numeric, price),
      county_id        = coalesce((p ->> 'county_id')::integer, county_id),
      sub_county_id    = coalesce((p ->> 'sub_county_id')::integer, sub_county_id),
      location         = coalesce(trim(p ->> 'location'), location),
      description      = coalesce(trim(p ->> 'description'), description),
      bedrooms         = coalesce((p ->> 'bedrooms')::smallint, bedrooms),
      bathrooms        = coalesce((p ->> 'bathrooms')::smallint, bathrooms),
      version = version + 1, updated_by = v_uid, updated_ip = public.client_ip(), updated_at = now()
    where id = p_id and version = p_version and archived_at is null;   -- <- the version check
    get diagnostics v_rows = row_count;
  exception when others then
    return public.zh_err('invalid', public.zh_friendly(sqlstate, sqlerrm));
  end;

  if v_rows = 0 then return public.zh_conflict(v_uid, p_id, p_version); end if;
  return jsonb_build_object('ok', true, 'version', p_version + 1);
end $$;

-- D6. StatusWorkflow: Available -> Reserved -> Sold (Reserved -> Available cancels)
create or replace function public.rpc_change_status(
  p_id bigint, p_version integer, p_new text, p_client jsonb default null, p_fee numeric default null)
returns jsonb language plpgsql security definer set search_path = public, private, extensions as $$
declare v_uid uuid := auth.uid(); v_prop public.properties; v_rows integer; v_client bigint;
begin
  if not public.is_staff() then return public.zh_err('forbidden', 'Staff access only.'); end if;
  select * into v_prop from public.properties where id = p_id and archived_at is null;
  if not found then return public.zh_err('not_found', 'Listing not found or already archived.'); end if;
  if not (public.is_manager() or v_prop.agent_id = v_uid) then
    return public.zh_err('forbidden', 'You can only change your own listings.');
  end if;
  if p_new not in ('AVAILABLE', 'RESERVED', 'SOLD') then
    return public.zh_err('invalid', 'Unknown status.');
  end if;
  if p_new = v_prop.status then
    return public.zh_err('illegal_transition', 'The listing is already ' || initcap(v_prop.status) || '.');
  end if;
  if not ((v_prop.status = 'AVAILABLE' and p_new = 'RESERVED')
       or (v_prop.status = 'RESERVED'  and p_new in ('AVAILABLE', 'SOLD'))) then
    return public.zh_err('illegal_transition',
      'A listing cannot move from ' || initcap(v_prop.status) || ' to ' || initcap(p_new) || '.');
  end if;

  if p_new = 'RESERVED' then
    if p_client is null or length(trim(coalesce(p_client ->> 'name', ''))) < 2 then
      return public.zh_err('invalid', 'Client name is required to reserve a property.');
    end if;
    if coalesce(p_client ->> 'phone', '') !~ '^(\+254|0)[17][0-9]{8}$' then
      return public.zh_err('invalid', 'Enter a valid Kenyan client phone number, e.g. 0712345678.');
    end if;
    if length(trim(coalesce(p_client ->> 'id_number', ''))) < 5 then
      return public.zh_err('invalid', 'Client ID number is required to reserve a property.');
    end if;
    if p_fee is null or p_fee < 0 then
      return public.zh_err('invalid', 'Enter the reservation fee (0 if none).');
    end if;
  end if;

  begin
    update public.properties
       set status = p_new, version = version + 1, updated_by = v_uid,
           updated_ip = public.client_ip(), updated_at = now()
     where id = p_id and version = p_version and archived_at is null;   -- <- the version check
    get diagnostics v_rows = row_count;

    if v_rows = 1 then
      if p_new = 'RESERVED' then
        insert into public.clients (full_name, phone_enc, id_number_enc)
        values (trim(p_client ->> 'name'), private.pii_encrypt(p_client ->> 'phone'),
                private.pii_encrypt(trim(p_client ->> 'id_number')))
        returning id into v_client;
        insert into public.reservations (property_id, client_id, fee, created_by)
        values (p_id, v_client, p_fee, v_uid);
      else
        update public.reservations
           set status = case when p_new = 'AVAILABLE' then 'CANCELLED' else 'COMPLETED' end,
               closed_at = now()
         where property_id = p_id and status = 'ACTIVE';
      end if;
    end if;
  exception when others then
    return public.zh_err('invalid', public.zh_friendly(sqlstate, sqlerrm));
  end;

  if v_rows = 0 then return public.zh_conflict(v_uid, p_id, p_version); end if;

  if p_new = 'RESERVED' then
    perform public.notify_staff(v_prop.agent_id,
      v_prop.lr_number || ' was reserved by ' || trim(p_client ->> 'name') || '.', 'status.html?id=' || p_id);
  end if;
  return jsonb_build_object('ok', true, 'version', p_version + 1, 'status', p_new);
end $$;

-- D7. Soft delete (archive). Listings are never removed.
create or replace function public.rpc_archive_property(p_id bigint, p_version integer) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_prop public.properties; v_rows integer;
begin
  if not public.is_staff() then return public.zh_err('forbidden', 'Staff access only.'); end if;
  select * into v_prop from public.properties where id = p_id and archived_at is null;
  if not found then return public.zh_err('not_found', 'Listing not found or already archived.'); end if;
  if not (public.is_manager() or v_prop.agent_id = v_uid) then
    return public.zh_err('forbidden', 'You can only change your own listings.');
  end if;
  if v_prop.status = 'RESERVED' then
    return public.zh_err('illegal_transition', 'A reserved listing cannot be archived. Cancel the reservation first.');
  end if;

  update public.properties
     set archived_at = now(), version = version + 1, updated_by = v_uid,
         updated_ip = public.client_ip(), updated_at = now()
   where id = p_id and version = p_version and archived_at is null;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then return public.zh_conflict(v_uid, p_id, p_version); end if;
  return jsonb_build_object('ok', true);
end $$;

-- D8. Register an uploaded photo (the file itself goes to Supabase Storage)
create or replace function public.rpc_add_property_image(p_property_id bigint, p_path text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_prop public.properties; v_first boolean;
begin
  if not public.is_staff() then return public.zh_err('forbidden', 'Staff access only.'); end if;
  select * into v_prop from public.properties where id = p_property_id and archived_at is null;
  if not found then return public.zh_err('not_found', 'Listing not found.'); end if;
  if not (public.is_manager() or v_prop.agent_id = v_uid) then
    return public.zh_err('forbidden', 'You can only change your own listings.');
  end if;
  if p_path is null or p_path not like (p_property_id::text || '/%') then
    return public.zh_err('invalid', 'Invalid image path.');
  end if;
  v_first := not exists (select 1 from public.property_images where property_id = p_property_id);
  insert into public.property_images (property_id, path, is_primary) values (p_property_id, p_path, v_first);
  return jsonb_build_object('ok', true);
end $$;

-- D9. Customers: request a viewing / join the waiting list (no login needed)
create or replace function public.rpc_submit_viewing_request(
  p_property_id bigint, p_name text, p_phone text, p_email text, p_date date, p_message text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_prop public.properties; v_kind text; v_today date := (now() at time zone 'Africa/Nairobi')::date;
begin
  select * into v_prop from public.properties where id = p_property_id and archived_at is null;
  if not found then return public.zh_err('not_found', 'This property is no longer listed.'); end if;
  if v_prop.status = 'SOLD' then
    return public.zh_err('sold', 'This property has been sold and is no longer available.');
  end if;
  if length(trim(coalesce(p_name, ''))) < 2 then return public.zh_err('invalid', 'Please enter your name.'); end if;
  if coalesce(p_phone, '') !~ '^(\+254|0)[17][0-9]{8}$' then
    return public.zh_err('invalid', 'Enter a valid Kenyan phone number, e.g. 0712345678 or +254712345678.');
  end if;
  if coalesce(p_email, '') <> '' and p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    return public.zh_err('invalid', 'That email address does not look right.');
  end if;

  v_kind := case when v_prop.status = 'AVAILABLE' then 'VISIT' else 'WAITLIST' end;
  if v_kind = 'VISIT' and (p_date is null or p_date < v_today) then
    return public.zh_err('invalid', 'Please choose a visit date from today onwards.');
  end if;
  if (select count(*) from public.viewing_requests
       where property_id = p_property_id and phone = p_phone and created_at > now() - interval '1 day') >= 3 then
    return public.zh_err('rate_limited', 'You have already sent several requests for this property today.');
  end if;

  insert into public.viewing_requests (property_id, kind, name, phone, email, preferred_date, message)
  values (p_property_id, v_kind, trim(p_name), p_phone, nullif(trim(coalesce(p_email, '')), ''),
          case when v_kind = 'VISIT' then p_date end, left(coalesce(p_message, ''), 1000));

  perform public.notify_staff(v_prop.agent_id,
    'New ' || case when v_kind = 'VISIT' then 'viewing request' else 'waiting-list inquiry' end
    || ' for ' || v_prop.lr_number || ' from ' || trim(p_name) || '.', 'viewing.html');
  return jsonb_build_object('ok', true, 'kind', v_kind);
end $$;

create or replace function public.rpc_set_request_handled(p_id bigint, p_handled boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then return public.zh_err('forbidden', 'Staff access only.'); end if;
  update public.viewing_requests v set handled = p_handled
   where v.id = p_id and (public.is_manager()
         or exists (select 1 from public.properties p where p.id = v.property_id and p.agent_id = auth.uid()));
  if not found then return public.zh_err('forbidden', 'Request not found or not yours.'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.rpc_mark_notifications_read() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then return public.zh_err('forbidden', 'Staff access only.'); end if;
  update public.notifications set is_read = true where user_id = auth.uid() and not is_read;
  return jsonb_build_object('ok', true);
end $$;

-- D10. Sessions: login/logout bookkeeping (IP + start time) and the audit LOGIN entry
create or replace function public.rpc_log_login() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_staff public.staff;
begin
  select * into v_staff from public.staff where id = v_uid and is_active;
  if not found then
    return public.zh_err('forbidden', 'This account is not an active staff account. Contact the System Manager.');
  end if;
  insert into public.login_sessions (user_id, ip_address) values (v_uid, public.client_ip());
  perform public.audit_write(v_uid, '', 'LOGIN', '', 'Signed in', public.client_ip());
  return jsonb_build_object('ok', true, 'id', v_staff.id, 'full_name', v_staff.full_name,
                            'role', v_staff.role, 'staff_no', v_staff.staff_no);
end $$;

create or replace function public.rpc_log_logout() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  update public.login_sessions set ended_at = now()
   where id = (select id from public.login_sessions
                where user_id = auth.uid() and ended_at is null order by started_at desc limit 1);
  return jsonb_build_object('ok', true);
end $$;

-- D11. Reservation details with the client's decrypted contact data
create or replace function public.rpc_reservation_details(p_property_id bigint) returns jsonb
language plpgsql security definer set search_path = public, private, extensions as $$
declare v_prop public.properties; v_res jsonb;
begin
  if not public.is_staff() then return public.zh_err('forbidden', 'Staff access only.'); end if;
  select * into v_prop from public.properties where id = p_property_id;
  if not found then return public.zh_err('not_found', 'Listing not found.'); end if;
  if not (public.is_manager() or v_prop.agent_id = auth.uid()) then
    return public.zh_err('forbidden', 'You can only view your own listings.');
  end if;
  select jsonb_build_object('id', r.id, 'fee', r.fee, 'created_at', r.created_at,
           'client_name', c.full_name, 'client_phone', private.pii_decrypt(c.phone_enc),
           'client_id_number', private.pii_decrypt(c.id_number_enc))
    into v_res
    from public.reservations r join public.clients c on c.id = r.client_id
   where r.property_id = p_property_id and r.status = 'ACTIVE';
  return jsonb_build_object('ok', true, 'reservation', v_res);
end $$;

-- ---------------------------------------------------------------------
-- E. Manager tools: integrity check, dashboard, staff, reports
-- ---------------------------------------------------------------------
create or replace function public.integrity_issues() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_array(
    jsonb_build_object('label', 'Reserved listings with no active reservation', 'count',
      (select count(*) from public.properties p where p.archived_at is null and p.status = 'RESERVED'
         and not exists (select 1 from public.reservations r where r.property_id = p.id and r.status = 'ACTIVE'))),
    jsonb_build_object('label', 'Active reservations on listings that are not Reserved', 'count',
      (select count(*) from public.reservations r join public.properties p on p.id = r.property_id
        where r.status = 'ACTIVE' and p.status <> 'RESERVED')),
    jsonb_build_object('label', 'Live listings owned by deactivated accounts', 'count',
      (select count(*) from public.properties p join public.staff s on s.id = p.agent_id
        where p.archived_at is null and not s.is_active))
  );
$$;

create or replace function public.rpc_dashboard_stats() returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb; v_today date := (now() at time zone 'Africa/Nairobi')::date;
begin
  if not public.is_manager() then return public.zh_err('forbidden', 'Managers only.'); end if;
  select jsonb_build_object(
           'available', count(*) filter (where status = 'AVAILABLE'),
           'reserved',  count(*) filter (where status = 'RESERVED'),
           'sold',      count(*) filter (where status = 'SOLD'),
           'total',     count(*))
    into v from public.properties where archived_at is null;
  return v || jsonb_build_object(
    'ok', true,
    'duplicates_today', (select count(*) from public.audit_log
        where action = 'DUPLICATE_BLOCKED' and (created_at at time zone 'Africa/Nairobi')::date = v_today),
    'conflicts_today', (select count(*) from public.audit_log
        where action = 'MVCC_CONFLICT' and (created_at at time zone 'Africa/Nairobi')::date = v_today),
    'open_requests', (select count(*) from public.viewing_requests where not handled),
    'issues', public.integrity_issues(),
    'triggers_expected', 5,
    'triggers_found', (select count(*) from pg_trigger where not tgisinternal and tgname in
        ('properties_guard_upd', 'properties_guard_del', 'properties_audit_trg', 'audit_no_change', 'audit_no_truncate')),
    'agents', (select coalesce(jsonb_agg(to_jsonb(a) order by a.staff_no), '[]'::jsonb) from (
        select s.id, s.staff_no, s.full_name, s.role,
               count(p.id) as listings,
               count(p.id) filter (where p.status = 'AVAILABLE') as available,
               count(p.id) filter (where p.status = 'RESERVED') as reserved,
               count(p.id) filter (where p.status = 'SOLD') as sold,
               (select count(*) from public.audit_log al where al.user_id = s.id and al.action <> 'LOGIN'
                   and al.created_at >= now() - interval '7 days') as actions_week
          from public.staff s
          left join public.properties p on p.agent_id = s.id and p.archived_at is null
         where s.is_active group by s.id) a));
end $$;

create or replace function public.rpc_set_staff(p_id uuid, p_role text, p_active boolean, p_name text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_manager() then return public.zh_err('forbidden', 'Managers only.'); end if;
  if p_role not in ('AGENT', 'MANAGER') then return public.zh_err('invalid', 'Unknown role.'); end if;
  if p_id = auth.uid() and (p_role <> 'MANAGER' or not p_active) then
    return public.zh_err('invalid', 'You cannot remove your own manager access or deactivate yourself.');
  end if;
  update public.staff set role = p_role, is_active = p_active,
         full_name = coalesce(nullif(trim(p_name), ''), full_name)
   where id = p_id;
  if not found then return public.zh_err('not_found', 'Account not found.'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.rpc_report_agent_performance(p_from date default null, p_to date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_manager() then return public.zh_err('forbidden', 'Managers only.'); end if;
  return jsonb_build_object('ok', true, 'rows', (select coalesce(jsonb_agg(to_jsonb(a) order by a.staff_no), '[]'::jsonb) from (
    select s.staff_no, s.full_name,
      (select count(*) from public.properties p where p.agent_id = s.id and p.archived_at is null) as listings,
      (select count(*) from public.properties p where p.agent_id = s.id and p.archived_at is null and p.status = 'AVAILABLE') as available,
      (select count(*) from public.properties p where p.agent_id = s.id and p.archived_at is null and p.status = 'RESERVED') as reserved,
      (select count(*) from public.properties p where p.agent_id = s.id and p.archived_at is null and p.status = 'SOLD') as sold,
      (select count(*) from public.reservations r where r.created_by = s.id
          and (p_from is null or (r.created_at at time zone 'Africa/Nairobi')::date >= p_from)
          and (p_to   is null or (r.created_at at time zone 'Africa/Nairobi')::date <= p_to)) as reservations_made,
      (select coalesce(sum(r.fee), 0) from public.reservations r where r.created_by = s.id
          and (p_from is null or (r.created_at at time zone 'Africa/Nairobi')::date >= p_from)
          and (p_to   is null or (r.created_at at time zone 'Africa/Nairobi')::date <= p_to)) as reservation_fees,
      (select count(*) from public.audit_log al where al.user_id = s.id and al.action <> 'LOGIN'
          and (p_from is null or (al.created_at at time zone 'Africa/Nairobi')::date >= p_from)
          and (p_to   is null or (al.created_at at time zone 'Africa/Nairobi')::date <= p_to)) as audit_actions
    from public.staff s) a));
end $$;
