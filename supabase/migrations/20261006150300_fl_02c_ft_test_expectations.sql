-- fl_02c: FT import tests now expect PUCC and VLTD in the gap list
do $$
declare r record; src text; n int := 0;
begin
  for r in select p.oid from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
            where ns.nspname = 'wh_test' and p.prokind = 'f'
  loop
    src := pg_get_functiondef(r.oid);
    if position('road_tax,gps,fastag missing true' in src) > 0 or position('road_tax,gps,fastag no_loan false' in src) > 0 then
      src := replace(src, 'road_tax,gps,fastag missing true', 'road_tax,gps,fastag,pucc,vltd missing true');
      src := replace(src, 'road_tax,gps,fastag no_loan false', 'road_tax,gps,fastag,pucc,vltd no_loan false');
      execute src; n := n + 1;
    end if;
  end loop;
  if n = 0 then raise exception 'test expectations not found'; end if;
end $$;
