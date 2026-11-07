-- Perth Road Rewards — journal check refinement (7 Nov 2026)
-- A claim whose only identical sale already backs another claim is now a
-- "duplicate" (with the receipt named) instead of "no sale".
-- No signature changes.

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
      -- an identical sale that already backs another claim makes this a duplicate
      select js.* into s from journal_sales js
       where js.pump_no = c.pump_no and js.grade_code = c.grade_code and js.litres = c.litres
         and abs(extract(epoch from js.sold_at - c.captured_at)) <= v_win and js.id = any(v_used)
       order by abs(extract(epoch from js.sold_at - c.captured_at))
       limit 1;
      if found then
        insert into _jm values (c.id, 'duplicate', s.id, v_detail || jsonb_build_object('reason',
            'The matching sale (receipt ' || s.receipt_no || ') already backs another claim.'))
          on conflict (claim_id) do update set result = excluded.result, sale_id = excluded.sale_id, detail = excluded.detail;
        continue;
      end if;
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
