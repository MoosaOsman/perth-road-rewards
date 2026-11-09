-- Perth Road Rewards — company accounts (9 Nov 2026)
-- A company (e.g. Atomic Demolishers) groups many customers (its drivers) and can
-- have its own cents-per-litre rate per grade. Owner's decisions:
--   * each driver keeps and collects their own balance (no pooled company balance);
--   * a grade with no company rate earns the standard rate.
-- Company rates keep a history like earn_rates; a row with a null rate means
-- "back to the standard rate". Claims use the rate in force when captured.
-- New: companies, company_rates, customers.company_id, _customer_rate, company API.
-- Recreated with the same signatures: _card_info (adds company and the customer's
-- rates), api_claim_create (company rate), api_mgr_customers, api_mgr_customer_detail.

create table public.companies (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) > 1),
  notes       text,
  active      boolean not null default true,
  created_by  uuid references public.staff(id),
  created_at  timestamptz not null default now()
);
create unique index companies_name_uq on public.companies (lower(trim(name)));
create index companies_created_by_idx on public.companies (created_by);

create table public.company_rates (
  id              bigint generated always as identity primary key,
  company_id      uuid not null references public.companies(id),
  grade_code      text not null references public.fuel_grades(code),
  cents_per_litre numeric(6,2) check (cents_per_litre is null or (cents_per_litre >= 0 and cents_per_litre <= 500)),
  effective_from  timestamptz not null default now(),
  set_by          uuid references public.staff(id)
);
create index company_rates_lookup_idx on public.company_rates (company_id, grade_code, effective_from desc);
create index company_rates_grade_idx on public.company_rates (grade_code);
create index company_rates_set_by_idx on public.company_rates (set_by);

alter table public.customers add column company_id uuid references public.companies(id);
create index customers_company_id_idx on public.customers (company_id);

alter table public.companies     enable row level security;
alter table public.company_rates enable row level security;
revoke all on public.companies, public.company_rates from anon, authenticated;

-- The company's rate for a grade now, or null when it has none (or reverted).
create or replace function public._company_rate(p_company uuid, p_grade text)
returns numeric language sql stable set search_path = public, extensions as $$
  select cents_per_litre from company_rates
   where company_id = p_company and grade_code = p_grade and effective_from <= now()
   order by effective_from desc, id desc limit 1;
$$;

-- The rate a customer earns on a grade: their active company's rate, else standard.
create or replace function public._customer_rate(p_customer uuid, p_grade text)
returns numeric language sql stable set search_path = public, extensions as $$
  select coalesce(
    (select _company_rate(co.id, p_grade) from customers cu join companies co on co.id = cu.company_id and co.active
      where cu.id = p_customer),
    _current_rate(p_grade));
$$;
revoke all on function public._company_rate(uuid, text) from public, anon, authenticated;
revoke all on function public._customer_rate(uuid, text) from public, anon, authenticated;

create or replace function public._card_info(p_uid text, p_full boolean)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare c record; cu record; st record; v_today numeric; v_cap numeric; v_paid int; v_company text;
begin
  select * into st from settings where id = 1;
  select * into c from cards where uid = _norm_uid(p_uid);
  if not found then
    perform _fail('CARD_UNKNOWN', 'This card is not registered. Register it at the kiosk.');
  end if;
  select * into cu from customers where id = c.customer_id;
  select name into v_company from companies where id = cu.company_id and active;
  select coalesce(sum(litres), 0) into v_today from claims
   where customer_id = cu.id and status in ('pending','approved')
     and _local_day(captured_at) = _local_day(now());
  select coalesce(sum(amount_cents), 0) into v_paid from payouts
   where customer_id = cu.id and _local_day(created_at) = _local_day(now());
  v_cap := coalesce(cu.daily_cap_litres, st.default_cap_litres);
  return jsonb_build_object(
    'card_uid', c.uid, 'card_status', c.status, 'block_reason', c.block_reason,
    'customer_id', cu.id, 'customer_name', cu.full_name, 'customer_status', cu.status,
    'company', v_company,
    'rates', (select coalesce(jsonb_object_agg(g.code, _customer_rate(cu.id, g.code)), '{}') from fuel_grades g where g.active),
    'mobile_masked', left(cu.mobile, 3) || ' *** ****',
    'litres_today', v_today, 'cap_litres', v_cap, 'litres_remaining', greatest(v_cap - v_today, 0),
    'balance_cents', case when p_full then _balance(cu.id) end,
    'paid_out_today_cents', case when p_full then v_paid end,
    'min_payout_cents', st.min_payout_cents,
    'max_payout_day_cents', st.max_payout_day_cents);
end $$;
revoke all on function public._card_info(text, boolean) from public, anon, authenticated;

create or replace function public.api_claim_create(
  p_token text, p_staff uuid, p_pin text, p_uid text, p_pump int, p_grade text, p_litres numeric,
  p_client_ref uuid, p_captured_at timestamptz default null, p_offline boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; st record; c record; cu record; ex record; pu record;
        v_litres numeric := round(coalesce(p_litres, 0), 2); v_rate numeric; v_cap numeric;
        v_today numeric; v_at timestamptz; v_id uuid; v_verified boolean;
begin
  v_verified := not (coalesce(p_offline, false) and p_pin is null);
  ctx := _auth(p_token, p_staff, p_pin, array['attendant','manager'], array['forecourt','manager'], v_verified);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  begin
    select * into st from settings where id = 1;
    if p_client_ref is null then perform _fail('REF', 'Missing reference.'); end if;

    -- Idempotent: a retried offline submission returns the original claim.
    select * into ex from claims where client_ref = p_client_ref;
    if found then
      return _ok(jsonb_build_object('claim_id', ex.id, 'status', ex.status,
        'cashback_cents', ex.cashback_cents, 'repeat', true));
    end if;

    v_at := coalesce(p_captured_at, now());
    if v_at > now() + interval '5 minutes' then v_at := now(); end if;
    if v_at < now() - make_interval(hours => st.claim_expiry_hours) then
      perform _fail('TOO_OLD', 'This offline claim is too old to submit.');
    end if;

    select * into c from cards where uid = _norm_uid(p_uid);
    if not found then perform _fail('CARD_UNKNOWN', 'Card not registered. Send the customer to the kiosk.'); end if;
    if c.status <> 'active' then perform _fail('CARD_BLOCKED', 'This card is blocked.'); end if;
    select * into cu from customers where id = c.customer_id for update;
    if cu.status <> 'active' then perform _fail('CUSTOMER_SUSPENDED', 'This customer account is suspended.'); end if;

    if p_pump is null or p_pump < 1 or p_pump > st.pump_count then
      perform _fail('PUMP', 'Choose a valid pump number.');
    end if;
    if not exists (select 1 from fuel_grades where code = p_grade and active) then
      perform _fail('GRADE', 'Choose a valid fuel grade.');
    end if;
    select * into pu from pumps where pump_no = p_pump;
    if found then
      if not pu.active then perform _fail('PUMP_OFF', 'Pump ' || p_pump || ' is not in use.'); end if;
      if cardinality(pu.grades) > 0 and not (p_grade = any(pu.grades)) then
        perform _fail('PUMP_GRADE', 'Pump ' || p_pump || ' does not dispense ' || p_grade || '.');
      end if;
    end if;
    if v_litres <= 0 then perform _fail('LITRES', 'Enter the litres filled.'); end if;
    if v_litres > st.max_litres_per_fill then
      perform _fail('LITRES_MAX', 'More than ' || st.max_litres_per_fill || ' L in one fill is not allowed.');
    end if;

    if exists (select 1 from claims where card_id = c.id and pump_no = p_pump and grade_code = p_grade
                 and litres = v_litres and status in ('pending','approved')
                 and captured_at > v_at - interval '10 minutes' and captured_at < v_at + interval '10 minutes') then
      perform _fail('DUPLICATE_CLAIM', 'An identical claim for this card was just captured.');
    end if;

    v_cap := coalesce(cu.daily_cap_litres, st.default_cap_litres);
    select coalesce(sum(litres), 0) into v_today from claims
     where customer_id = cu.id and status in ('pending','approved')
       and _local_day(captured_at) = _local_day(v_at);
    if v_today + v_litres > v_cap then
      perform _fail('CAP', 'Daily limit reached: ' || greatest(v_cap - v_today, 0) || ' L left today (limit '
        || v_cap || ' L).');
    end if;

    v_rate := coalesce(_customer_rate(cu.id, p_grade), 0);   -- company rate, else standard
    insert into claims (client_ref, card_id, customer_id, pump_no, grade_code, litres,
                        rate_cents_per_litre, cashback_cents, created_by, created_device,
                        pin_verified, captured_at)
    values (p_client_ref, c.id, cu.id, p_pump, p_grade, v_litres, v_rate,
            round(v_litres * v_rate)::int, (ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid,
            v_verified, v_at)
    returning id into v_id;

    return _ok(jsonb_build_object('claim_id', v_id, 'status', 'pending',
      'cashback_cents', round(v_litres * v_rate)::int, 'customer_name', cu.full_name, 'repeat', false));
  exception when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

-- ---------------------------------------------------------------- manager: companies
create or replace function public.api_mgr_companies(p_token text, p_staff uuid, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  return _ok(jsonb_build_object('companies', (select coalesce(jsonb_agg(jsonb_build_object(
      'id', co.id, 'name', co.name, 'notes', co.notes, 'active', co.active, 'created_at', co.created_at,
      'drivers', (select count(*) from customers where company_id = co.id),
      'balance_cents', (select coalesce(sum(_balance(id)), 0) from customers where company_id = co.id),
      'rates', (select coalesce(jsonb_object_agg(g.code, _company_rate(co.id, g.code)), '{}') from fuel_grades g where g.active))
      order by co.active desc, lower(co.name)), '[]') from companies co)));
end $$;

create or replace function public.api_mgr_company_detail(p_token text, p_staff uuid, p_pin text, p_company uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; co record;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  select * into co from companies where id = p_company;
  if not found then return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Company not found.'); end if;
  return _ok(jsonb_build_object(
    'company', jsonb_build_object('id', co.id, 'name', co.name, 'notes', co.notes, 'active', co.active, 'created_at', co.created_at),
    'rates', (select coalesce(jsonb_agg(jsonb_build_object('grade', g.code, 'name', g.name,
                'company', _company_rate(co.id, g.code), 'standard', _current_rate(g.code)) order by g.sort_order), '[]')
              from fuel_grades g where g.active),
    'drivers', (select coalesce(jsonb_agg(jsonb_build_object('id', cu.id, 'name', cu.full_name, 'mobile', cu.mobile,
                'status', cu.status, 'balance_cents', _balance(cu.id),
                'litres_30d', (select coalesce(sum(litres), 0) from claims where customer_id = cu.id and status = 'approved'
                                 and captured_at > now() - interval '30 days'),
                'earned_30d', (select coalesce(sum(cashback_cents), 0) from claims where customer_id = cu.id and status = 'approved'
                                 and captured_at > now() - interval '30 days'),
                'last_claim', (select max(captured_at) from claims where customer_id = cu.id)) order by cu.full_name), '[]')
              from customers cu where cu.company_id = co.id),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('from', r.effective_from, 'grade', r.grade_code,
                'cents_per_litre', r.cents_per_litre, 'by', s.full_name) order by r.effective_from desc, r.id desc), '[]')
              from company_rates r left join staff s on s.id = r.set_by where r.company_id = co.id)));
end $$;

create or replace function public.api_mgr_company_save(
  p_token text, p_staff uuid, p_pin text, p_id uuid, p_name text, p_notes text, p_active boolean)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; v_id uuid := p_id;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  begin
    if length(trim(coalesce(p_name, ''))) < 2 then perform _fail('NAME', 'Enter the company name.'); end if;
    if exists (select 1 from companies where lower(trim(name)) = lower(trim(p_name)) and id is distinct from p_id) then
      perform _fail('NAME_EXISTS', 'A company with this name already exists.');
    end if;
    if v_id is null then
      insert into companies (name, notes, active, created_by)
        values (trim(p_name), nullif(trim(coalesce(p_notes, '')), ''), coalesce(p_active, true), (ctx->>'staff_id')::uuid)
        returning id into v_id;
    else
      update companies set name = trim(p_name), notes = nullif(trim(coalesce(p_notes, '')), ''), active = coalesce(p_active, true)
       where id = v_id;
      if not found then perform _fail('NOT_FOUND', 'Company not found.'); end if;
    end if;
    perform _audit((ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid, 'company_saved',
      jsonb_build_object('company_id', v_id, 'name', trim(p_name), 'active', coalesce(p_active, true)));
    return _ok(jsonb_build_object('id', v_id));
  exception when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

-- Set a company's rate for a grade. p_cents null = back to the standard rate.
create or replace function public.api_mgr_company_rate(
  p_token text, p_staff uuid, p_pin text, p_company uuid, p_grade text, p_cents numeric)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  begin
    if not exists (select 1 from companies where id = p_company) then perform _fail('NOT_FOUND', 'Company not found.'); end if;
    if not exists (select 1 from fuel_grades where code = p_grade and active) then perform _fail('GRADE', 'Unknown fuel grade.'); end if;
    if p_cents is not null and (p_cents < 0 or p_cents > 500) then
      perform _fail('RATE', 'Enter a rate between 0 and 500 cents per litre.');
    end if;
    insert into company_rates (company_id, grade_code, cents_per_litre, set_by)
      values (p_company, p_grade, p_cents, (ctx->>'staff_id')::uuid);
    perform _audit((ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid, 'company_rate_changed',
      jsonb_build_object('company_id', p_company, 'grade', p_grade, 'cents_per_litre', p_cents));
    return _ok();
  exception when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

-- Put a customer under a company, or take them out (p_company null).
create or replace function public.api_mgr_customer_set_company(
  p_token text, p_staff uuid, p_pin text, p_customer uuid, p_company uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  begin
    if p_company is not null and not exists (select 1 from companies where id = p_company) then
      perform _fail('NOT_FOUND', 'Company not found.');
    end if;
    update customers set company_id = p_company where id = p_customer;
    if not found then perform _fail('NOT_FOUND', 'Customer not found.'); end if;
    perform _audit((ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid, 'customer_company_changed',
      jsonb_build_object('customer_id', p_customer, 'company_id', p_company));
    return _ok();
  exception when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

-- Customer search and detail now include the company.
create or replace function public.api_mgr_customers(p_token text, p_staff uuid, p_pin text, p_search text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; v_q text := '%' || lower(trim(coalesce(p_search,''))) || '%';
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  return _ok(jsonb_build_object('customers', (select coalesce(jsonb_agg(x order by x->>'name'), '[]') from (
    select jsonb_build_object('id', cu.id, 'name', cu.full_name, 'mobile', cu.mobile, 'status', cu.status,
      'cap', cu.daily_cap_litres, 'balance_cents', _balance(cu.id), 'company', co.name,
      'cards', (select coalesce(jsonb_agg(jsonb_build_object('uid', uid, 'status', status)), '[]') from cards where customer_id = cu.id),
      'last_claim', (select max(captured_at) from claims where customer_id = cu.id)) x
    from customers cu left join companies co on co.id = cu.company_id
    where lower(cu.full_name) like v_q or cu.mobile like v_q or lower(coalesce(co.name, '')) like v_q
       or exists (select 1 from cards where customer_id = cu.id and lower(uid) like v_q)
    order by cu.full_name limit 200) q)));
end $$;

create or replace function public.api_mgr_customer_detail(p_token text, p_staff uuid, p_pin text, p_customer uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  return _ok(jsonb_build_object(
    'customer', (select jsonb_build_object('id', cu.id, 'name', cu.full_name, 'mobile', cu.mobile, 'status', cu.status,
       'cap', cu.daily_cap_litres, 'notes', cu.notes, 'consent_at', cu.popia_consent_at, 'created_at', cu.created_at,
       'balance_cents', _balance(cu.id), 'company_id', cu.company_id, 'company', co.name)
       from customers cu left join companies co on co.id = cu.company_id where cu.id = p_customer),
    'companies', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'active', active) order by lower(name)), '[]') from companies),
    'cards', (select coalesce(jsonb_agg(jsonb_build_object('uid', uid, 'status', status, 'issued_at', issued_at,
       'block_reason', block_reason) order by issued_at desc), '[]') from cards where customer_id = p_customer),
    'ledger', (select coalesce(jsonb_agg(jsonb_build_object('at', l.created_at, 'type', l.entry_type,
       'amount_cents', l.amount_cents, 'note', l.note, 'by', s.full_name,
       'receipt', cl.namos_receipt_no, 'litres', cl.litres, 'grade', cl.grade_code) order by l.created_at desc), '[]')
       from (select * from ledger where customer_id = p_customer order by created_at desc limit 300) l
       left join staff s on s.id = l.staff_id left join claims cl on cl.id = l.claim_id),
    'claims', (select coalesce(jsonb_agg(jsonb_build_object('at', cl.captured_at, 'status', cl.status,
       'litres', cl.litres, 'grade', cl.grade_code, 'pump', cl.pump_no, 'cashback_cents', cl.cashback_cents,
       'rate', cl.rate_cents_per_litre, 'attendant', s.full_name, 'reject_reason', cl.reject_reason) order by cl.captured_at desc), '[]')
       from (select * from claims where customer_id = p_customer order by captured_at desc limit 100) cl
       left join staff s on s.id = cl.created_by)));
end $$;
