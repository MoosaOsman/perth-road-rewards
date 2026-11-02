-- Perth Road Rewards — manager functions (manager device + manager PIN only)

create or replace function public._mgr(p_token text, p_staff uuid, p_pin text)
returns jsonb language sql security definer set search_path = public, extensions as $$
  select _auth(p_token, p_staff, p_pin, array['manager'], array['manager']);
$$;

create or replace function public.api_mgr_dashboard(p_token text, p_staff uuid, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; v_today date := _local_day(now());
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  perform _expire_claims();
  return _ok(jsonb_build_object(
    'liability_cents', (select coalesce(sum(amount_cents),0) from ledger),
    'customers', (select count(*) from customers),
    'active_cards', (select count(*) from cards where status = 'active'),
    'pending', (select count(*) from claims where status = 'pending'),
    'days', (select jsonb_agg(jsonb_build_object(
        'day', d,
        'litres', (select coalesce(sum(litres),0) from claims where status='approved' and _local_day(captured_at) = d),
        'earned_cents', (select coalesce(sum(cashback_cents),0) from claims where status='approved' and _local_day(captured_at) = d),
        'approved', (select count(*) from claims where status='approved' and _local_day(captured_at) = d),
        'rejected', (select count(*) from claims where status='rejected' and _local_day(captured_at) = d),
        'expired', (select count(*) from claims where status='expired' and _local_day(captured_at) = d),
        'payout_cents', (select coalesce(sum(amount_cents),0) from payouts where _local_day(created_at) = d)
      ) order by d desc)
      from (select gs::date d from generate_series(v_today - 6, v_today, interval '1 day') gs) x),
    'attendants', (select coalesce(jsonb_agg(row_to_json(a)), '[]') from (
        select s.full_name as name,
          count(*) as claims,
          count(*) filter (where cl.status='approved') as approved,
          count(*) filter (where cl.status='rejected') as rejected,
          count(*) filter (where cl.status='expired') as expired,
          count(*) filter (where not cl.pin_verified) as offline_unverified,
          coalesce(sum(cl.litres) filter (where cl.status='approved'),0) as approved_litres
        from claims cl join staff s on s.id = cl.created_by
        where _local_day(cl.captured_at) > v_today - 7
        group by s.full_name order by s.full_name) a)));
end $$;

create or replace function public.api_mgr_set_rate(p_token text, p_staff uuid, p_pin text, p_grade text, p_cents numeric)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  begin
    if p_cents is null or p_cents < 0 or p_cents > 500 then
      perform _fail('RATE', 'Rate must be between 0 and 500 cents per litre.');
    end if;
    if p_grade is not null and not exists (select 1 from fuel_grades where code = p_grade) then
      perform _fail('GRADE', 'Unknown grade.');
    end if;
    insert into earn_rates (grade_code, cents_per_litre, set_by)
      select code, round(p_cents, 2), (ctx->>'staff_id')::uuid from fuel_grades
       where active and (p_grade is null or code = p_grade);
    perform _audit((ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid, 'rate_changed',
      jsonb_build_object('grade', coalesce(p_grade, 'ALL'), 'cents_per_litre', p_cents));
    return _ok(jsonb_build_object('grades', (select jsonb_agg(jsonb_build_object('code', code, 'name', name,
      'rate', _current_rate(code)) order by sort_order) from fuel_grades where active)));
  exception when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

create or replace function public.api_mgr_rates_history(p_token text, p_staff uuid, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  return _ok(jsonb_build_object('history', (select coalesce(jsonb_agg(jsonb_build_object(
    'grade', r.grade_code, 'cents_per_litre', r.cents_per_litre, 'from', r.effective_from, 'by', s.full_name)
    order by r.effective_from desc, r.id desc), '[]')
    from (select * from earn_rates order by effective_from desc, id desc limit 200) r
    left join staff s on s.id = r.set_by)));
end $$;

create or replace function public.api_mgr_update_settings(p_token text, p_staff uuid, p_pin text, p_settings jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  begin
    update settings set
      scheme_name          = coalesce(nullif(trim(p_settings->>'scheme_name'),''), scheme_name),
      min_payout_cents     = coalesce((p_settings->>'min_payout_cents')::int, min_payout_cents),
      max_payout_day_cents = coalesce((p_settings->>'max_payout_day_cents')::int, max_payout_day_cents),
      default_cap_litres   = coalesce((p_settings->>'default_cap_litres')::numeric, default_cap_litres),
      max_litres_per_fill  = coalesce((p_settings->>'max_litres_per_fill')::numeric, max_litres_per_fill),
      claim_expiry_hours   = coalesce((p_settings->>'claim_expiry_hours')::int, claim_expiry_hours),
      pump_count           = coalesce((p_settings->>'pump_count')::int, pump_count),
      updated_at = now()
    where id = 1;
    perform _audit((ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid, 'settings_changed', p_settings);
    return _ok((select to_jsonb(s) from settings s where id = 1));
  exception
    when check_violation then return jsonb_build_object('ok', false, 'code', 'SETTINGS', 'message', 'One of the values is out of range.');
    when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

create or replace function public.api_mgr_staff_list(p_token text, p_staff uuid, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  return _ok(jsonb_build_object('staff', (select coalesce(jsonb_agg(jsonb_build_object(
    'id', id, 'name', full_name, 'role', role, 'active', active,
    'locked', locked_until is not null and locked_until > now(), 'created_at', created_at)
    order by active desc, role, full_name), '[]') from staff)));
end $$;

create or replace function public.api_mgr_staff_save(
  p_token text, p_staff uuid, p_pin text, p_id uuid, p_name text, p_role text, p_new_pin text, p_active boolean)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; v_id uuid;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  begin
    if p_role not in ('attendant','cashier','manager') then perform _fail('ROLE', 'Choose a role.'); end if;
    if length(trim(coalesce(p_name,''))) = 0 then perform _fail('NAME', 'Enter a name.'); end if;
    if p_new_pin is not null and not _valid_pin(p_new_pin) then perform _fail('PIN_FORMAT', 'PIN must be 4 to 6 digits.'); end if;
    if p_id is null then
      if p_new_pin is null then perform _fail('PIN_FORMAT', 'A new staff member needs a PIN.'); end if;
      insert into staff (full_name, role, pin_hash, active)
        values (trim(p_name), p_role, crypt(p_new_pin, gen_salt('bf', 8)), coalesce(p_active, true))
        returning id into v_id;
    else
      if p_id = (ctx->>'staff_id')::uuid and (coalesce(p_active, true) = false or p_role <> 'manager') then
        perform _fail('SELF', 'You cannot deactivate or demote yourself.');
      end if;
      update staff set full_name = trim(p_name), role = p_role, active = coalesce(p_active, active),
        pin_hash = case when p_new_pin is not null then crypt(p_new_pin, gen_salt('bf', 8)) else pin_hash end,
        failed_attempts = case when p_new_pin is not null then 0 else failed_attempts end,
        locked_until = case when p_new_pin is not null then null else locked_until end
       where id = p_id returning id into v_id;
      if v_id is null then perform _fail('NOT_FOUND', 'Staff member not found.'); end if;
    end if;
    perform _audit((ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid, 'staff_saved',
      jsonb_build_object('id', v_id, 'name', trim(p_name), 'role', p_role, 'active', p_active,
                         'pin_changed', p_new_pin is not null));
    return _ok(jsonb_build_object('id', v_id));
  exception when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

create or replace function public.api_mgr_devices(p_token text, p_staff uuid, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  return _ok(jsonb_build_object('devices', (select coalesce(jsonb_agg(jsonb_build_object(
    'id', id, 'name', name, 'kind', kind, 'active', active, 'paired', token_hash is not null,
    'pairing_code', case when pairing_expires > now() then pairing_code end,
    'pairing_expires', pairing_expires, 'last_seen', last_seen,
    'this_device', id = (ctx->>'device_id')::uuid)
    order by active desc, kind, name), '[]') from devices)));
end $$;

create or replace function public.api_mgr_device_create(p_token text, p_staff uuid, p_pin text, p_name text, p_kind text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; v_code text; v_id uuid;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  begin
    if p_kind not in ('forecourt','kiosk','manager') then perform _fail('KIND', 'Choose a device type.'); end if;
    if length(trim(coalesce(p_name,''))) = 0 then perform _fail('NAME', 'Name the device.'); end if;
    v_code := upper(substr(translate(encode(gen_random_bytes(12), 'base64'), '+/=0O1IL', ''), 1, 8));
    insert into devices (name, kind, pairing_code, pairing_expires)
      values (trim(p_name), p_kind, v_code, now() + interval '24 hours') returning id into v_id;
    perform _audit((ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid, 'device_created',
      jsonb_build_object('id', v_id, 'name', p_name, 'kind', p_kind));
    return _ok(jsonb_build_object('id', v_id, 'pairing_code', v_code));
  exception when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

-- p_action: 'disable' | 'enable' | 'repair' (new pairing code; old token stops working)
create or replace function public.api_mgr_device_action(p_token text, p_staff uuid, p_pin text, p_id uuid, p_action text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; v_code text;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  begin
    if p_id = (ctx->>'device_id')::uuid and p_action in ('disable','repair') then
      perform _fail('SELF', 'You cannot disable or re-pair the device you are using.');
    end if;
    if p_action = 'disable' then
      update devices set active = false where id = p_id;
    elsif p_action = 'enable' then
      update devices set active = true where id = p_id;
    elsif p_action = 'repair' then
      v_code := upper(substr(translate(encode(gen_random_bytes(12), 'base64'), '+/=0O1IL', ''), 1, 8));
      update devices set token_hash = null, pairing_code = v_code,
                         pairing_expires = now() + interval '24 hours', active = true where id = p_id;
    else
      perform _fail('ACTION', 'Unknown action.');
    end if;
    perform _audit((ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid, 'device_' || p_action,
      jsonb_build_object('id', p_id));
    return _ok(jsonb_build_object('pairing_code', v_code));
  exception when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

create or replace function public.api_mgr_customers(p_token text, p_staff uuid, p_pin text, p_search text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; v_q text := '%' || lower(trim(coalesce(p_search,''))) || '%';
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  return _ok(jsonb_build_object('customers', (select coalesce(jsonb_agg(x order by x->>'name'), '[]') from (
    select jsonb_build_object('id', cu.id, 'name', cu.full_name, 'mobile', cu.mobile, 'status', cu.status,
      'cap', cu.daily_cap_litres, 'balance_cents', _balance(cu.id),
      'cards', (select coalesce(jsonb_agg(jsonb_build_object('uid', uid, 'status', status)), '[]') from cards where customer_id = cu.id),
      'last_claim', (select max(captured_at) from claims where customer_id = cu.id)) x
    from customers cu
    where lower(cu.full_name) like v_q or cu.mobile like v_q
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
    'customer', (select jsonb_build_object('id', id, 'name', full_name, 'mobile', mobile, 'status', status,
       'cap', daily_cap_litres, 'notes', notes, 'consent_at', popia_consent_at, 'created_at', created_at,
       'balance_cents', _balance(id)) from customers where id = p_customer),
    'cards', (select coalesce(jsonb_agg(jsonb_build_object('uid', uid, 'status', status, 'issued_at', issued_at,
       'block_reason', block_reason) order by issued_at desc), '[]') from cards where customer_id = p_customer),
    'ledger', (select coalesce(jsonb_agg(jsonb_build_object('at', l.created_at, 'type', l.entry_type,
       'amount_cents', l.amount_cents, 'note', l.note, 'by', s.full_name,
       'receipt', cl.namos_receipt_no, 'litres', cl.litres, 'grade', cl.grade_code) order by l.created_at desc), '[]')
       from (select * from ledger where customer_id = p_customer order by created_at desc limit 300) l
       left join staff s on s.id = l.staff_id left join claims cl on cl.id = l.claim_id),
    'claims', (select coalesce(jsonb_agg(jsonb_build_object('at', cl.captured_at, 'status', cl.status,
       'litres', cl.litres, 'grade', cl.grade_code, 'pump', cl.pump_no, 'cashback_cents', cl.cashback_cents,
       'attendant', s.full_name, 'reject_reason', cl.reject_reason) order by cl.captured_at desc), '[]')
       from (select * from claims where customer_id = p_customer order by captured_at desc limit 100) cl
       left join staff s on s.id = cl.created_by)));
end $$;

create or replace function public.api_mgr_customer_update(
  p_token text, p_staff uuid, p_pin text, p_customer uuid, p_name text, p_mobile text,
  p_cap numeric, p_status text, p_notes text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; v_mobile text := _norm_mobile(p_mobile);
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  begin
    if v_mobile !~ '^0[0-9]{9}$' then perform _fail('MOBILE', 'Enter a valid 10-digit SA mobile number.'); end if;
    if p_status not in ('active','suspended') then perform _fail('STATUS', 'Invalid status.'); end if;
    if p_cap is not null and p_cap <= 0 then perform _fail('CAP', 'Cap must be more than 0 (leave blank for the default).'); end if;
    update customers set full_name = trim(p_name), mobile = v_mobile, daily_cap_litres = p_cap,
                         status = p_status, notes = nullif(trim(coalesce(p_notes,'')),'')
     where id = p_customer;
    if not found then perform _fail('NOT_FOUND', 'Customer not found.'); end if;
    perform _audit((ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid, 'customer_updated',
      jsonb_build_object('customer_id', p_customer, 'cap', p_cap, 'status', p_status));
    return _ok();
  exception when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

create or replace function public.api_mgr_adjust(
  p_token text, p_staff uuid, p_pin text, p_customer uuid, p_amount_cents int, p_note text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; v_bal int;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  begin
    perform 1 from customers where id = p_customer for update;
    if not found then perform _fail('NOT_FOUND', 'Customer not found.'); end if;
    if coalesce(p_amount_cents, 0) = 0 then perform _fail('AMOUNT', 'Enter a non-zero amount.'); end if;
    if length(trim(coalesce(p_note,''))) < 3 then perform _fail('NOTE', 'A note explaining the adjustment is required.'); end if;
    v_bal := _balance(p_customer);
    if v_bal + p_amount_cents < 0 then perform _fail('NEGATIVE', 'Adjustment would make the balance negative.'); end if;
    insert into ledger (customer_id, entry_type, amount_cents, staff_id, note)
      values (p_customer, 'adjust', p_amount_cents, (ctx->>'staff_id')::uuid, trim(p_note));
    perform _audit((ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid, 'balance_adjusted',
      jsonb_build_object('customer_id', p_customer, 'amount_cents', p_amount_cents, 'note', p_note));
    return _ok(jsonb_build_object('balance_cents', _balance(p_customer)));
  exception when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

create or replace function public.api_mgr_report(p_token text, p_staff uuid, p_pin text, p_from date, p_to date)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    return jsonb_build_object('ok', false, 'code', 'RANGE', 'message', 'Choose a date range of up to one year.');
  end if;
  perform _expire_claims();
  return _ok(jsonb_build_object(
    'by_day', (select coalesce(jsonb_agg(jsonb_build_object('day', d,
        'approved', (select count(*) from claims where status='approved' and _local_day(captured_at)=d),
        'litres', (select coalesce(sum(litres),0) from claims where status='approved' and _local_day(captured_at)=d),
        'earned_cents', (select coalesce(sum(cashback_cents),0) from claims where status='approved' and _local_day(captured_at)=d),
        'rejected', (select count(*) from claims where status='rejected' and _local_day(captured_at)=d),
        'expired', (select count(*) from claims where status='expired' and _local_day(captured_at)=d),
        'payouts', (select count(*) from payouts where _local_day(created_at)=d),
        'payout_cents', (select coalesce(sum(amount_cents),0) from payouts where _local_day(created_at)=d),
        'adjust_cents', (select coalesce(sum(amount_cents),0) from ledger where entry_type='adjust' and _local_day(created_at)=d))
        order by d), '[]')
      from (select gs::date d from generate_series(p_from, p_to, interval '1 day') gs) days),
    'by_grade', (select coalesce(jsonb_agg(row_to_json(g)), '[]') from (
        select grade_code as grade, count(*) as approved, sum(litres) as litres, sum(cashback_cents) as earned_cents
        from claims where status='approved' and _local_day(captured_at) between p_from and p_to
        group by grade_code order by grade_code) g),
    'by_attendant', (select coalesce(jsonb_agg(row_to_json(a)), '[]') from (
        select s.full_name as name, count(*) as claims,
          count(*) filter (where cl.status='approved') as approved,
          count(*) filter (where cl.status='rejected') as rejected,
          count(*) filter (where cl.status='expired') as expired,
          count(*) filter (where not cl.pin_verified) as offline_unverified,
          coalesce(sum(cl.litres) filter (where cl.status='approved'),0) as approved_litres
        from claims cl join staff s on s.id = cl.created_by
        where _local_day(cl.captured_at) between p_from and p_to
        group by s.full_name order by s.full_name) a),
    'by_cashier', (select coalesce(jsonb_agg(row_to_json(c)), '[]') from (
        select s.full_name as name,
          (select count(*) from claims where decided_by = s.id and status='approved' and _local_day(decided_at) between p_from and p_to) as approved,
          (select count(*) from claims where decided_by = s.id and status='rejected' and _local_day(decided_at) between p_from and p_to) as rejected,
          (select count(*) from payouts where staff_id = s.id and _local_day(created_at) between p_from and p_to) as payouts,
          (select coalesce(sum(amount_cents),0) from payouts where staff_id = s.id and _local_day(created_at) between p_from and p_to) as payout_cents
        from staff s where s.role in ('cashier','manager') order by s.full_name) c),
    'claims', (select coalesce(jsonb_agg(jsonb_build_object('captured_at', cl.captured_at, 'status', cl.status,
        'pump', cl.pump_no, 'grade', cl.grade_code, 'litres', cl.litres, 'rate', cl.rate_cents_per_litre,
        'cashback_cents', cl.cashback_cents, 'customer', cu.full_name, 'card', ca.uid,
        'attendant', sa.full_name, 'pin_verified', cl.pin_verified, 'decided_by', sd.full_name,
        'decided_at', cl.decided_at, 'receipt', cl.namos_receipt_no, 'reject_reason', cl.reject_reason)
        order by cl.captured_at), '[]')
      from claims cl join customers cu on cu.id = cl.customer_id join cards ca on ca.id = cl.card_id
      left join staff sa on sa.id = cl.created_by left join staff sd on sd.id = cl.decided_by
      where _local_day(cl.captured_at) between p_from and p_to),
    'payouts', (select coalesce(jsonb_agg(jsonb_build_object('at', p.created_at, 'amount_cents', p.amount_cents,
        'customer', cu.full_name, 'card', ca.uid, 'cashier', s.full_name, 'namos_ref', p.namos_paidout_ref)
        order by p.created_at), '[]')
      from payouts p join customers cu on cu.id = p.customer_id join cards ca on ca.id = p.card_id
      join staff s on s.id = p.staff_id
      where _local_day(p.created_at) between p_from and p_to)));
end $$;

create or replace function public.api_mgr_audit(p_token text, p_staff uuid, p_pin text, p_limit int)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  return _ok(jsonb_build_object('entries', (select coalesce(jsonb_agg(jsonb_build_object(
    'at', a.at, 'action', a.action, 'staff', s.full_name, 'device', d.name, 'detail', a.detail)
    order by a.at desc), '[]')
    from (select * from audit_log order by at desc limit least(greatest(coalesce(p_limit, 200), 1), 1000)) a
    left join staff s on s.id = a.staff_id left join devices d on d.id = a.device_id)));
end $$;

-- ---------------------------------------------------------------- permissions
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and (p.proname like 'api\_%' or p.proname like '\_%')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.proname like 'api\_%' then
      execute format('grant execute on function %s to anon, authenticated', f.sig);
    end if;
  end loop;
end $$;
