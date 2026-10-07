-- ic_03 (7 Oct 2026): Inter-Company module removed from the app at the owner's request.
-- No inter-company data existed (0 cash entries, 0 hire/service lines, 0 settlements).
-- The ic_* tables, views and functions are left in place, empty and unused, until the owner decides to drop or rebuild.
-- Tests: part_ic (32 checks) taken out of wh_test.run(); its shared setup moved to part_shared_setup (ic_03b).
do $$
declare src text;
begin
  src := pg_get_functiondef('wh_test.run()'::regprocedure);
  src := replace(src, E'    perform wh_test.as_user(admin);\n    log := log || wh_test.part_ic(ids);\n', '');
  if position('part_ic(' in src) > 0 then raise exception 'could not remove part_ic from wh_test.run()'; end if;
  execute src;
end $$;
