-- =====================================================================
-- ZETECH HOMES  |  Step 3 of 6  |  Public views, row-level security, permissions
-- Run after 02_logic.sql. Safe to run again at any time (re-run it last
-- whenever you add new functions, so they stay locked down).
--
-- Principle: the Supabase "anon key" sits inside your web page, so anybody
-- can use it. Therefore:
--   * customers (anon) can only READ a safe public view and call ONE
--     function (request a viewing);
--   * staff (authenticated) can READ what their role allows, but cannot
--     INSERT/UPDATE/DELETE tables directly. All changes go through the
--     rpc_* functions, which enforce duplicate, version and status rules;
--   * the audit log can be read by managers only and can never be changed.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A. Public views for the customer portal (no agent ids, IPs or versions)
-- ---------------------------------------------------------------------
create or replace view public.public_listings as
select p.id, p.lr_number, p.title, p.price, p.location, p.description,
       p.bedrooms, p.bathrooms, p.status, p.created_at,
       p.property_type_id, pt.name  as property_type,
       p.county_id,        c.name   as county,
       p.sub_county_id,    sc.name  as sub_county,
       (select split_part(s.full_name, ' ', 1) from public.staff s where s.id = p.agent_id) as agent_first_name,
       (select i.path from public.property_images i
         where i.property_id = p.id order by i.is_primary desc, i.id limit 1) as image_path
from public.properties p
join public.property_types pt on pt.id = p.property_type_id
join public.counties c       on c.id  = p.county_id
join public.sub_counties sc  on sc.id = p.sub_county_id
where p.archived_at is null;

create or replace view public.public_property_images as
select i.id, i.property_id, i.path, i.is_primary
from public.property_images i
join public.properties p on p.id = i.property_id
where p.archived_at is null;

-- ---------------------------------------------------------------------
-- B. Lock everything, then open only what is needed
-- ---------------------------------------------------------------------
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;
grant usage on schema public to anon, authenticated;

alter table public.staff            enable row level security;
alter table public.counties         enable row level security;
alter table public.sub_counties     enable row level security;
alter table public.property_types   enable row level security;
alter table public.properties       enable row level security;
alter table public.property_images  enable row level security;
alter table public.clients          enable row level security;   -- no policy: nobody reads it directly
alter table public.reservations     enable row level security;
alter table public.viewing_requests enable row level security;
alter table public.notifications    enable row level security;
alter table public.audit_log        enable row level security;
alter table public.login_sessions   enable row level security;

-- Customers + staff: lookup lists and the safe public views
grant select on public.counties, public.sub_counties, public.property_types,
                public.public_listings, public.public_property_images to anon, authenticated;

drop policy if exists lookups_read on public.counties;
create policy lookups_read on public.counties       for select to anon, authenticated using (true);
drop policy if exists lookups_read on public.sub_counties;
create policy lookups_read on public.sub_counties   for select to anon, authenticated using (true);
drop policy if exists lookups_read on public.property_types;
create policy lookups_read on public.property_types for select to anon, authenticated using (true);

-- Staff: read access (writes only through rpc_* functions)
grant select on public.staff, public.properties, public.property_images, public.reservations,
                public.viewing_requests, public.notifications, public.audit_log,
                public.login_sessions to authenticated;

drop policy if exists staff_read on public.staff;
create policy staff_read on public.staff for select to authenticated using (public.is_staff());

drop policy if exists properties_read on public.properties;
create policy properties_read on public.properties for select to authenticated using (public.is_staff());

drop policy if exists images_read on public.property_images;
create policy images_read on public.property_images for select to authenticated using (public.is_staff());

drop policy if exists reservations_read on public.reservations;
create policy reservations_read on public.reservations for select to authenticated using (
  public.is_staff() and (public.is_manager() or exists (
    select 1 from public.properties p where p.id = reservations.property_id and p.agent_id = auth.uid())));

drop policy if exists viewing_read on public.viewing_requests;
create policy viewing_read on public.viewing_requests for select to authenticated using (
  public.is_staff() and (public.is_manager() or exists (
    select 1 from public.properties p where p.id = viewing_requests.property_id and p.agent_id = auth.uid())));

drop policy if exists notifications_own on public.notifications;
create policy notifications_own on public.notifications for select to authenticated using (user_id = auth.uid());

drop policy if exists audit_managers on public.audit_log;
create policy audit_managers on public.audit_log for select to authenticated using (public.is_manager());

drop policy if exists sessions_managers on public.login_sessions;
create policy sessions_managers on public.login_sessions for select to authenticated using (public.is_manager());

-- ---------------------------------------------------------------------
-- C. Which functions each role may call
-- ---------------------------------------------------------------------
-- used inside the policies above
grant execute on function public.is_staff(), public.is_manager() to anon, authenticated;

-- customers (and staff) may send a viewing request
grant execute on function public.rpc_submit_viewing_request(bigint, text, text, text, date, text)
  to anon, authenticated;

-- staff only (each function re-checks the caller's role inside)
grant execute on function
  public.rpc_create_property(jsonb),
  public.rpc_check_lr(text),
  public.rpc_update_property(bigint, integer, jsonb),
  public.rpc_change_status(bigint, integer, text, jsonb, numeric),
  public.rpc_archive_property(bigint, integer),
  public.rpc_add_property_image(bigint, text),
  public.rpc_set_request_handled(bigint, boolean),
  public.rpc_mark_notifications_read(),
  public.rpc_log_login(),
  public.rpc_log_logout(),
  public.rpc_reservation_details(bigint),
  public.rpc_dashboard_stats(),
  public.rpc_set_staff(uuid, text, boolean, text),
  public.rpc_report_agent_performance(date, date)
  to authenticated;

-- Everything else (audit_write, notify_*, zh_*, trigger functions, private.*)
-- is internal and not callable from the website.
