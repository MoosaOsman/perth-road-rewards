-- End-to-end scenario test. Run against an EMPTY database (before real setup).
-- Results land in temp table t_results; all test data is wiped at the end.
create temp table t_results (n serial, step text, pass boolean, got jsonb);

do $$
declare
  r jsonb; mt text; ft text; kt text; mgr uuid; a uuid; b uuid; c uuid;
  code_f text; code_k text; cl1 uuid; cl_m uuid; cl_off uuid;
  procedure_ok boolean;
begin
  -- helper via local function-like pattern
  r := api_setup_status();
  insert into t_results(step, pass, got) values ('setup needed', (r->'data'->>'needs_setup')::boolean, r);

  r := api_setup_first_manager('Test Manager', '1234', 'Manager laptop');
  mt := r->'data'->>'token';
  insert into t_results(step, pass, got) values ('first manager', (r->>'ok')::boolean and mt is not null, r);
  select id into mgr from staff where full_name = 'Test Manager';

  r := api_setup_first_manager('Intruder', '9999', 'x');
  insert into t_results(step, pass, got) values ('second setup blocked', r->>'code' = 'SETUP_DONE', r);

  r := api_mgr_staff_save(mt, mgr, '1234', null, 'Att A', 'attendant', '1111', true); a := (r->'data'->>'id')::uuid;
  r := api_mgr_staff_save(mt, mgr, '1234', null, 'Att B', 'attendant', '2222', true); b := (r->'data'->>'id')::uuid;
  r := api_mgr_staff_save(mt, mgr, '1234', null, 'Cash C', 'cashier', '3333', true); c := (r->'data'->>'id')::uuid;
  insert into t_results(step, pass, got) values ('staff created', a is not null and b is not null and c is not null, r);

  r := api_mgr_staff_save(mt, mgr, '1234', null, 'Bad Pin', 'cashier', '12', true);
  insert into t_results(step, pass, got) values ('bad pin format', r->>'code' = 'PIN_FORMAT', r);

  r := api_mgr_device_create(mt, mgr, '1234', 'Forecourt 1', 'forecourt'); code_f := r->'data'->>'pairing_code';
  r := api_mgr_device_create(mt, mgr, '1234', 'Kiosk', 'kiosk'); code_k := r->'data'->>'pairing_code';
  r := api_pair_device(lower(code_f)); ft := r->'data'->>'token';
  insert into t_results(step, pass, got) values ('pair forecourt (lowercase code)', ft is not null, r);
  r := api_pair_device(code_k); kt := r->'data'->>'token';
  r := api_pair_device(code_k);
  insert into t_results(step, pass, got) values ('pairing code single-use', r->>'code' = 'PAIR', r);

  r := api_bootstrap(ft);
  insert into t_results(step, pass, got) values ('forecourt staff list = attendants+manager',
    jsonb_array_length(r->'data'->'staff') = 3 and not (r->'data'->'staff' @> jsonb_build_array(jsonb_build_object('name','Cash C'))), r);

  r := api_sign_in(kt, a, '1111');
  insert into t_results(step, pass, got) values ('attendant cannot sign in on kiosk', r->>'code' = 'ROLE', r);

  r := api_bootstrap('not-a-token');
  insert into t_results(step, pass, got) values ('bad token rejected', r->>'code' = 'DEVICE', r);

  r := api_card_lookup(ft, a, '1111', '04:A1:B2:C3');
  insert into t_results(step, pass, got) values ('unknown card', r->>'code' = 'CARD_UNKNOWN', r);

  r := api_customer_register(ft, a, '1111', 'Jo Soap', '0821234567', true, '04A1B2C3');
  insert into t_results(step, pass, got) values ('register blocked on forecourt', r->>'code' = 'DEVICE_KIND', r);

  r := api_customer_register(kt, c, '3333', 'Jo Soap', '+27 82 123 4567', false, '04A1B2C3');
  insert into t_results(step, pass, got) values ('register needs consent', r->>'code' = 'CONSENT', r);

  r := api_customer_register(kt, c, '3333', 'Jo Soap', '+27 82 123 4567', true, '04:a1:b2:c3');
  insert into t_results(step, pass, got) values ('register customer', (r->>'ok')::boolean
    and r->'data'->>'mobile_masked' like '%567' and (r->'data'->>'balance_cents')::int = 0, r);

  r := api_customer_register(kt, c, '3333', 'Jo Again', '0821234567', true, 'FFEE0011');
  insert into t_results(step, pass, got) values ('duplicate mobile', r->>'code' = 'MOBILE_EXISTS', r);

  r := api_card_lookup(ft, a, '1111', '04a1b2c3');
  insert into t_results(step, pass, got) values ('forecourt lookup hides balance',
    (r->>'ok')::boolean and r->'data'->'balance_cents' = 'null'::jsonb, r);

  r := api_claim_create(ft, a, '1111', '04A1B2C3', 3, 'ULP95', 40.5, '00000000-0000-0000-0000-000000000001');
  cl1 := (r->'data'->>'claim_id')::uuid;
  insert into t_results(step, pass, got) values ('claim 40.5L @10c = 405c', (r->'data'->>'cashback_cents')::int = 405, r);

  r := api_claim_create(ft, a, '1111', '04A1B2C3', 3, 'ULP95', 40.5, '00000000-0000-0000-0000-000000000001');
  insert into t_results(step, pass, got) values ('retry same ref is idempotent', (r->'data'->>'repeat')::boolean, r);

  r := api_claim_create(ft, a, '1111', '04A1B2C3', 3, 'ULP95', 40.5, '00000000-0000-0000-0000-000000000002');
  insert into t_results(step, pass, got) values ('identical claim blocked', r->>'code' = 'DUPLICATE_CLAIM', r);

  r := api_claim_create(ft, a, '1111', '04A1B2C3', 4, 'D50', 120, '00000000-0000-0000-0000-000000000003');
  insert into t_results(step, pass, got) values ('daily cap 150L enforced', r->>'code' = 'CAP', r);

  r := api_claim_create(ft, a, '1111', '04A1B2C3', 99, 'D50', 10, '00000000-0000-0000-0000-000000000004');
  insert into t_results(step, pass, got) values ('bad pump', r->>'code' = 'PUMP', r);

  r := api_claim_create(ft, a, '1111', '04A1B2C3', 2, 'D50', 250, '00000000-0000-0000-0000-000000000005');
  insert into t_results(step, pass, got) values ('max per fill', r->>'code' = 'LITRES_MAX', r);

  -- PIN lockout for B
  for i in 1..5 loop r := api_sign_in(ft, b, '0000'); end loop;
  r := api_sign_in(ft, b, '2222');
  insert into t_results(step, pass, got) values ('lockout after 5 wrong PINs', r->>'code' = 'LOCKED', r);
  r := api_mgr_staff_save(mt, mgr, '1234', b, 'Att B', 'attendant', '2223', true);
  r := api_sign_in(ft, b, '2223');
  insert into t_results(step, pass, got) values ('manager PIN reset unlocks', (r->>'ok')::boolean, r);

  -- offline claims
  r := api_claim_create(ft, b, null, '04A1B2C3', 5, 'ULP93', 20, '00000000-0000-0000-0000-000000000006', now() - interval '1 hour', true);
  cl_off := (r->'data'->>'claim_id')::uuid;
  insert into t_results(step, pass, got) values ('offline claim accepted, unverified', (r->>'ok')::boolean
    and not (select pin_verified from claims where id = cl_off), r);
  r := api_claim_create(ft, b, null, '04A1B2C3', 5, 'ULP93', 21, '00000000-0000-0000-0000-000000000007');
  insert into t_results(step, pass, got) values ('online claim needs PIN', r->>'code' = 'PIN', r);

  -- manager captures a claim on manager device, cannot approve own
  r := api_claim_create(mt, mgr, '1234', '04A1B2C3', 1, 'D50', 10, '00000000-0000-0000-0000-000000000008');
  cl_m := (r->'data'->>'claim_id')::uuid;
  r := api_claim_decide(mt, mgr, '1234', cl_m, true, 'R1', null);
  insert into t_results(step, pass, got) values ('cannot approve own claim', r->>'code' = 'OWN_CLAIM', r);

  r := api_claims_pending(kt, c, '3333');
  insert into t_results(step, pass, got) values ('pending list has 3', jsonb_array_length(r->'data'->'claims') = 3, r);

  r := api_claim_decide(kt, c, '3333', cl1, true, '', null);
  insert into t_results(step, pass, got) values ('approve needs receipt', r->>'code' = 'RECEIPT', r);
  r := api_claim_decide(kt, c, '3333', cl1, true, 'ab-1234', null);
  insert into t_results(step, pass, got) values ('approve claim', (r->'data'->>'balance_cents')::int = 405, r);
  r := api_claim_decide(kt, c, '3333', cl1, true, 'ab-9999', null);
  insert into t_results(step, pass, got) values ('cannot approve twice', r->>'code' = 'NOT_PENDING', r);
  r := api_claim_decide(kt, c, '3333', cl_m, true, 'AB-1234', null);
  insert into t_results(step, pass, got) values ('receipt reuse blocked (case-insensitive)', r->>'code' = 'RECEIPT_USED', r);
  r := api_claim_decide(kt, c, '3333', cl_m, false, null, '');
  insert into t_results(step, pass, got) values ('reject needs reason', r->>'code' = 'REASON', r);
  r := api_claim_decide(kt, c, '3333', cl_m, false, null, 'Customer did not pay at kiosk');
  insert into t_results(step, pass, got) values ('reject claim', r->'data'->>'status' = 'rejected', r);

  -- payouts
  r := api_payout(kt, c, '3333', '04A1B2C3', 5000, '567', null);
  insert into t_results(step, pass, got) values ('payout more than balance', r->>'code' = 'BALANCE', r);
  r := api_mgr_adjust(mt, mgr, '1234', (select customer_id from cards where uid = '04A1B2C3'), 10000, 'Test top-up');
  insert into t_results(step, pass, got) values ('manager adjustment', (r->'data'->>'balance_cents')::int = 10405, r);
  r := api_payout(kt, c, '3333', '04A1B2C3', 6000, '999', null);
  insert into t_results(step, pass, got) values ('payout mobile check', r->>'code' = 'MOBILE_CHECK', r);
  r := api_payout(kt, c, '3333', '04A1B2C3', 4000, '567', null);
  insert into t_results(step, pass, got) values ('payout minimum R50', r->>'code' = 'MIN', r);
  r := api_payout(kt, c, '3333', '04A1B2C3', 6000, '567', 'PO-77');
  insert into t_results(step, pass, got) values ('payout R60', (r->'data'->>'balance_cents')::int = 4405, r);
  r := api_payout(ft, a, '1111', '04A1B2C3', 5000, '567', null);
  insert into t_results(step, pass, got) values ('no payouts on forecourt tablet', r->>'code' = 'DEVICE_KIND', r);

  -- rate change applies to new claims only
  r := api_mgr_set_rate(mt, mgr, '1234', null, 15);
  r := api_claim_create(ft, a, '1111', '04A1B2C3', 6, 'ULP95', 10, '00000000-0000-0000-0000-000000000009');
  insert into t_results(step, pass, got) values ('new rate 15c applied', (r->'data'->>'cashback_cents')::int = 150, r);
  insert into t_results(step, pass, got) values ('old claim keeps 10c', (select cashback_cents from claims where id = cl1) = 405, null);
  r := api_mgr_set_rate(mt, mgr, '1234', 'D50', 20);
  insert into t_results(step, pass, got) values ('per-grade rate', r->'data'->'grades' @> '[{"code":"D50","rate":20.00}]'::jsonb
    or r->'data'->'grades' @> '[{"code":"D50","rate":20}]'::jsonb, r);

  -- expiry
  update claims set created_at = now() - interval '20 hours' where id = cl_off;
  r := api_claims_pending(kt, c, '3333');
  insert into t_results(step, pass, got) values ('stale claim expires', (select status from claims where id = cl_off) = 'expired', r);

  -- card loss & replacement
  r := api_card_block(kt, c, '3333', '04A1B2C3', 'Lost');
  r := api_claim_create(ft, a, '1111', '04A1B2C3', 2, 'ULP95', 5, '00000000-0000-0000-0000-00000000000a');
  insert into t_results(step, pass, got) values ('blocked card rejected', r->>'code' = 'CARD_BLOCKED', r);
  r := api_card_replace(kt, c, '3333', '082 123 4567', 'NEWCARD01', 'Lost');
  insert into t_results(step, pass, got) values ('replacement keeps balance', (r->'data'->>'balance_cents')::int = 4405, r);

  -- reports
  r := api_mgr_dashboard(mt, mgr, '1234');
  insert into t_results(step, pass, got) values ('dashboard', (r->>'ok')::boolean and (r->'data'->>'liability_cents')::int = 4405, r);
  r := api_mgr_report(mt, mgr, '1234', current_date - 7, current_date + 1);
  insert into t_results(step, pass, got) values ('report', (r->>'ok')::boolean, r);
  r := api_shift_summary(kt, c, '3333');
  insert into t_results(step, pass, got) values ('shift summary', (r->'data'->'me'->>'payout_cents')::int = 6000, r);
  r := api_mgr_customers(mt, mgr, '1234', 'soap');
  insert into t_results(step, pass, got) values ('customer search', jsonb_array_length(r->'data'->'customers') = 1, r);
  r := api_mgr_customer_detail(mt, mgr, '1234', (select customer_id from cards where uid = 'NEWCARD01'));
  insert into t_results(step, pass, got) values ('customer detail', jsonb_array_length(r->'data'->'cards') = 2, r);
  r := api_mgr_audit(mt, mgr, '1234', 50);
  insert into t_results(step, pass, got) values ('audit log', jsonb_array_length(r->'data'->'entries') > 5, null);
  r := api_mgr_devices(mt, mgr, '1234');
  insert into t_results(step, pass, got) values ('device list', jsonb_array_length(r->'data'->'devices') = 3, r);
  r := api_mgr_update_settings(mt, mgr, '1234', '{"pump_count": 0}');
  insert into t_results(step, pass, got) values ('settings range check', r->>'code' = 'SETTINGS', r);
  r := api_mgr_update_settings(mt, mgr, '1234', '{"pump_count": 10}');
  insert into t_results(step, pass, got) values ('settings update', (r->'data'->>'pump_count')::int = 10, r);
  r := api_mgr_dashboard(kt, c, '3333');
  insert into t_results(step, pass, got) values ('cashier blocked from manager functions', r->>'code' = 'DEVICE_KIND', r);
end $$;

-- privilege checks
insert into t_results(step, pass, got) values
  ('anon cannot select staff', not has_table_privilege('anon', 'public.staff', 'select'), null),
  ('anon cannot select ledger', not has_table_privilege('anon', 'public.ledger', 'select'), null),
  ('anon cannot call _auth', not has_function_privilege('anon', 'public._auth(text,uuid,text,text[],text[],boolean)', 'execute'), null),
  ('anon can call api_claim_create', has_function_privilege('anon',
     'public.api_claim_create(text,uuid,text,text,int,text,numeric,uuid,timestamptz,boolean)', 'execute'), null);

select n, step, pass, case when pass then null else got end as got from t_results order by n;
