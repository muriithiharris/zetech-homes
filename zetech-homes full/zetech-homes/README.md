# Zetech Homes: setup guide (Supabase + HTML/CSS/JavaScript)

No Python, no XAMPP, no server of your own. The website is plain HTML, CSS and
JavaScript. Supabase provides the PostgreSQL database, staff login, photo
storage and the security rules.

## 1. Create the Supabase project (5 minutes)

1. Go to supabase.com, sign in, click **New project**.
2. Name it `zetech-homes`, choose the region closest to Kenya (for example
   Europe/Frankfurt or Middle East if offered), set a database password and
   **save it somewhere safe**.
3. Wait about two minutes until the project says it is ready.

## 2. Close public sign-up (important)

Every new Supabase user automatically becomes an active *agent* (that is how
staff accounts are created). So nobody outside your agency may be allowed to
register themselves.

**Authentication > Sign In / Providers > Email**: switch **off** "Allow new
users to sign up". Staff are added by you in step 4. (Menu names can differ
slightly between dashboard versions.)

## 3. Build the database

Open **SQL Editor > New query**. For each file below: open it from the
`supabase/` folder, copy the whole text, paste it, press **Run**. Wait for
"Success" before the next one. Keep this order:

| Order | File | What it creates |
|---|---|---|
| 1 | `01_schema.sql` | tables, constraints, indexes |
| 2 | `02_logic.sql` | integrity triggers, encryption, the functions the website calls |
| 3 | `03_security.sql` | public views and row-level security |
| 4 | `04_lookup_data.sql` | counties, sub-counties, property types |
| 5 | (create staff, step 4) | |
| 6 | `05_demo_data.sql` | OPTIONAL: 30 demo listings (needs step 4 first) |
| 7 | `06_storage.sql` | photo bucket and upload rules |

If you later add or change functions, run `03_security.sql` again last so they
stay locked down.

## 4. Create staff accounts and the first manager

1. **Authentication > Users > Add user > Create new user**. Enter an email and
   password and **tick "Auto Confirm User"**. Repeat for each agent.
2. Make yourself the manager: SQL Editor, run (with your email):

```sql
update public.staff set role = 'MANAGER' where email = 'you@example.com';
```

After that, managers promote or deactivate people from the website, never by
editing tables.

Now run `05_demo_data.sql` if you want sample listings.

## 5. Connect the website

**Project Settings > API**. Copy the **Project URL** and the **anon** key (or
the newer **publishable** key) into `web/config.js`:

```js
window.ZH_CONFIG = {
  SUPABASE_URL: "https://abcdefghijkl.supabase.co",
  SUPABASE_KEY: "eyJ...your anon key...",
};
```

Never use the `service_role` or `secret` key in the website. The anon key is
meant to be public because the database rules decide what it may do.

## 6. Open the site while you build

The pages use JavaScript modules, which browsers refuse to run from a
`file://` address. In VS Code install the **Live Server** extension, right-click
`web/index.html` and choose **Open with Live Server**.

## 7. Check the database works

In the SQL Editor:

```sql
select count(*) from public.public_listings;               -- what customers see
select * from public.audit_log order by id desc limit 5;   -- the audit trail
```

Then try to break the rules, as your project report should show:

```sql
-- must fail: the audit log is immutable
delete from public.audit_log;
-- must fail: listings are never deleted
delete from public.properties;
```

## How your objectives map to the code

| Objective | Where |
|---|---|
| No duplicate records | `lr_number` UNIQUE + CHECK (01); DuplicateGuard in `rpc_create_property` (02) |
| No silent overwrites (lost updates) | `version` column; every update is `WHERE id = ? AND version = ?`; trigger `trg_properties_guard` checks it again (02) |
| Illegal status changes blocked | `trg_properties_guard`: only Available > Reserved > Sold; Sold is final |
| Nothing is silently erased | no hard delete (trigger); soft delete via `archived_at`; audit log is append-only (`trg_audit_immutable`) |
| Reports managers can trust | `rpc_dashboard_stats`, `integrity_issues`, `rpc_report_agent_performance`, readable `audit_log` |
| Sensitive data encrypted | client phone and ID encrypted with pgcrypto (`private.pii_encrypt`) |
| Role-based access | `staff.role`, row-level security (03), role checks inside each function |

## Tests (optional, run on your own PostgreSQL, not on Supabase)

`tests/` contains 78 automated checks and a two-session race test that were
used to verify these files. They need a local PostgreSQL; they are not part of
the Supabase setup.

## Pages
Customer: `web/index.html` (browse), `property.html` (details + viewing request), `status.html` (check by LR).
Staff (`web/staff/`): `login`, `index` (dashboard), `properties`, `property-form` (add/edit), `status` (change status), `viewing`, `notifications`.
Manager only: `audit`, `reports`, `users`.
Open `web/index.html` with VS Code Live Server (not by double-clicking).
