-- Perth Road Rewards — pump set-up (7 Nov 2026)
-- The manager sets once which grade(s) each pump dispenses and which pumps are
-- in use. The forecourt then asks only for the pump: a pump with one grade fills
-- the grade in itself; a multi-grade pump offers only its own grades.
-- A pump with no set-up row behaves as before (any active grade).
-- api_bootstrap and api_claim_create are recreated with the same signatures.
-- The site sells three grades only (owner, 7 Nov 2026): Diesel 500ppm is switched
-- off (kept, not deleted, so its rate history stays; it had no claims).

update public.fuel_grades set active = false where code = 'D500';

create table public.pumps (
  pump_no    int primary key check (pump_no between 1 and 40),
  grades     text[] not null default '{}',
  active     boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.pumps enable row level security;
revoke all on public.pumps from anon, authenticated;

create or replace function public.api_bootstrap(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; v_roles text[];
begin
  ctx := _auth(p_token, null, null, null, array['forecourt','kiosk','manager']);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  v_roles := case ctx->>'device_kind'
               when 'forecourt' then array['attendant','manager']
               when 'kiosk' then array['cashier','manager']
               else array['manager'] end;
  return _ok(jsonb_build_object(
    'device', jsonb_build_object('id', ctx->'device_id', 'kind', ctx->'device_kind', 'name', ctx->'device_name'),
    'settings', (select to_jsonb(s) from settings s where id = 1),
    'grades', (select coalesce(jsonb_agg(jsonb_build_object('code', g.code, 'name', g.name,
                  'rate', _current_rate(g.code)) order by g.sort_order), '[]') from fuel_grades g where g.active),
    'pumps', (select coalesce(jsonb_agg(jsonb_build_object('pump', p.pump_no, 'grades', to_jsonb(p.grades), 'active', p.active)
                  order by p.pump_no), '[]') from pumps p),
    'staff', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.full_name, 'role', s.role)
                  order by s.full_name), '[]') from staff s where s.active and s.role = any(v_roles))));
end $$;

-- Save the whole pump set-up. p_pumps: [{pump, grades: [codes], active}]
create or replace function public.api_mgr_pumps_save(p_token text, p_staff uuid, p_pin text, p_pumps jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; st record; x jsonb; v_n int; v_grades text[]; v_bad text;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  begin
    select * into st from settings where id = 1;
    if jsonb_typeof(p_pumps) <> 'array' then perform _fail('PUMPS', 'Nothing to save.'); end if;
    delete from pumps where pump_no is not null;   -- safeupdate needs a WHERE
    for x in select * from jsonb_array_elements(p_pumps) loop
      v_n := (x->>'pump')::int;
      if v_n is null or v_n < 1 or v_n > st.pump_count then
        perform _fail('PUMP', 'Pump ' || coalesce(x->>'pump', '?') || ' is outside 1–' || st.pump_count || '.');
      end if;
      select coalesce(array_agg(distinct g), '{}') into v_grades from jsonb_array_elements_text(coalesce(x->'grades', '[]')) g;
      select g into v_bad from unnest(v_grades) g where not exists (select 1 from fuel_grades f where f.code = g and f.active) limit 1;
      if v_bad is not null then perform _fail('GRADE', 'Unknown fuel grade ' || v_bad || ' on pump ' || v_n || '.'); end if;
      if coalesce((x->>'active')::boolean, true) and cardinality(v_grades) = 0 then
        perform _fail('NO_GRADE', 'Choose at least one grade for pump ' || v_n || ', or mark it not in use.');
      end if;
      insert into pumps (pump_no, grades, active) values (v_n, v_grades, coalesce((x->>'active')::boolean, true));
    end loop;
    perform _audit((ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid, 'pumps_changed', p_pumps);
    return _ok(jsonb_build_object('pumps', (select coalesce(jsonb_agg(jsonb_build_object('pump', pump_no,
      'grades', to_jsonb(grades), 'active', active) order by pump_no), '[]') from pumps)));
  exception when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

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

    v_rate := coalesce(_current_rate(p_grade), 0);
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
