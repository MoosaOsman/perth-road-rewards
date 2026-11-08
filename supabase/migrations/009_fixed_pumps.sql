-- Perth Road Rewards — fixed pumps (8 Nov 2026)
-- The pumps and their grades are a physical fact of the site, not a setting
-- (owner's decision). They are installed here, taken from the Namos transaction
-- journal of 1 Nov 2026 (every fuel line: pump number and product):
--   ULP 95: pumps 1, 4, 8, 9    ULP 93: pump 6    D50: pumps 2, 3, 5, 10
--   Pump 7: no sales in the journal, installed as not in use.
-- The manager can no longer change them: api_mgr_pumps_save is dropped and the
-- pump count is no longer accepted by api_mgr_update_settings. A change to the
-- forecourt (new pump, grade swap) is made with a new migration.

alter table public.settings alter column pump_count set default 10;
update public.settings set pump_count = 10 where id = 1;

delete from public.pumps where pump_no is not null;
insert into public.pumps (pump_no, grades, active) values
  (1,  '{ULP95}', true),
  (2,  '{D50}',   true),
  (3,  '{D50}',   true),
  (4,  '{ULP95}', true),
  (5,  '{D50}',   true),
  (6,  '{ULP93}', true),
  (7,  '{}',      false),
  (8,  '{ULP95}', true),
  (9,  '{ULP95}', true),
  (10, '{D50}',   true);

drop function if exists public.api_mgr_pumps_save(text, uuid, text, jsonb);

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
      updated_at = now()
    where id = 1;
    perform _audit((ctx->>'staff_id')::uuid, (ctx->>'device_id')::uuid, 'settings_changed', p_settings - 'pump_count');
    return _ok((select to_jsonb(s) from settings s where id = 1));
  exception
    when check_violation then return jsonb_build_object('ok', false, 'code', 'SETTINGS', 'message', 'One of the values is out of range.');
    when others then return _err_json(SQLSTATE, SQLERRM);
  end;
end $$;
