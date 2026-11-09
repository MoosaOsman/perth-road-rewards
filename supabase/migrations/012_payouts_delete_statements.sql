-- Perth Road Rewards — payout limits, POPIA deletion, company statements (9 Nov 2026)
-- 1. Owner: minimum payout R20 and no daily payout limit (for now). The daily
--    limit becomes optional: null = no limit. Defaults follow for new installs.
-- 2. POPIA deletion: a manager can delete a customer's personal information.
--    Name and mobile are erased, cards blocked and the customer marked
--    'deleted'; claims, payouts and the ledger stay (anonymised) for the books.
--    Only allowed with a zero balance and no pending claims.
-- 3. Company statement: approved claims and payouts of a company's drivers for a
--    date range (for invoicing or reporting to the company).
-- Recreated with the same signatures: api_payout, api_mgr_update_settings,
-- api_mgr_customer_update (refuses deleted customers).

-- ---------------------------------------------------------------- 1. limits
alter table public.settings drop constraint if exists settings_max_payout_day_cents_check;
alter table public.settings alter column max_payout_day_cents drop not null;
alter table public.settings add constraint settings_max_payout_day_cents_check
  check (max_payout_day_cents is null or max_payout_day_cents > 0);
alter table public.settings alter column max_payout_day_cents set default null;
alter table public.settings alter column min_payout_cents set default 2000;
update public.settings set min_payout_cents = 2000, max_payout_day_cents = null, updated_at = now() where id = 1;

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
    if cu.mobile is null or right(cu.mobile, 3) <> trim(coalesce(p_mobile_last3, '')) then
      perform _fail('MOBILE_CHECK', 'The last 3 digits of the mobile number do not match.');
    end if;
    v_bal := _balance(cu.id);
    if coalesce(p_amount_cents, 0) <= 0 then perform _fail('AMOUNT', 'Enter an amount.'); end if;
    if p_amount_cents < st.min_payout_cents then
      perform _fail('MIN', 'Minimum payout is R' || to_char(st.min_payout_cents / 100.0, 'FM999990.00') || '.');
    end if;
    if p_amount_cents > v_bal then perform _fail('BALANCE', 'Amount is more than the balance.'); end if;
    if st.max_payout_day_cents is not null then              -- null = no daily limit
      select coalesce(sum(amount_cents), 0) into v_paid from payouts
       where customer_id = cu.id and _local_day(created_at) = _local_day(now());
      if v_paid + p_amount_cents > st.max_payout_day_cents then
        perform _fail('DAY_LIMIT', 'Daily payout limit reached. Maximum still allowed today: R' ||
          to_char(greatest(st.max_payout_day_cents - v_paid, 0) / 100.0, 'FM999990.00') || '.');
      end if;
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

-- An empty or zero daily limit means no limit.
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
      max_payout_day_cents = case when p_settings ? 'max_payout_day_cents'
                                  then nullif((p_settings->>'max_payout_day_cents')::int, 0)
                                  else max_payout_day_cents end,
      default_cap_litres   = coalesce((p_settings->>'default_cap_litres')::numeric, default_cap_litres),
      max_litres_per_fill  = coalesce((p_settings->>'max_litres_per_fill')::numeric, max_litres_per_fill),
      claim_expiry_hours   = coalesce((p_settings->>'claim_expiry_hours')::int, claim_expiry_hours),
      updated_at = now()
    where id = 1;
    perform _audit((ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid, 'settings_changed', p_settings - 'pump_count');
    return _ok((select to_jsonb(s) from settings s where id = 1));
  exception
    when check_violation then return jsonb_build_object('ok', false, 'code', 'SETTINGS', 'message', 'One of the values is out of range.');
    when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

-- ---------------------------------------------------------------- 2. POPIA deletion
alter table public.customers alter column mobile drop not null;
alter table public.customers drop constraint if exists customers_mobile_check;
alter table public.customers add constraint customers_mobile_check check (mobile is null or mobile ~ '^0[0-9]{9}$');
alter table public.customers drop constraint if exists customers_status_check;
alter table public.customers add constraint customers_status_check check (status in ('active','suspended','deleted'));
alter table public.customers add column deleted_at timestamptz;

create or replace function public.api_mgr_customer_delete(p_token text, p_staff uuid, p_pin text, p_customer uuid, p_note text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; cu record; v_bal int;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  begin
    select * into cu from customers where id = p_customer for update;
    if not found then perform _fail('NOT_FOUND', 'Customer not found.'); end if;
    if cu.status = 'deleted' then perform _fail('DELETED', 'This customer has already been deleted.'); end if;
    v_bal := _balance(cu.id);
    if v_bal <> 0 then
      perform _fail('BALANCE', 'The balance is R' || to_char(v_bal / 100.0, 'FM999990.00')
        || '. Pay it out, or adjust it to zero with a note, before deleting.');
    end if;
    if exists (select 1 from claims where customer_id = cu.id and status = 'pending') then
      perform _fail('PENDING', 'This customer has pending claims. Have them approved or rejected first.');
    end if;
    if length(trim(coalesce(p_note, ''))) < 3 then perform _fail('NOTE', 'Record who asked and when (for example “Customer request at kiosk, 9 Nov”).'); end if;
    update cards set status = 'blocked', blocked_at = coalesce(blocked_at, now()), blocked_by = coalesce(blocked_by, (ctx->>'staff_id')::uuid),
                     block_reason = 'Customer deleted (POPIA)'
     where customer_id = cu.id and status = 'active';
    update customers set full_name = 'Deleted customer', mobile = null, notes = null, company_id = null,
                         daily_cap_litres = null, status = 'deleted', deleted_at = now()
     where id = cu.id;
    -- the audit entry holds no personal information
    perform _audit((ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid, 'customer_deleted',
      jsonb_build_object('customer_id', cu.id, 'note', trim(p_note)));
    return _ok();
  exception when others then return _err_json(SQLSTATE, SQLERRM);
  end;
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
    if exists (select 1 from customers where id = p_customer and status = 'deleted') then
      perform _fail('DELETED', 'This customer was deleted and cannot be edited.');
    end if;
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

-- ---------------------------------------------------------------- 3. company statement
-- Approved claims (by fill date) and payouts of the company's current drivers.
create or replace function public.api_mgr_company_statement(
  p_token text, p_staff uuid, p_pin text, p_company uuid, p_from date, p_to date)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; co record;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  select * into co from companies where id = p_company;
  if not found then return jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Company not found.'); end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    return jsonb_build_object('ok', false, 'code', 'RANGE', 'message', 'Choose a date range of up to one year.');
  end if;
  return _ok(jsonb_build_object(
    'company', jsonb_build_object('id', co.id, 'name', co.name, 'notes', co.notes),
    'from', p_from, 'to', p_to,
    'claims', (select coalesce(jsonb_agg(jsonb_build_object('at', cl.captured_at, 'driver', cu.full_name,
        'card', ca.uid, 'pump', cl.pump_no, 'grade', cl.grade_code, 'litres', cl.litres,
        'rate', cl.rate_cents_per_litre, 'cashback_cents', cl.cashback_cents, 'receipt', cl.namos_receipt_no)
        order by cl.captured_at), '[]')
      from claims cl join customers cu on cu.id = cl.customer_id join cards ca on ca.id = cl.card_id
      where cu.company_id = co.id and cl.status = 'approved' and _local_day(cl.captured_at) between p_from and p_to),
    'payouts', (select coalesce(jsonb_agg(jsonb_build_object('at', p.created_at, 'driver', cu.full_name,
        'amount_cents', p.amount_cents, 'namos_ref', p.namos_paidout_ref) order by p.created_at), '[]')
      from payouts p join customers cu on cu.id = p.customer_id
      where cu.company_id = co.id and _local_day(p.created_at) between p_from and p_to),
    'balances', (select coalesce(jsonb_agg(jsonb_build_object('driver', cu.full_name, 'balance_cents', _balance(cu.id))
        order by cu.full_name), '[]') from customers cu where cu.company_id = co.id)));
end $$;
