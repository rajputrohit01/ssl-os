-- sys_01: every entry records Created by / Edited by
-- 1. created_by / created_at / updated_by / updated_at on every public table (except wh_audit_log)
-- 2. backfill from wh_audit_log, with user triggers off during the backfill
-- 3. trigger zz_stamp -> app.stamp() on every table; event trigger stamp_new_tables for future tables
-- 4. public.sys_user_labels() -> {user id: name}
-- 5. view columns: vn_market_truck_list + updated_by/updated_at, vn_vendor_list + created_by/updated_by
-- 6. test part_stamp, wired into wh_test.run()

-- 1. columns (helper reused by the event trigger) -------------------------------------------
create or replace function app.stamp_columns(p_table regclass)
 returns void language plpgsql set search_path to '' as $f$
begin
  execute format('alter table %s add column if not exists created_by uuid, add column if not exists created_at timestamptz,
                  add column if not exists updated_by uuid, add column if not exists updated_at timestamptz', p_table);
end $f$;

create or replace function app.stamp() returns trigger
 language plpgsql set search_path to '' as $f$
begin
  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by, auth.uid());
    new.created_at := coalesce(new.created_at, now());
  else
    -- creation is fixed once written
    new.created_by := coalesce(old.created_by, new.created_by);
    new.created_at := coalesce(old.created_at, new.created_at);
    -- stamp an edit only when a signed-in user actually changed something
    if auth.uid() is not null
       and (to_jsonb(new) - 'updated_at' - 'updated_by') is distinct from (to_jsonb(old) - 'updated_at' - 'updated_by') then
      new.updated_by := auth.uid();
      new.updated_at := now();
    end if;
  end if;
  return new;
end $f$;

create or replace function app.stamp_install(p_table regclass)
 returns void language plpgsql set search_path to '' as $f$
begin
  if p_table = 'public.wh_audit_log'::regclass then return; end if;
  perform app.stamp_columns(p_table);
  execute format('create or replace trigger zz_stamp before insert or update on %s for each row execute function app.stamp()', p_table);
end $f$;

do $$
declare t record;
begin
  for t in select c.oid::regclass reg from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind in ('r','p') and c.relname <> 'wh_audit_log' and not c.relispartition
  loop
    perform app.stamp_columns(t.reg);
  end loop;
end $$;

-- 2. backfill from the audit log -----------------------------------------------------------------
do $$
declare t record; g record; trg text[];
begin
  for t in select c.relname, c.oid::regclass reg from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind in ('r','p') and c.relname <> 'wh_audit_log' and not c.relispartition
              and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'id' and not a.attisdropped)
              and exists (select 1 from public.wh_audit_log l where l.table_name in (c.relname, 'public.' || c.relname))
  loop
    begin
      trg := '{}';
      for g in select tgname, tgenabled from pg_trigger where tgrelid = t.reg and not tgisinternal and tgenabled <> 'D' loop
        execute format('alter table %s disable trigger %I', t.reg, g.tgname);
        trg := trg || (g.tgenabled::text || g.tgname::text);
      end loop;

      execute format($q$
        with a as (
          select row_id,
                 (array_agg(changed_by order by changed_at, id) filter (where lower(action) like 'i%%' or lower(action) like 'c%%'))[1] c_by,
                 min(changed_at) filter (where lower(action) like 'i%%' or lower(action) like 'c%%') c_at,
                 (array_agg(changed_by order by changed_at desc, id desc) filter (where lower(action) like 'u%%'))[1] u_by,
                 max(changed_at) filter (where lower(action) like 'u%%') u_at
            from public.wh_audit_log where table_name in (%L, %L) group by row_id)
        update %s t set
               created_by = coalesce(t.created_by, a.c_by),
               created_at = coalesce(t.created_at, a.c_at),
               updated_by = coalesce(t.updated_by, a.u_by),
               updated_at = case when t.updated_by is null and a.u_by is not null then a.u_at else t.updated_at end
          from a
         where a.row_id = t.id::text
           and ((t.created_by is null and a.c_by is not null) or (t.created_at is null and a.c_at is not null)
                or (t.updated_by is null and a.u_by is not null))$q$,
        t.relname, 'public.' || t.relname, t.reg);

      for i in 1 .. coalesce(array_length(trg, 1), 0) loop
        execute format('alter table %s enable %s trigger %I', t.reg,
          case left(trg[i], 1) when 'A' then 'always' when 'R' then 'replica' else '' end, substr(trg[i], 2));
      end loop;
    exception when others then
      raise notice 'sys_01 backfill skipped for %: %', t.relname, sqlerrm;   -- triggers roll back to enabled
    end;
  end loop;
end $$;

-- 3. triggers ------------------------------------------------------------------------------------------
do $$
declare t record;
begin
  for t in select c.oid::regclass reg from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind in ('r','p') and c.relname <> 'wh_audit_log' and not c.relispartition
  loop
    perform app.stamp_install(t.reg);
  end loop;
end $$;

create or replace function app.stamp_new_table() returns event_trigger
 language plpgsql set search_path to '' as $f$
declare r record;
begin
  for r in select objid from pg_event_trigger_ddl_commands()
            where command_tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
              and object_type = 'table' and schema_name = 'public'
  loop
    perform app.stamp_install(r.objid::regclass);
  end loop;
end $f$;

-- may need extra privilege on Supabase; if refused, everything else above still stands
do $$
begin
  drop event trigger if exists stamp_new_tables;
  create event trigger stamp_new_tables on ddl_command_end
    when tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
    execute function app.stamp_new_table();
exception when others then
  raise notice 'stamp_new_tables not created (%): new tables must call app.stamp_install() in their migration', sqlerrm;
end $$;

-- 4. names for the Created by / Edited by columns --------------------------------------------------
create or replace function public.sys_user_labels()
 returns jsonb language sql stable security definer set search_path to '' as $f$
  select coalesce(jsonb_object_agg(u.id::text, coalesce(nullif(trim(u.full_name), ''), u.email)), '{}'::jsonb)
    from public.sys_users u
$f$;
revoke all on function public.sys_user_labels() from public, anon;
grant execute on function public.sys_user_labels() to authenticated;

-- 5. views ---------------------------------------------------------------------------------------------------
create or replace view public.vn_market_truck_list as
 SELECT m.id,
    m.truck_no,
    m.vendor_id,
    m.from_date,
    m.to_date,
    m.remarks,
    m.created_by,
    m.created_at,
    m.ended_by,
    m.ended_at,
    v.vendor_code,
    v.vendor_name,
    v.phone AS vendor_phone,
    ( SELECT (pv.vendor_code || ' · '::text) || pv.vendor_name
           FROM public.vn_market_trucks p
             JOIN public.sys_vendors pv ON pv.id = p.vendor_id
          WHERE p.truck_no = m.truck_no AND p.to_date = m.from_date AND p.id <> m.id
          ORDER BY p.from_date DESC
         LIMIT 1) AS moved_from,
    m.assigned_at,
    m.updated_by,
    m.updated_at
   FROM public.vn_market_trucks m
     JOIN public.sys_vendors v ON v.id = m.vendor_id;

create or replace view public.vn_vendor_list as
 SELECT v.id,
    v.vendor_code,
    v.vendor_name,
    v.busy_name,
    v.is_active,
    v.created_at,
    v.company_id,
    v.kinds,
    v.contact_person,
    v.phone,
    v.email,
    v.pan,
    v.gstin,
    v.address,
    v.state_id,
    v.bank_account,
    v.bank_ifsc,
    v.bank_holder,
    v.note,
    v.updated_at,
    v.bank_name,
    v.bank_branch,
    v.vendor_since,
    v.incomplete,
    s.name AS state_name,
    (( SELECT count(*) AS count FROM public.wh_contractors x WHERE x.vendor_id = v.id))
      + (( SELECT count(*) AS count FROM public.rk_sardars x WHERE x.vendor_id = v.id))
      + (( SELECT count(*) AS count FROM public.wh_dispatches x WHERE x.vendor_id = v.id))
      + (( SELECT count(*) AS count FROM public.rk_truck_slips x WHERE x.vendor_id = v.id))
      + (( SELECT count(*) AS count FROM public.ft_orders x WHERE x.dealer_id = v.id))
      + (( SELECT count(*) AS count FROM public.ft_steps x WHERE x.vendor_id = v.id)) AS used_count,
    ( SELECT count(*) AS count FROM public.wh_evidence e WHERE e.entity_type = 'vendor_cheque'::text AND e.entity_id = v.id) AS cheque_docs,
    v.business_type,
    v.aadhaar_no,
    ( SELECT count(*) AS count FROM public.wh_evidence e WHERE e.entity_type = 'vendor_aadhaar'::text AND e.entity_id = v.id) AS aadhaar_docs,
    ( SELECT count(*) AS count FROM public.wh_evidence e WHERE e.entity_type = 'vendor_regdoc'::text AND e.entity_id = v.id) AS reg_docs,
    ( SELECT count(*) AS count FROM public.vn_market_trucks m WHERE m.vendor_id = v.id AND m.to_date IS NULL) AS trucks,
    v.created_by,
    v.updated_by
   FROM public.sys_vendors v
     LEFT JOIN public.sys_states s ON s.id = v.state_id;

-- 6. test -------------------------------------------------------------------------------------------------------
create or replace function wh_test.part_stamp(ids jsonb)
 returns jsonb language plpgsql set search_path to 'public', 'wh_test', 'app', 'pg_temp' as $f$
declare log jsonb := '[]'; admin uuid := 'd021a30f-98f2-4130-9c55-767137cfb277'; staff uuid := '036fb790-9ba6-45b0-961d-f7c483514851';
        vid uuid; r record; ed uuid;
begin
  log := log || wh_test.eq('STAMP: every table except the audit log has the zz_stamp trigger',
    (select count(*)::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind in ('r','p') and c.relname <> 'wh_audit_log' and not c.relispartition
        and not exists (select 1 from pg_trigger t where t.tgrelid = c.oid and t.tgname = 'zz_stamp')), '0');
  perform wh_test.as_user(admin);
  insert into public.sys_vendors(vendor_code, vendor_name, kinds, phone, pan)
       values ('TV61','STAMP VENDOR','{transporter}','9830066001','STMPV6001A') returning id into vid;
  select created_by, created_at, updated_by into r from public.sys_vendors where id = vid;
  log := log || wh_test.eq('STAMP: new entry records who created it, no editor yet',
    (r.created_by = admin and r.created_at is not null and r.updated_by is null)::text, 'true');
  -- edit as staff; if vendor edits are HO-only, the admin edits instead (still proves the stamp)
  ed := staff;
  perform wh_test.as_user(staff);
  begin
    update public.sys_vendors set note = 'stamp test' where id = vid;
  exception when others then
    ed := admin;
    perform wh_test.as_user(admin);
    update public.sys_vendors set note = 'stamp test' where id = vid;
  end;
  select created_by, updated_by, updated_at into r from public.sys_vendors where id = vid;
  log := log || wh_test.eq('STAMP: edit records who edited it and keeps the creator',
    (r.created_by = admin and r.updated_by = ed and r.updated_at is not null)::text, 'true');
  perform wh_test.as_user(admin);
  update public.sys_vendors set note = 'stamp test' where id = vid;
  log := log || wh_test.eq('STAMP: saving without a change is not an edit',
    ((select updated_by from public.sys_vendors where id = vid) = ed)::text, 'true');
  log := log || wh_test.eq('STAMP: sys_user_labels gives a name for every user',
    ((select count(*) from jsonb_object_keys(public.sys_user_labels())) = (select count(*) from public.sys_users))::text, 'true');
  perform wh_test.as_user(admin);
  return log;
end $f$;

do $$
declare src text;
begin
  select pg_get_functiondef('wh_test.run()'::regprocedure) into src;
  if position('part_stamp' in src) = 0 then
    src := replace(src, 'log := log || wh_test.part_tds(ids);',
                        'log := log || wh_test.part_tds(ids);' || chr(10) || '    log := log || wh_test.part_stamp(ids);');
    if position('part_stamp' in src) = 0 then raise exception 'could not wire part_stamp into wh_test.run()'; end if;
    execute src;
  end if;
end $$;
