-- ic_04: Inter-Company permissions off the Users screen (run by the owner in the SQL Editor; the tool approval kept cancelling)
-- To restore: re-insert the 5 keys (module 'Inter-Company', sort 200-204) and the role grants:
--   Administrator: all 5 · HO Accounts: ic_view, ic_entry, ic_settle_pay · Accounts Head: ic_view, ic_approve · Managing Partner: ic_view, ic_settle_approve
delete from public.sys_role_permissions where permission_key in ('ic_view','ic_entry','ic_approve','ic_settle_approve','ic_settle_pay');
delete from public.sys_permissions where key in ('ic_view','ic_entry','ic_approve','ic_settle_approve','ic_settle_pay');
