-- Perth Road Rewards — API functions
-- Every public function is prefixed api_ and returns jsonb:
--   { "ok": true,  "data": ... }   or   { "ok": false, "code": "...", "message": "..." }
-- Business-rule failures are returned (not raised) so that PIN-failure counters
-- and audit rows are kept. Inner work runs in a sub-block that rolls back on error.

-- ---------------------------------------------------------------- helpers
create or replace function public._fail(p_code text, p_msg text)
returns void language plpgsql as $$
begin
  raise exception using errcode = 'P0001', message = p_code || '|' || p_msg;
end $$;

create or replace function public._err_json(p_sqlstate text, p_sqlerrm text)
returns jsonb language plpgsql immutable as $$
begin
  if p_sqlstate = 'P0001' and position('|' in p_sqlerrm) > 0 then
    return jsonb_build_object('ok', false,
      'code', split_part(p_sqlerrm, '|', 1),
      'message', substr(p_sqlerrm, position('|' in p_sqlerrm) + 1));
  elsif p_sqlstate = '23505' then
    return jsonb_build_object('ok', false, 'code', 'DUPLICATE',
      'message', 'That record already exists (duplicate value).');
  end if;
  return jsonb_build_object('ok', false, 'code', 'SERVER',
    'message', 'Unexpected error: ' || p_sqlerrm);
end $$;

create or replace function public._ok(p_data jsonb default '{}'::jsonb)
returns jsonb language sql immutable as $$
  select jsonb_build_object('ok', true, 'data', coalesce(p_data, '{}'::jsonb));
$$;

create or replace function public._hash_token(p_token text)
returns text language sql immutable as $$
  select encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex');
$$;

create or replace function public._local_day(p_ts timestamptz)
returns date language sql immutable as $$
  select (p_ts at time zone 'Africa/Johannesburg')::date;
$$;

create or replace function public._norm_uid(p_uid text)
returns text language sql immutable as $$
  select upper(regexp_replace(coalesce(p_uid,''), '[^0-9A-Za-z]', '', 'g'));
$$;

create or replace function public._norm_mobile(p_mobile text)
returns text language plpgsql immutable as $$
declare m text := regexp_replace(coalesce(p_mobile,''), '[^0-9+]', '', 'g');
begin
  if m like '+27%' then m := '0' || substr(m, 4);
  elsif m like '27%' and length(m) = 11 then m := '0' || substr(m, 3);
  end if;
  return m;
end $$;

create or replace function public._balance(p_customer uuid)
returns int language sql stable as $$
  select coalesce(sum(amount_cents), 0)::int from public.ledger where customer_id = p_customer;
$$;

create or replace function public._current_rate(p_grade text)
returns numeric language sql stable as $$
  select cents_per_litre from public.earn_rates
   where grade_code = p_grade and effective_from <= now()
   order by effective_from desc, id desc limit 1;
$$;

create or replace function public._audit(p_staff uuid, p_device uuid, p_action text, p_detail jsonb)
returns void language sql as $$
  insert into public.audit_log (staff_id, device_id, action, detail)
  values (p_staff, p_device, p_action, p_detail);
$$;

create or replace function public._valid_pin(p_pin text)
returns boolean language sql immutable as $$
  select coalesce(p_pin, '') ~ '^[0-9]{4,6}$';
$$;

-- Authenticate device (+ optionally staff). Returns ctx jsonb with ok flag.
create or replace function public._auth(
  p_token text, p_staff uuid, p_pin text, p_roles text[], p_kinds text[],
  p_require_pin boolean default true)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare d record; s record; st record;
begin
  select * into st from settings where id = 1;
  select * into d from devices where token_hash = _hash_token(p_token) and token_hash is not null;
  if not found or not d.active then
    return jsonb_build_object('ok', false, 'code', 'DEVICE',
      'message', 'This tablet is not registered or has been disabled. Ask the manager to pair it.');
  end if;
  if not (d.kind = any(p_kinds)) then
    return jsonb_build_object('ok', false, 'code', 'DEVICE_KIND',
      'message', 'This action is not allowed on a ' || d.kind || ' tablet.');
  end if;
  update devices set last_seen = now() where id = d.id;

  if p_staff is null then
    return jsonb_build_object('ok', true, 'device_id', d.id, 'device_kind', d.kind, 'device_name', d.name);
  end if;

  select * into s from staff where id = p_staff for update;
  if not found or not s.active then
    return jsonb_build_object('ok', false, 'code', 'STAFF', 'message', 'Staff member not found or inactive.');
  end if;
  if not (s.role = any(p_roles)) then
    return jsonb_build_object('ok', false, 'code', 'ROLE',
      'message', s.full_name || ' (' || s.role || ') is not allowed to do this.');
  end if;
  if s.locked_until is not null and s.locked_until > now() then
    return jsonb_build_object('ok', false, 'code', 'LOCKED',
      'message', 'Too many wrong PINs. Locked until ' ||
        to_char(s.locked_until at time zone 'Africa/Johannesburg', 'HH24:MI') || '.');
  end if;

  if p_require_pin then
    if p_pin is null or crypt(p_pin, s.pin_hash) <> s.pin_hash then
      update staff set failed_attempts = failed_attempts + 1,
        locked_until = case when failed_attempts + 1 >= st.max_pin_attempts
                            then now() + make_interval(mins => st.lockout_minutes) else locked_until end
       where id = s.id;
      perform _audit(s.id, d.id, 'pin_failed', jsonb_build_object('attempt', s.failed_attempts + 1));
      return jsonb_build_object('ok', false, 'code', 'PIN', 'message', 'Wrong PIN.');
    end if;
    if s.failed_attempts > 0 or s.locked_until is not null then
      update staff set failed_attempts = 0, locked_until = null where id = s.id;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'device_id', d.id, 'device_kind', d.kind, 'device_name', d.name,
    'staff_id', s.id, 'staff_role', s.role, 'staff_name', s.full_name);
end $$;

-- ---------------------------------------------------------------- setup & pairing
create or replace function public.api_setup_status()
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  return _ok(jsonb_build_object(
    'needs_setup', not exists (select 1 from staff),
    'scheme_name', (select scheme_name from settings where id = 1)));
end $$;

create or replace function public.api_setup_first_manager(p_name text, p_pin text, p_device_name text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_staff uuid; v_dev uuid; v_token text;
begin
  begin
    lock table staff in exclusive mode;
    if exists (select 1 from staff) then
      perform _fail('SETUP_DONE', 'Setup has already been completed. Ask the manager to pair this device.');
    end if;
    if not _valid_pin(p_pin) then perform _fail('PIN_FORMAT', 'PIN must be 4 to 6 digits.'); end if;
    if length(trim(coalesce(p_name,''))) = 0 then perform _fail('NAME', 'Enter your name.'); end if;
    insert into staff (full_name, role, pin_hash)
      values (trim(p_name), 'manager', crypt(p_pin, gen_salt('bf', 8))) returning id into v_staff;
    v_token := encode(gen_random_bytes(32), 'hex');
    insert into devices (name, kind, token_hash)
      values (coalesce(nullif(trim(p_device_name),''), 'Manager device'), 'manager', _hash_token(v_token))
      returning id into v_dev;
    perform _audit(v_staff, v_dev, 'setup_first_manager', jsonb_build_object('name', trim(p_name)));
    return _ok(jsonb_build_object('token', v_token, 'kind', 'manager'));
  exception when others then
    return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

create or replace function public.api_pair_device(p_code text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare d record; v_token text;
begin
  select * into d from devices
   where pairing_code = upper(trim(coalesce(p_code,''))) and active for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'PAIR', 'message', 'Pairing code not recognised.');
  end if;
  if d.pairing_expires < now() then
    return jsonb_build_object('ok', false, 'code', 'PAIR_EXPIRED',
      'message', 'Pairing code has expired. Ask the manager for a new one.');
  end if;
  v_token := encode(gen_random_bytes(32), 'hex');
  update devices set token_hash = _hash_token(v_token), pairing_code = null, pairing_expires = null,
                     last_seen = now()
   where id = d.id;
  perform _audit(null, d.id, 'device_paired', jsonb_build_object('name', d.name, 'kind', d.kind));
  return _ok(jsonb_build_object('token', v_token, 'kind', d.kind, 'name', d.name));
end $$;

-- Everything a tablet needs on start-up (no PIN needed: names only).
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
    'staff', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.full_name, 'role', s.role)
                  order by s.full_name), '[]') from staff s where s.active and s.role = any(v_roles))));
end $$;

-- Verify a PIN without doing anything (used to sign in to a tablet session).
create or replace function public.api_sign_in(p_token text, p_staff uuid, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb;
begin
  ctx := _auth(p_token, p_staff, p_pin, array['attendant','cashier','manager'],
               array['forecourt','kiosk','manager']);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  if (ctx->>'device_kind' = 'forecourt' and ctx->>'staff_role' not in ('attendant','manager'))
     or (ctx->>'device_kind' = 'kiosk' and ctx->>'staff_role' not in ('cashier','manager'))
     or (ctx->>'device_kind' = 'manager' and ctx->>'staff_role' <> 'manager') then
    return jsonb_build_object('ok', false, 'code', 'ROLE', 'message', 'You cannot sign in on this tablet.');
  end if;
  return _ok(jsonb_build_object('name', ctx->>'staff_name', 'role', ctx->>'staff_role'));
end $$;

-- ---------------------------------------------------------------- cards & customers
create or replace function public._card_info(p_uid text, p_full boolean)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare c record; cu record; st record; v_today numeric; v_cap numeric; v_paid int;
begin
  select * into st from settings where id = 1;
  select * into c from cards where uid = _norm_uid(p_uid);
  if not found then
    perform _fail('CARD_UNKNOWN', 'This card is not registered. Register it at the kiosk.');
  end if;
  select * into cu from customers where id = c.customer_id;
  select coalesce(sum(litres), 0) into v_today from claims
   where customer_id = cu.id and status in ('pending','approved')
     and _local_day(captured_at) = _local_day(now());
  select coalesce(sum(amount_cents), 0) into v_paid from payouts
   where customer_id = cu.id and _local_day(created_at) = _local_day(now());
  v_cap := coalesce(cu.daily_cap_litres, st.default_cap_litres);
  return jsonb_build_object(
    'card_uid', c.uid, 'card_status', c.status, 'block_reason', c.block_reason,
    'customer_id', cu.id, 'customer_name', cu.full_name, 'customer_status', cu.status,
    'mobile_masked', '*******' || right(cu.mobile, 3),
    'litres_today', v_today, 'cap_litres', v_cap, 'litres_remaining', greatest(v_cap - v_today, 0),
    'balance_cents', case when p_full then _balance(cu.id) end,
    'paid_out_today_cents', case when p_full then v_paid end,
    'min_payout_cents', st.min_payout_cents,
    'max_payout_day_cents', st.max_payout_day_cents);
end $$;

create or replace function public.api_card_lookup(p_token text, p_staff uuid, p_pin text, p_uid text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb;
begin
  ctx := _auth(p_token, p_staff, p_pin, array['attendant','cashier','manager'], array['forecourt','kiosk','manager']);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  begin
    return _ok(_card_info(p_uid, ctx->>'device_kind' <> 'forecourt'));
  exception when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

create or replace function public.api_customer_register(
  p_token text, p_staff uuid, p_pin text, p_name text, p_mobile text, p_consent boolean, p_uid text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; v_cust uuid; v_mobile text := _norm_mobile(p_mobile); v_uid text := _norm_uid(p_uid);
begin
  ctx := _auth(p_token, p_staff, p_pin, array['cashier','manager'], array['kiosk','manager']);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  begin
    if coalesce(p_consent, false) is false then
      perform _fail('CONSENT', 'The customer must give POPIA consent before registering.');
    end if;
    if length(trim(coalesce(p_name,''))) < 2 then perform _fail('NAME', 'Enter the customer''s name.'); end if;
    if v_mobile !~ '^0[0-9]{9}$' then perform _fail('MOBILE', 'Enter a valid 10-digit SA mobile number.'); end if;
    if v_uid !~ '^[0-9A-Z]{4,32}$' then perform _fail('CARD', 'Card number not read correctly. Tap again.'); end if;
    if exists (select 1 from cards where uid = v_uid) then
      perform _fail('CARD_IN_USE', 'This card is already registered to a customer.');
    end if;
    if exists (select 1 from customers where mobile = v_mobile) then
      perform _fail('MOBILE_EXISTS', 'A customer with this mobile number already exists. Use "Replace card" instead.');
    end if;
    insert into customers (full_name, mobile, popia_consent_at, created_by)
      values (trim(p_name), v_mobile, now(), (ctx->>'staff_id')::uuid) returning id into v_cust;
    insert into cards (uid, customer_id, issued_by) values (v_uid, v_cust, (ctx->>'staff_id')::uuid);
    perform _audit((ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid, 'customer_registered',
      jsonb_build_object('customer_id', v_cust, 'card', v_uid));
    return _ok(_card_info(v_uid, true));
  exception when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

create or replace function public.api_card_replace(
  p_token text, p_staff uuid, p_pin text, p_mobile text, p_new_uid text, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; cu record; v_uid text := _norm_uid(p_new_uid);
begin
  ctx := _auth(p_token, p_staff, p_pin, array['cashier','manager'], array['kiosk','manager']);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  begin
    select * into cu from customers where mobile = _norm_mobile(p_mobile);
    if not found then perform _fail('NO_CUSTOMER', 'No customer with that mobile number.'); end if;
    if v_uid !~ '^[0-9A-Z]{4,32}$' then perform _fail('CARD', 'Card number not read correctly. Tap again.'); end if;
    if exists (select 1 from cards where uid = v_uid) then
      perform _fail('CARD_IN_USE', 'This new card is already registered.');
    end if;
    update cards set status = 'blocked', blocked_at = now(), blocked_by = (ctx->>'staff_id')::uuid,
                     block_reason = coalesce(nullif(trim(p_reason),''), 'Replaced')
     where customer_id = cu.id and status = 'active';
    insert into cards (uid, customer_id, issued_by) values (v_uid, cu.id, (ctx->>'staff_id')::uuid);
    perform _audit((ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid, 'card_replaced',
      jsonb_build_object('customer_id', cu.id, 'new_card', v_uid, 'reason', p_reason));
    return _ok(_card_info(v_uid, true));
  exception when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

create or replace function public.api_card_block(p_token text, p_staff uuid, p_pin text, p_uid text, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; c record;
begin
  ctx := _auth(p_token, p_staff, p_pin, array['cashier','manager'], array['kiosk','manager']);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  begin
    select * into c from cards where uid = _norm_uid(p_uid) for update;
    if not found then perform _fail('CARD_UNKNOWN', 'Card not found.'); end if;
    if c.status = 'blocked' then perform _fail('ALREADY', 'Card is already blocked.'); end if;
    update cards set status = 'blocked', blocked_at = now(), blocked_by = (ctx->>'staff_id')::uuid,
                     block_reason = coalesce(nullif(trim(p_reason),''), 'Blocked') where id = c.id;
    perform _audit((ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid, 'card_blocked',
      jsonb_build_object('card', c.uid, 'reason', p_reason));
    return _ok(jsonb_build_object('card_uid', c.uid));
  exception when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

-- ---------------------------------------------------------------- claims (forecourt)
create or replace function public.api_claim_create(
  p_token text, p_staff uuid, p_pin text, p_uid text, p_pump int, p_grade text, p_litres numeric,
  p_client_ref uuid, p_captured_at timestamptz default null, p_offline boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; st record; c record; cu record; ex record;
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

-- ---------------------------------------------------------------- claims (kiosk)
create or replace function public._expire_claims()
returns int language plpgsql security definer set search_path = public, extensions as $$
declare n int;
begin
  update claims set status = 'expired', decided_at = now()
   where status = 'pending'
     and created_at < now() - make_interval(hours => (select claim_expiry_hours from settings where id = 1));
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.api_claims_pending(p_token text, p_staff uuid, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb;
begin
  ctx := _auth(p_token, p_staff, p_pin, array['cashier','manager'], array['kiosk','manager']);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  perform _expire_claims();
  return _ok(jsonb_build_object('claims', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', cl.id, 'pump_no', cl.pump_no, 'grade', cl.grade_code, 'litres', cl.litres,
      'cashback_cents', cl.cashback_cents, 'captured_at', cl.captured_at,
      'customer_name', cu.full_name, 'card_last4', right(ca.uid, 4),
      'attendant', s.full_name, 'pin_verified', cl.pin_verified,
      'own_claim', cl.created_by = (ctx->>'staff_id')::uuid)
      order by cl.captured_at), '[]')
    from claims cl join customers cu on cu.id = cl.customer_id join cards ca on ca.id = cl.card_id
    left join staff s on s.id = cl.created_by
    where cl.status = 'pending')));
end $$;

create or replace function public.api_claim_decide(
  p_token text, p_staff uuid, p_pin text, p_claim uuid, p_approve boolean, p_receipt text, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; cl record; v_receipt text := upper(trim(coalesce(p_receipt, '')));
begin
  ctx := _auth(p_token, p_staff, p_pin, array['cashier','manager'], array['kiosk','manager']);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  perform _expire_claims();
  begin
    select * into cl from claims where id = p_claim for update;
    if not found then perform _fail('NOT_FOUND', 'Claim not found.'); end if;
    if cl.status <> 'pending' then perform _fail('NOT_PENDING', 'This claim is already ' || cl.status || '.'); end if;
    if cl.created_by = (ctx->>'staff_id')::uuid then
      perform _fail('OWN_CLAIM', 'You cannot approve or reject a claim you captured yourself.');
    end if;

    if p_approve then
      if v_receipt !~ '^[0-9A-Z/\-]{1,30}$' then
        perform _fail('RECEIPT', 'Enter the Namos receipt / transaction number from the till slip.');
      end if;
      if exists (select 1 from claims where status = 'approved' and upper(namos_receipt_no) = v_receipt) then
        perform _fail('RECEIPT_USED', 'This receipt number has already been used for another claim.');
      end if;
      if exists (select 1 from cards where id = cl.card_id and status <> 'active') then
        perform _fail('CARD_BLOCKED', 'The card has been blocked since this claim was captured. Reject it.');
      end if;
      update claims set status = 'approved', decided_by = (ctx->>'staff_id')::uuid,
             decided_device = (ctx->>'device_id')::uuid, decided_at = now(), namos_receipt_no = v_receipt
       where id = cl.id;
      insert into ledger (customer_id, entry_type, amount_cents, claim_id, staff_id)
        values (cl.customer_id, 'earn', cl.cashback_cents, cl.id, (ctx->>'staff_id')::uuid);
    else
      if length(trim(coalesce(p_reason, ''))) = 0 then perform _fail('REASON', 'Choose a reason for rejecting.'); end if;
      update claims set status = 'rejected', decided_by = (ctx->>'staff_id')::uuid,
             decided_device = (ctx->>'device_id')::uuid, decided_at = now(), reject_reason = trim(p_reason)
       where id = cl.id;
    end if;
    return _ok(jsonb_build_object('claim_id', cl.id, 'status', case when p_approve then 'approved' else 'rejected' end,
      'balance_cents', _balance(cl.customer_id)));
  exception when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

-- ---------------------------------------------------------------- payouts (kiosk)
create or replace function public.api_payout(
  p_token text, p_staff uuid, p_pin text, p_uid text, p_amount_cents int, p_mobile_last3 text, p_namos_ref text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; st record; c record; cu record; v_bal int; v_paid int; v_id uuid;
begin
  ctx := _auth(p_token, p_staff, p_pin, array['cashier','manager'], array['kiosk','manager']);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  begin
    select * into st from settings where id = 1;
    select * into c from cards where uid = _norm_uid(p_uid);
    if not found then perform _fail('CARD_UNKNOWN', 'Card not registered.'); end if;
    if c.status <> 'active' then perform _fail('CARD_BLOCKED', 'This card is blocked.'); end if;
    select * into cu from customers where id = c.customer_id for update;
    if cu.status <> 'active' then perform _fail('CUSTOMER_SUSPENDED', 'This customer account is suspended.'); end if;
    if right(cu.mobile, 3) <> trim(coalesce(p_mobile_last3, '')) then
      perform _fail('MOBILE_CHECK', 'The last 3 digits of the mobile number do not match.');
    end if;
    v_bal := _balance(cu.id);
    if coalesce(p_amount_cents, 0) <= 0 then perform _fail('AMOUNT', 'Enter an amount.'); end if;
    if p_amount_cents < st.min_payout_cents then
      perform _fail('MIN', 'Minimum payout is R' || to_char(st.min_payout_cents / 100.0, 'FM999990.00') || '.');
    end if;
    if p_amount_cents > v_bal then perform _fail('BALANCE', 'Amount is more than the balance.'); end if;
    select coalesce(sum(amount_cents), 0) into v_paid from payouts
     where customer_id = cu.id and _local_day(created_at) = _local_day(now());
    if v_paid + p_amount_cents > st.max_payout_day_cents then
      perform _fail('DAY_LIMIT', 'Daily payout limit reached. Maximum still allowed today: R' ||
        to_char(greatest(st.max_payout_day_cents - v_paid, 0) / 100.0, 'FM999990.00') || '.');
    end if;
    insert into payouts (customer_id, card_id, amount_cents, namos_paidout_ref, staff_id, device_id)
      values (cu.id, c.id, p_amount_cents, nullif(trim(coalesce(p_namos_ref,'')),''),
              (ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid)
      returning id into v_id;
    insert into ledger (customer_id, entry_type, amount_cents, payout_id, staff_id)
      values (cu.id, 'payout', -p_amount_cents, v_id, (ctx->>'staff_id')::uuid);
    perform _audit((ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid, 'payout',
      jsonb_build_object('customer_id', cu.id, 'amount_cents', p_amount_cents, 'payout_id', v_id));
    return _ok(jsonb_build_object('payout_id', v_id, 'amount_cents', p_amount_cents,
      'balance_cents', _balance(cu.id), 'customer_name', cu.full_name));
  exception when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

create or replace function public.api_shift_summary(p_token text, p_staff uuid, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; v_me uuid; v_day date := _local_day(now());
begin
  ctx := _auth(p_token, p_staff, p_pin, array['cashier','manager'], array['kiosk','manager']);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  perform _expire_claims();
  v_me := (ctx->>'staff_id')::uuid;
  return _ok(jsonb_build_object(
    'day', v_day,
    'me', jsonb_build_object(
      'approved', (select count(*) from claims where decided_by = v_me and status = 'approved' and _local_day(decided_at) = v_day),
      'approved_cents', (select coalesce(sum(cashback_cents),0) from claims where decided_by = v_me and status = 'approved' and _local_day(decided_at) = v_day),
      'rejected', (select count(*) from claims where decided_by = v_me and status = 'rejected' and _local_day(decided_at) = v_day),
      'payouts', (select count(*) from payouts where staff_id = v_me and _local_day(created_at) = v_day),
      'payout_cents', (select coalesce(sum(amount_cents),0) from payouts where staff_id = v_me and _local_day(created_at) = v_day)),
    'site', jsonb_build_object(
      'approved', (select count(*) from claims where status = 'approved' and _local_day(decided_at) = v_day),
      'approved_litres', (select coalesce(sum(litres),0) from claims where status = 'approved' and _local_day(decided_at) = v_day),
      'approved_cents', (select coalesce(sum(cashback_cents),0) from claims where status = 'approved' and _local_day(decided_at) = v_day),
      'pending', (select count(*) from claims where status = 'pending'),
      'expired', (select count(*) from claims where status = 'expired' and _local_day(decided_at) = v_day),
      'payouts', (select count(*) from payouts where _local_day(created_at) = v_day),
      'payout_cents', (select coalesce(sum(amount_cents),0) from payouts where _local_day(created_at) = v_day)),
    'my_payouts', (select coalesce(jsonb_agg(jsonb_build_object('at', p.created_at, 'amount_cents', p.amount_cents,
        'customer', cu.full_name, 'namos_ref', p.namos_paidout_ref) order by p.created_at), '[]')
      from payouts p join customers cu on cu.id = p.customer_id
      where p.staff_id = v_me and _local_day(p.created_at) = v_day)));
end $$;
