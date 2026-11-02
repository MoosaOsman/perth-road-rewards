-- Perth Road Rewards — schema
-- All tables have RLS enabled and NO policies: the browser (anon key) cannot read
-- or write tables directly. Every action goes through SECURITY DEFINER functions
-- in 002_functions.sql, which check the device token and staff PIN.

create extension if not exists pgcrypto with schema extensions;

create table public.settings (
  id                     int primary key default 1 check (id = 1),
  scheme_name            text    not null default 'Perth Road Rewards',
  min_payout_cents       int     not null default 5000  check (min_payout_cents >= 0),
  max_payout_day_cents   int     not null default 100000 check (max_payout_day_cents > 0),
  default_cap_litres     numeric(7,2) not null default 150 check (default_cap_litres > 0),
  max_litres_per_fill    numeric(7,2) not null default 200 check (max_litres_per_fill > 0),
  claim_expiry_hours     int     not null default 14 check (claim_expiry_hours between 1 and 72),
  pump_count             int     not null default 8 check (pump_count between 1 and 40),
  max_pin_attempts       int     not null default 5,
  lockout_minutes        int     not null default 15,
  updated_at             timestamptz not null default now()
);
insert into public.settings (id) values (1);

create table public.fuel_grades (
  code       text primary key,
  name       text not null,
  sort_order int  not null default 0,
  active     boolean not null default true
);
insert into public.fuel_grades (code, name, sort_order) values
  ('ULP93', 'Unleaded 93', 1),
  ('ULP95', 'Unleaded 95', 2),
  ('D50',   'Diesel 50ppm', 3),
  ('D500',  'Diesel 500ppm', 4);

create table public.staff (
  id               uuid primary key default gen_random_uuid(),
  full_name        text not null check (length(trim(full_name)) > 0),
  role             text not null check (role in ('attendant','cashier','manager')),
  pin_hash         text not null,
  active           boolean not null default true,
  failed_attempts  int not null default 0,
  locked_until     timestamptz,
  created_at       timestamptz not null default now()
);

create table public.devices (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  kind          text not null check (kind in ('forecourt','kiosk','manager')),
  token_hash    text unique,
  pairing_code  text unique,
  pairing_expires timestamptz,
  active        boolean not null default true,
  last_seen     timestamptz,
  created_at    timestamptz not null default now()
);

create table public.earn_rates (
  id               bigint generated always as identity primary key,
  grade_code       text not null references public.fuel_grades(code),
  cents_per_litre  numeric(6,2) not null check (cents_per_litre >= 0 and cents_per_litre <= 500),
  effective_from   timestamptz not null default now(),
  set_by           uuid references public.staff(id)
);
create index on public.earn_rates (grade_code, effective_from desc);
insert into public.earn_rates (grade_code, cents_per_litre)
  select code, 10 from public.fuel_grades;

create table public.customers (
  id                uuid primary key default gen_random_uuid(),
  full_name         text not null check (length(trim(full_name)) > 0),
  mobile            text not null check (mobile ~ '^0[0-9]{9}$'),
  popia_consent_at  timestamptz not null,
  daily_cap_litres  numeric(7,2) check (daily_cap_litres > 0),
  status            text not null default 'active' check (status in ('active','suspended')),
  notes             text,
  created_by        uuid references public.staff(id),
  created_at        timestamptz not null default now()
);
create unique index customers_mobile_uq on public.customers (mobile);

create table public.cards (
  id           uuid primary key default gen_random_uuid(),
  uid          text not null unique check (uid ~ '^[0-9A-Z]{4,32}$'),
  customer_id  uuid not null references public.customers(id),
  status       text not null default 'active' check (status in ('active','blocked')),
  issued_at    timestamptz not null default now(),
  issued_by    uuid references public.staff(id),
  blocked_at   timestamptz,
  blocked_by   uuid references public.staff(id),
  block_reason text
);
create index on public.cards (customer_id);

create table public.claims (
  id                  uuid primary key default gen_random_uuid(),
  client_ref          uuid not null unique,
  card_id             uuid not null references public.cards(id),
  customer_id         uuid not null references public.customers(id),
  pump_no             int  not null check (pump_no > 0),
  grade_code          text not null references public.fuel_grades(code),
  litres              numeric(7,2) not null check (litres > 0),
  rate_cents_per_litre numeric(6,2) not null,
  cashback_cents      int not null check (cashback_cents >= 0),
  status              text not null default 'pending'
                       check (status in ('pending','approved','rejected','expired')),
  created_by          uuid references public.staff(id),
  created_device      uuid references public.devices(id),
  pin_verified        boolean not null default true,
  captured_at         timestamptz not null default now(),
  created_at          timestamptz not null default now(),
  decided_by          uuid references public.staff(id),
  decided_device      uuid references public.devices(id),
  decided_at          timestamptz,
  namos_receipt_no    text,
  reject_reason       text
);
create index on public.claims (status, created_at);
create index on public.claims (customer_id, created_at);
create unique index claims_receipt_uq on public.claims (upper(namos_receipt_no))
  where status = 'approved';

create table public.payouts (
  id              uuid primary key default gen_random_uuid(),
  customer_id     uuid not null references public.customers(id),
  card_id         uuid not null references public.cards(id),
  amount_cents    int not null check (amount_cents > 0),
  namos_paidout_ref text,
  staff_id        uuid not null references public.staff(id),
  device_id       uuid references public.devices(id),
  created_at      timestamptz not null default now()
);
create index on public.payouts (customer_id, created_at);

create table public.ledger (
  id            bigint generated always as identity primary key,
  customer_id   uuid not null references public.customers(id),
  entry_type    text not null check (entry_type in ('earn','payout','adjust')),
  amount_cents  int not null,
  claim_id      uuid references public.claims(id),
  payout_id     uuid references public.payouts(id),
  staff_id      uuid references public.staff(id),
  note          text,
  created_at    timestamptz not null default now()
);
create index on public.ledger (customer_id);
create unique index ledger_claim_uq on public.ledger (claim_id) where claim_id is not null;

create table public.audit_log (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  staff_id   uuid references public.staff(id),
  device_id  uuid references public.devices(id),
  action     text not null,
  detail     jsonb
);
create index on public.audit_log (at desc);

alter table public.settings     enable row level security;
alter table public.fuel_grades  enable row level security;
alter table public.staff        enable row level security;
alter table public.devices      enable row level security;
alter table public.earn_rates   enable row level security;
alter table public.customers    enable row level security;
alter table public.cards        enable row level security;
alter table public.claims       enable row level security;
alter table public.payouts      enable row level security;
alter table public.ledger       enable row level security;
alter table public.audit_log    enable row level security;

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
