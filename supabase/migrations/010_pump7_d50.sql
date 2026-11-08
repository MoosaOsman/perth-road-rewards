-- Perth Road Rewards — pump 7 dispenses D50 (owner, 8 Nov 2026)
-- Migration 009 installed pump 7 as not in use because it had no sales in the
-- 1 Nov journal. It is a working D50 pump.

update public.pumps set grades = '{D50}', active = true, updated_at = now() where pump_no = 7;
