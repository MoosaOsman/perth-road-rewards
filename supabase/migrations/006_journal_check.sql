-- Perth Road Rewards — daily Namos journal check (7 Nov 2026)
-- The manager uploads the day's Namos transaction journal. The tablet parses it
-- (app/journal.js) and sends one row per receipt, pump and grade. The server
-- matches every approved or pending claim of that day against the sales:
--
--   1. Receipt number first: the receipt the cashier typed must exist, and its
--      pump, grade and litres must be identical (litres to the cent of a litre)
--      with the sale time within 30 minutes of the claim.
--   2. Otherwise: one unclaimed sale with the same pump, grade and identical
--      litres within 30 minutes. Found → "receipt number wrong" (passes, flagged).
--   3. Otherwise the claim fails: "mismatch" (receipt found but different) or
--      "no sale" (nothing on that pump with those litres).
--   A sale can back only one claim; a second claim on it is a "duplicate".
--
-- Split fuel lines on one receipt (same pump and grade) are added up by the
-- parser, so the claim must equal the receipt total. Journal times are to the
-- minute, so the window is 30 min 59 s. Failed claims are never reversed
-- automatically: the manager reviews and reverses with one tap (audited).
-- Re-uploading a day replaces its sales and re-runs the check; reversals stay.

create table public.journals (
  day          date primary key,
  file_name    text,
  receipts     int  not null,
  fuel_rows    int  not null,
  litres       numeric(10,2) not null,
  first_sale   timestamptz,
  last_sale    timestamptz,
  warnings     jsonb not null default '[]',
  uploaded_by  uuid references public.staff(id),
  uploaded_at  timestamptz not null default now()
);

create table public.journal_sales (
  id           bigint generated always as identity primary key,
  day          date not null references public.journals(day) on delete cascade,
  sold_at      timestamptz not null,
  pos          text not null,
  receipt_no   text not null,
  receipt_key  text not null,
  pump_no      int  not null,
  grade_code   text,
  grade_name   text not null,
  litres       numeric(9,2) not null,
  amount_cents int  not null,
  lines        int  not null default 1,
  attendant    text,
  cashier      text,
  shift        text
);
create index journal_sales_day_idx     on public.journal_sales (day);
create index journal_sales_receipt_idx on public.journal_sales (receipt_key);
create index journal_sales_pump_idx    on public.journal_sales (pump_no, grade_code, sold_at);

create table public.claim_checks (
  claim_id      uuid primary key references public.claims(id),
  day           date not null,
  result        text not null check (result in ('match','receipt_wrong','mismatch','no_sale','duplicate')),
  sale_id       bigint references public.journal_sales(id) on delete set null,
  detail        jsonb not null default '{}',
  checked_at    timestamptz not null default now(),
  reversed_at   timestamptz,
  reversed_by   uuid references public.staff(id),
  reverse_note  text,
  reverse_cents int
);
create index claim_checks_day_idx         on public.claim_checks (day);
create index claim_checks_sale_id_idx     on public.claim_checks (sale_id);
create index claim_checks_reversed_by_idx on public.claim_checks (reversed_by);
create index journals_uploaded_by_idx     on public.journals (uploaded_by);

alter table public.journals      enable row level security;
alter table public.journal_sales enable row level security;
alter table public.claim_checks  enable row level security;
revoke all on public.journals, public.journal_sales, public.claim_checks from anon, authenticated;

create or replace function public._receipt_key(p text)
returns text language sql immutable set search_path = public, extensions as $$
  select nullif(regexp_replace(regexp_replace(coalesce(p, ''), '\D', '', 'g'), '^0+(?=\d)', ''), '');
$$;

-- Match every approved/pending claim captured on p_day. Needs that day's journal.
create or replace function public._journal_match(p_day date)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  c record; s record; v_used bigint[] := '{}'; v_win int := 30 * 60 + 59;
  v_detail jsonb; v_rec record; v_diff text[];
begin
  if not exists (select 1 from journals where day = p_day) then return; end if;

  -- claims no longer approved/pending lose their result (unless reversed)
  delete from claim_checks k using claims cl
   where k.claim_id = cl.id and k.day = p_day and k.reversed_at is null
     and cl.status not in ('approved','pending');

  create temp table if not exists _jm (claim_id uuid primary key, result text, sale_id bigint, detail jsonb) on commit drop;
  truncate _jm;

  -- pass 1: the receipt number the cashier typed
  for c in
    select cl.* from claims cl
     where _local_day(cl.captured_at) = p_day and cl.status in ('approved','pending')
       and _receipt_key(cl.namos_receipt_no) is not null
     order by cl.captured_at
  loop
    select js.* into v_rec from journal_sales js
     where js.receipt_key = _receipt_key(c.namos_receipt_no)
       and abs(extract(epoch from js.sold_at - c.captured_at)) <= 12 * 3600
     order by coalesce(js.pump_no = c.pump_no and js.grade_code = c.grade_code, false) desc,
              abs(extract(epoch from js.sold_at - c.captured_at))
     limit 1;
    if not found then
      insert into _jm values (c.id, null, null, jsonb_build_object('receipt_note', 'Receipt ' || c.namos_receipt_no || ' is not in the journal.'));
      continue;
    end if;
    v_diff := '{}';
    if v_rec.pump_no <> c.pump_no then v_diff := v_diff || ('pump ' || v_rec.pump_no || ' on the slip, ' || c.pump_no || ' claimed'); end if;
    if v_rec.grade_code is distinct from c.grade_code then v_diff := v_diff || (coalesce(v_rec.grade_code, v_rec.grade_name) || ' on the slip, ' || c.grade_code || ' claimed'); end if;
    if v_rec.litres <> c.litres then v_diff := v_diff || (v_rec.litres || ' L on the slip, ' || c.litres || ' L claimed'); end if;
    if abs(extract(epoch from v_rec.sold_at - c.captured_at)) > v_win then
      v_diff := v_diff || ('sold ' || to_char(v_rec.sold_at at time zone 'Africa/Johannesburg', 'HH24:MI') || ', claimed '
        || to_char(c.captured_at at time zone 'Africa/Johannesburg', 'HH24:MI') || ' (more than 30 min apart)');
    end if;
    if cardinality(v_diff) = 0 then
      if v_rec.id = any(v_used) then
        insert into _jm values (c.id, 'duplicate', v_rec.id, jsonb_build_object('reason', 'Receipt ' || v_rec.receipt_no || ' already backs another claim.'));
      else
        v_used := v_used || v_rec.id;
        insert into _jm values (c.id, 'match', v_rec.id, '{}');
      end if;
    else
      insert into _jm values (c.id, null, v_rec.id, jsonb_build_object('receipt_sale', v_rec.id, 'differences', to_jsonb(v_diff)));
    end if;
  end loop;

  -- pass 2: identical pump, grade and litres within 30 minutes, nearest first
  for c in
    select cl.* from claims cl
     where _local_day(cl.captured_at) = p_day and cl.status in ('approved','pending')
       and not exists (select 1 from _jm where _jm.claim_id = cl.id and _jm.result is not null)
     order by cl.captured_at
  loop
    v_detail := coalesce((select detail from _jm where claim_id = c.id), '{}');
    select js.* into s from journal_sales js
     where js.pump_no = c.pump_no and js.grade_code = c.grade_code and js.litres = c.litres
       and abs(extract(epoch from js.sold_at - c.captured_at)) <= v_win
       and not (js.id = any(v_used))
     order by abs(extract(epoch from js.sold_at - c.captured_at))
     limit 1;
    if found then
      v_used := v_used || s.id;
      insert into _jm values (c.id, case when c.namos_receipt_no is null then 'match' else 'receipt_wrong' end, s.id, v_detail)
        on conflict (claim_id) do update set result = excluded.result, sale_id = excluded.sale_id, detail = excluded.detail;
    elsif v_detail ? 'receipt_sale' then
      insert into _jm values (c.id, 'mismatch', (v_detail->>'receipt_sale')::bigint, v_detail)
        on conflict (claim_id) do update set result = excluded.result, sale_id = excluded.sale_id, detail = excluded.detail;
    else
      -- nearest sales on the same pump, to help the manager see what happened
      v_detail := v_detail || jsonb_build_object('nearby', (
        select coalesce(jsonb_agg(jsonb_build_object('receipt', x.receipt_no, 'sold_at', x.sold_at, 'grade', coalesce(x.grade_code, x.grade_name),
                 'litres', x.litres, 'attendant', x.attendant) order by x.d), '[]')
          from (select js.*, abs(extract(epoch from js.sold_at - c.captured_at)) d from journal_sales js
                 where js.pump_no = c.pump_no and abs(extract(epoch from js.sold_at - c.captured_at)) <= 3600
                 order by d limit 3) x));
      insert into _jm values (c.id, 'no_sale', null, v_detail)
        on conflict (claim_id) do update set result = excluded.result, sale_id = excluded.sale_id, detail = excluded.detail;
    end if;
  end loop;

  insert into claim_checks (claim_id, day, result, sale_id, detail, checked_at)
    select claim_id, p_day, result, sale_id, detail, now() from _jm where result is not null
  on conflict (claim_id) do update set day = excluded.day, result = excluded.result, sale_id = excluded.sale_id,
    detail = excluded.detail, checked_at = excluded.checked_at;
end $$;
revoke all on function public._journal_match(date) from public, anon, authenticated;
revoke all on function public._receipt_key(text) from public, anon, authenticated;

-- Upload (or replace) a day's journal and run the check for that day and its
-- neighbours (claims just before or after midnight can match the next day's sales).
create or replace function public.api_mgr_journal_upload(
  p_token text, p_staff uuid, p_pin text, p_day date, p_file_name text, p_meta jsonb, p_sales jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; v_n int;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  perform _expire_claims();
  begin
    if p_day is null then perform _fail('DAY', 'The journal has no recognisable date.'); end if;
    if p_day > _local_day(now()) then perform _fail('DAY', 'The journal is dated in the future.'); end if;
    if jsonb_typeof(p_sales) <> 'array' or jsonb_array_length(p_sales) = 0 then
      perform _fail('EMPTY', 'No fuel sales were found in this file. Check that it is the Namos transaction journal.');
    end if;
    if jsonb_array_length(p_sales) > 5000 then perform _fail('SIZE', 'The file has too many sales for one day.'); end if;

    delete from journals where day = p_day;   -- cascades to journal_sales; claim_checks.sale_id → null
    insert into journals (day, file_name, receipts, fuel_rows, litres, first_sale, last_sale, warnings, uploaded_by)
    values (p_day, left(p_file_name, 200), coalesce((p_meta->>'receipts')::int, 0), jsonb_array_length(p_sales),
            coalesce((p_meta->>'litres')::numeric, 0), (p_meta->>'first_sale')::timestamptz, (p_meta->>'last_sale')::timestamptz,
            coalesce(p_meta->'warnings', '[]'), (ctx->>'staff_id')::uuid);
    insert into journal_sales (day, sold_at, pos, receipt_no, receipt_key, pump_no, grade_code, grade_name, litres,
                               amount_cents, lines, attendant, cashier, shift)
    select p_day, (x->>'sold_at')::timestamptz, coalesce(x->>'pos', ''), x->>'receipt_no', _receipt_key(x->>'receipt_no'),
           (x->>'pump_no')::int, nullif(x->>'grade_code', ''), coalesce(x->>'grade_name', ''), (x->>'litres')::numeric(9,2),
           coalesce((x->>'amount_cents')::int, 0), coalesce((x->>'lines')::int, 1),
           left(x->>'attendant', 60), left(x->>'cashier', 60), left(x->>'shift', 10)
      from jsonb_array_elements(p_sales) x;
    get diagnostics v_n = row_count;

    perform _journal_match(p_day - 1);
    perform _journal_match(p_day);
    perform _journal_match(p_day + 1);
    perform _audit((ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid, 'journal_uploaded',
      jsonb_build_object('day', p_day, 'file', p_file_name, 'sales', v_n));
    return _ok(jsonb_build_object('day', p_day, 'sales', v_n));
  exception when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

-- Re-run the check for a day (e.g. after late approvals).
create or replace function public.api_mgr_journal_recheck(p_token text, p_staff uuid, p_pin text, p_day date)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  perform _expire_claims();
  if not exists (select 1 from journals where day = p_day) then
    return jsonb_build_object('ok', false, 'code', 'NO_JOURNAL', 'message', 'No journal has been uploaded for that day.');
  end if;
  perform _journal_match(p_day);
  return _ok(jsonb_build_object('day', p_day));
end $$;

create or replace function public.api_mgr_journal_list(p_token text, p_staff uuid, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  return _ok(jsonb_build_object('journals', (select coalesce(jsonb_agg(jsonb_build_object(
      'day', j.day, 'file_name', j.file_name, 'receipts', j.receipts, 'litres', j.litres, 'uploaded_at', j.uploaded_at,
      'uploaded_by', s.full_name,
      'claims', (select count(*) from claims where _local_day(captured_at) = j.day and status in ('approved','pending')),
      'passed', (select count(*) from claim_checks k where k.day = j.day and k.result in ('match','receipt_wrong')),
      'failed', (select count(*) from claim_checks k where k.day = j.day and k.result in ('mismatch','no_sale','duplicate')),
      'open', (select count(*) from claim_checks k join claims cl on cl.id = k.claim_id
                where k.day = j.day and k.result in ('mismatch','no_sale','duplicate') and k.reversed_at is null and cl.status = 'approved'))
      order by j.day desc), '[]')
    from (select * from journals order by day desc limit 60) j left join staff s on s.id = j.uploaded_by)));
end $$;

create or replace function public.api_mgr_journal_result(p_token text, p_staff uuid, p_pin text, p_day date)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; j record;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  select * into j from journals where day = p_day;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'NO_JOURNAL', 'message', 'No journal has been uploaded for that day.');
  end if;
  return _ok(jsonb_build_object(
    'journal', jsonb_build_object('day', j.day, 'file_name', j.file_name, 'receipts', j.receipts, 'fuel_rows', j.fuel_rows,
       'litres', j.litres, 'first_sale', j.first_sale, 'last_sale', j.last_sale, 'warnings', j.warnings, 'uploaded_at', j.uploaded_at),
    'grades', (select coalesce(jsonb_agg(jsonb_build_object('grade', g.grade, 'sold_litres', g.sold_litres,
         'claimed_litres', (select coalesce(sum(litres), 0) from claims where status = 'approved'
             and _local_day(captured_at) = p_day and grade_code = g.grade)) order by g.grade), '[]')
       from (select coalesce(js.grade_code, js.grade_name) as grade, sum(js.litres) as sold_litres
               from journal_sales js where js.day = p_day group by 1) g),
    'claims', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', cl.id, 'captured_at', cl.captured_at, 'status', cl.status, 'pump', cl.pump_no, 'grade', cl.grade_code,
        'litres', cl.litres, 'cashback_cents', cl.cashback_cents, 'customer', cu.full_name, 'card', ca.uid,
        'attendant', sa.full_name, 'cashier', sd.full_name, 'receipt', cl.namos_receipt_no, 'pin_verified', cl.pin_verified,
        'result', coalesce(k.result, 'unchecked'), 'detail', k.detail, 'reversed_at', k.reversed_at,
        'reverse_cents', k.reverse_cents, 'reverse_note', k.reverse_note, 'reversed_by', sr.full_name,
        'sale', case when js.id is null then null else jsonb_build_object('receipt', js.receipt_no, 'sold_at', js.sold_at,
           'pump', js.pump_no, 'grade', coalesce(js.grade_code, js.grade_name), 'litres', js.litres, 'lines', js.lines,
           'amount_cents', js.amount_cents, 'attendant', js.attendant, 'cashier', js.cashier) end)
        order by cl.captured_at), '[]')
      from claims cl join customers cu on cu.id = cl.customer_id join cards ca on ca.id = cl.card_id
      left join staff sa on sa.id = cl.created_by left join staff sd on sd.id = cl.decided_by
      left join claim_checks k on k.claim_id = cl.id left join journal_sales js on js.id = k.sale_id
      left join staff sr on sr.id = k.reversed_by
      where _local_day(cl.captured_at) = p_day and (cl.status in ('approved','pending') or k.reversed_at is not null))));
end $$;

-- Reverse the cashback of an approved claim that failed the check.
-- The balance may go below zero if the cashback was already paid out; it is then
-- recovered from future earnings (payouts need a positive balance).
create or replace function public.api_mgr_journal_reverse(
  p_token text, p_staff uuid, p_pin text, p_claim uuid, p_note text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; cl record; k record;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  begin
    select * into cl from claims where id = p_claim for update;
    if not found then perform _fail('NOT_FOUND', 'Claim not found.'); end if;
    select * into k from claim_checks where claim_id = p_claim for update;
    if not found or k.result not in ('mismatch','no_sale','duplicate') then
      perform _fail('NOT_FAILED', 'Only claims that failed the journal check can be reversed here.');
    end if;
    if k.reversed_at is not null then perform _fail('REVERSED', 'This claim has already been reversed.'); end if;
    if cl.status <> 'approved' then perform _fail('NOT_APPROVED', 'Only approved claims earned cashback. Reject pending claims at the kiosk.'); end if;
    if length(trim(coalesce(p_note, ''))) < 3 then perform _fail('NOTE', 'A note explaining the reversal is required.'); end if;
    perform 1 from customers where id = cl.customer_id for update;
    insert into ledger (customer_id, entry_type, amount_cents, staff_id, note)
      values (cl.customer_id, 'adjust', -cl.cashback_cents, (ctx->>'staff_id')::uuid,
              'Journal check reversal (' || k.result || ', receipt ' || coalesce(cl.namos_receipt_no, '-') || '): ' || trim(p_note));
    update claim_checks set reversed_at = now(), reversed_by = (ctx->>'staff_id')::uuid,
           reverse_note = trim(p_note), reverse_cents = cl.cashback_cents
     where claim_id = p_claim;
    perform _audit((ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid, 'claim_reversed',
      jsonb_build_object('claim_id', cl.id, 'customer_id', cl.customer_id, 'amount_cents', cl.cashback_cents,
                         'result', k.result, 'note', p_note));
    return _ok(jsonb_build_object('balance_cents', _balance(cl.customer_id)));
  exception when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;
