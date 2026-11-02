-- Perth Road Rewards — hardening after Supabase advisor review
-- 1. Pin search_path on helper functions (advisor 0011 function_search_path_mutable).
-- 2. Index every foreign key (advisor 0001 unindexed_foreign_keys).
-- No signature or behaviour changes.

alter function public._fail(text, text)            set search_path = public, extensions;
alter function public._err_json(text, text)        set search_path = public, extensions;
alter function public._ok(jsonb)                    set search_path = public, extensions;
alter function public._hash_token(text)             set search_path = public, extensions;
alter function public._local_day(timestamptz)       set search_path = public, extensions;
alter function public._norm_uid(text)               set search_path = public, extensions;
alter function public._norm_mobile(text)            set search_path = public, extensions;
alter function public._balance(uuid)                set search_path = public, extensions;
alter function public._current_rate(text)           set search_path = public, extensions;
alter function public._audit(uuid, uuid, text, jsonb) set search_path = public, extensions;
alter function public._valid_pin(text)              set search_path = public, extensions;

create index if not exists audit_log_device_id_idx     on public.audit_log (device_id);
create index if not exists audit_log_staff_id_idx      on public.audit_log (staff_id);
create index if not exists cards_blocked_by_idx        on public.cards (blocked_by);
create index if not exists cards_issued_by_idx         on public.cards (issued_by);
create index if not exists claims_card_id_idx          on public.claims (card_id);
create index if not exists claims_created_by_idx       on public.claims (created_by);
create index if not exists claims_created_device_idx   on public.claims (created_device);
create index if not exists claims_decided_by_idx       on public.claims (decided_by);
create index if not exists claims_decided_device_idx   on public.claims (decided_device);
create index if not exists claims_grade_code_idx       on public.claims (grade_code);
create index if not exists customers_created_by_idx    on public.customers (created_by);
create index if not exists earn_rates_set_by_idx       on public.earn_rates (set_by);
create index if not exists ledger_payout_id_idx        on public.ledger (payout_id);
create index if not exists ledger_staff_id_idx         on public.ledger (staff_id);
create index if not exists payouts_card_id_idx         on public.payouts (card_id);
create index if not exists payouts_device_id_idx       on public.payouts (device_id);
create index if not exists payouts_staff_id_idx        on public.payouts (staff_id);
