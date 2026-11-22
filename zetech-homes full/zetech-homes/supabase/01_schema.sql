-- =====================================================================
-- ZETECH HOMES  |  Step 1 of 6  |  Tables and constraints
-- Run this first in the Supabase SQL Editor (new empty project).
--
-- NOTE: this file was RECONSTRUCTED on 2026-11-04 after the original was
-- accidentally overwritten. It was rebuilt from what 02_logic.sql,
-- 03_security.sql, 04/05/06 and the tests require, and it passes the full
-- test suite in /tests (see the end of this header). Compare it with any
-- copy you saved earlier before relying on it for your documentation.
--
-- The rules live INSIDE the database:
--   * UNIQUE, canonical LR numbers      * price must be > 0
--   * a sub-county must belong to its county (composite foreign key)
--   * one ACTIVE reservation per property (partial unique index)
--   * version tag for optimistic concurrency (checked by triggers in 02)
--   * append-only audit log (triggers in 02)
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- Staff: one row per Supabase Auth user (created automatically, see 02)
-- ---------------------------------------------------------------------
create table public.staff (
  id         uuid primary key references auth.users (id) on delete cascade,
  staff_no   integer generated always as identity unique,      -- shown as AGT-0001 / MGR-0001
  full_name  text    not null default '',
  email      text,
  phone      text    check (phone is null or phone ~ '^(\+254|0)[17][0-9]{8}$'),
  role       text    not null default 'AGENT' check (role in ('AGENT', 'MANAGER')),
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);
comment on table public.staff is
  'Staff accounts. The role is stored here (RBAC) and can only be changed by a manager through rpc_set_staff.';

-- ---------------------------------------------------------------------
-- Lookup lists
-- ---------------------------------------------------------------------
create table public.counties (
  id   integer generated always as identity primary key,
  name text not null unique
);

create table public.sub_counties (
  id        integer generated always as identity primary key,
  county_id integer not null references public.counties (id),
  name      text    not null,
  unique (county_id, name),
  unique (id, county_id)                 -- lets properties prove sub-county belongs to county
);

create table public.property_types (
  id   integer generated always as identity primary key,
  name text not null unique
);

-- ---------------------------------------------------------------------
-- Listings
-- ---------------------------------------------------------------------
create table public.properties (
  id               bigint generated always as identity primary key,
  lr_number        text   not null unique
                     check (lr_number ~ '^LR/[0-9]{4}/[0-9]{3,6}$'),   -- canonical, uppercase
  title            text   not null check (length(trim(title)) >= 3),
  property_type_id integer not null references public.property_types (id),
  price            numeric(14, 2) not null check (price > 0),
  county_id        integer not null,
  sub_county_id    integer not null,
  location         text   not null check (length(trim(location)) >= 1),
  description      text   not null default '',
  bedrooms         smallint not null default 0 check (bedrooms between 0 and 50),
  bathrooms        smallint not null default 0 check (bathrooms between 0 and 50),
  status           text   not null default 'AVAILABLE'
                     check (status in ('AVAILABLE', 'RESERVED', 'SOLD')),
  version          integer not null default 1 check (version >= 1),   -- optimistic-lock "version tag"
  agent_id         uuid   not null references public.staff (id),
  updated_by       uuid   references public.staff (id),
  updated_ip       inet,
  archived_at      timestamptz,                                       -- soft delete
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  foreign key (county_id) references public.counties (id),
  -- the sub-county MUST belong to the chosen county (checked by the database itself)
  foreign key (sub_county_id, county_id) references public.sub_counties (id, county_id)
);
create index properties_status_idx   on public.properties (status) where archived_at is null;
create index properties_price_idx    on public.properties (price);
create index properties_county_idx   on public.properties (county_id, status);
create index properties_agent_idx    on public.properties (agent_id);

create table public.property_images (
  id          bigint generated always as identity primary key,
  property_id bigint not null references public.properties (id),
  path        text   not null,                      -- file path inside the 'property-images' bucket
  is_primary  boolean not null default false,
  created_at  timestamptz not null default now()
);
create index property_images_property_idx on public.property_images (property_id);
create unique index one_primary_image_per_property on public.property_images (property_id) where is_primary;

-- ---------------------------------------------------------------------
-- Buyers and reservations (phone + ID are stored ENCRYPTED, see 02)
-- ---------------------------------------------------------------------
create table public.clients (
  id            bigint generated always as identity primary key,
  full_name     text  not null,
  phone_enc     bytea not null,
  id_number_enc bytea not null,
  created_at    timestamptz not null default now()
);

create table public.reservations (
  id          bigint generated always as identity primary key,
  property_id bigint not null references public.properties (id),
  client_id   bigint not null references public.clients (id),
  fee         numeric(12, 2) not null check (fee >= 0),
  status      text   not null default 'ACTIVE' check (status in ('ACTIVE', 'CANCELLED', 'COMPLETED')),
  created_by  uuid   not null references public.staff (id),
  created_at  timestamptz not null default now(),
  closed_at   timestamptz
);
-- A property can never have two live reservations, whatever the code does.
create unique index one_active_reservation_per_property
  on public.reservations (property_id) where status = 'ACTIVE';

-- ---------------------------------------------------------------------
-- Customer requests and staff notifications
-- ---------------------------------------------------------------------
create table public.viewing_requests (
  id             bigint generated always as identity primary key,
  property_id    bigint not null references public.properties (id),
  kind           text   not null default 'VISIT' check (kind in ('VISIT', 'WAITLIST')),
  name           text   not null check (length(trim(name)) >= 2),
  phone          text   not null check (phone ~ '^(\+254|0)[17][0-9]{8}$'),
  email          text   check (email is null or email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  preferred_date date,
  message        text   not null default '' check (length(message) <= 1000),
  handled        boolean not null default false,
  created_at     timestamptz not null default now()
);
create index viewing_requests_property_idx on public.viewing_requests (property_id);

create table public.notifications (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.staff (id) on delete cascade,
  message    text not null,
  link       text not null default '',
  is_read    boolean not null default false,
  created_at timestamptz not null default now()
);
create index notifications_user_idx on public.notifications (user_id, is_read);

-- ---------------------------------------------------------------------
-- Security trail
-- ---------------------------------------------------------------------
create table public.audit_log (
  id         bigint generated always as identity primary key,
  user_id    uuid references public.staff (id),
  target_lr  text not null default '',
  action     text not null check (action in (
               'INSERT_ENTRY', 'STATUS_UPDATE', 'PRICE_EDIT', 'DETAILS_EDIT', 'ARCHIVE',
               'DUPLICATE_BLOCKED', 'MVCC_CONFLICT', 'LOGIN')),
  old_value  text not null default '',
  new_value  text not null default '',
  ip_address inet,
  created_at timestamptz not null default now()
);
create index audit_log_created_idx on public.audit_log (created_at desc);
create index audit_log_action_idx  on public.audit_log (action);
create index audit_log_lr_idx      on public.audit_log (target_lr);

create table public.login_sessions (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.staff (id) on delete cascade,
  ip_address inet,
  started_at timestamptz not null default now(),
  ended_at   timestamptz
);
create index login_sessions_user_idx on public.login_sessions (user_id, started_at desc);
