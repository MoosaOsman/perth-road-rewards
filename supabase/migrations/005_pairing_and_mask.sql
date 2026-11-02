-- Perth Road Rewards — fixes found in the end-to-end smoke test (2 Nov 2026)
-- 1. Pairing codes could contain O, I or L: ambiguous characters were stripped
--    before upper-casing, so lower-case o/i/l survived. Codes now come from an
--    unambiguous alphabet (no 0/O, 1/I/L).
-- 2. The masked mobile shown on kiosk screens ended in the last 3 digits, which
--    are the payout check. It now shows the first 3 digits only.
-- No signature changes.

create or replace function public._pairing_code()
returns text language sql volatile set search_path = public, extensions as $$
  select string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', (get_byte(x.b, i) % 31) + 1, 1), '' order by i)
  from (select gen_random_bytes(8) as b) x, generate_series(0, 7) i;
$$;
revoke all on function public._pairing_code() from public, anon, authenticated;

create or replace function public.api_mgr_device_create(p_token text, p_staff uuid, p_pin text, p_name text, p_kind text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare ctx jsonb; v_code text; v_id uuid;
begin
  ctx := _mgr(p_token, p_staff, p_pin);
  if not (ctx->>'ok')::boolean then return ctx; end if;
  begin
    if p_kind not in ('forecourt','kiosk','manager') then perform _fail('KIND', 'Choose a device type.'); end if;
    if length(trim(coalesce(p_name,''))) = 0 then perform _fail('NAME', 'Name the device.'); end if;
    v_code := _pairing_code();
    insert into devices (name, kind, pairing_code, pairing_expires)
      values (trim(p_name), p_kind, v_code, now() + interval '24 hours') returning id into v_id;
    perform _audit((ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid, 'device_created',
      jsonb_build_object('id', v_id, 'name', p_name, 'kind', p_kind));
    return _ok(jsonb_build_object('id', v_id, 'pairing_code', v_code));
  exception when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;

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
      v_code := _pairing_code();
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
    'mobile_masked', left(cu.mobile, 3) || ' *** ****',
    'litres_today', v_today, 'cap_litres', v_cap, 'litres_remaining', greatest(v_cap - v_today, 0),
    'balance_cents', case when p_full then _balance(cu.id) end,
    'paid_out_today_cents', case when p_full then v_paid end,
    'min_payout_cents', st.min_payout_cents,
    'max_payout_day_cents', st.max_payout_day_cents);
end $$;
revoke all on function public._card_info(text, boolean) from public, anon, authenticated;
