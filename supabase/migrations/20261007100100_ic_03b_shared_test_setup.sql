-- ic_03b: setup that used to live at the top of part_ic; later parts (pd, te, dr ...) depend on it
create or replace function wh_test.part_shared_setup(ids jsonb)
 returns jsonb language plpgsql set search_path to 'public', 'wh_test', 'app', 'pg_temp' as $f$
declare staff uuid := '036fb790-9ba6-45b0-961d-f7c483514851'; ssl uuid; lsa uuid; wh uuid := (ids->>'wh')::uuid;
begin
  insert into public.sys_companies(code, name) values ('TSA', 'TEST CO A') returning id into ssl;
  insert into public.sys_companies(code, name) values ('TSB', 'TEST CO B') returning id into lsa;
  update public.sys_plants set company_id = ssl where id = wh;
  insert into public.sys_trucks(registration_no, company_id) values ('WB00IC0001', lsa);
  insert into public.sys_trucks(registration_no, company_id) values ('WB00IC0002', ssl);
  update public.sys_users set is_active = true where id = staff;
  insert into public.sys_user_roles(user_id, role_id) select staff, id from public.sys_roles where code = 'ACCOUNTS_HEAD' on conflict do nothing;
  return '[]'::jsonb;
end $f$;

do $$
declare src text;
begin
  src := pg_get_functiondef('wh_test.run()'::regprocedure);
  if position('part_shared_setup' in src) = 0 then
    src := replace(src, E'log := log || wh_test.part_b(ids, null);\n',
                        E'log := log || wh_test.part_b(ids, null);\n    perform wh_test.as_user(admin);\n    log := log || wh_test.part_shared_setup(ids);\n');
    if position('part_shared_setup' in src) = 0 then raise exception 'could not wire part_shared_setup'; end if;
    execute src;
  end if;
end $$;
