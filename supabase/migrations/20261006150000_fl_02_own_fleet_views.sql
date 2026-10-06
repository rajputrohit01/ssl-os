-- fl_02: Own Fleet trucks view, truck transfers (re-registration), document view with PUCC + VLTD
-- 1. ft_steps: new documents pucc (PUCC / pollution) and vltd (VLTD), both with expiry; open rows for existing fleet trucks
-- 2. ft_step_save / ft_import know the two new documents; import also fills vehicle type, body type, GVW, registration date
-- 3. ft_truck_transfers + fl_truck_transfer(): new registration number from a date, old number kept as history
-- 4. fl_truck_details(): edit vehicle type, body type, GVW, registration date (+ the existing truck fields)
-- 5. view fl_truck_master: one row per own-fleet truck in the owner's column order
-- 6. tests part_fl
--
-- AS APPLIED 6 Oct 2026: the approval prompt kept cancelling, so it went in as
--   fl_02a (everything except section 1 and the tests), section 1 run by the owner in the SQL Editor,
--   fl_02b (tests, plus a check that every existing truck has PUCC and VLTD), fl_02c (two FT test expectations: gaps now list pucc,vltd).

-- 1 ---------------------------------------------------------------------------------------------
alter table public.ft_steps drop constraint ft_steps_step_check;
alter table public.ft_steps add constraint ft_steps_step_check check (step = any (array['body','insurance','temp_reg','perm_reg','permit',
  'nat_permit','fitness','road_tax','gps','fastag','pucc','vltd']));

insert into public.ft_steps(ft_truck_id, step, status)
select t.id, s, 'open' from public.ft_trucks t cross join unnest(array['pucc','vltd']) s
 where t.source = 'import' and not exists (select 1 from public.ft_steps x where x.ft_truck_id = t.id and x.step = s);

-- 2 ---------------------------------------------------------------------------------------------
do $$
declare src text;
begin
  -- ft_step_save: PUCC and VLTD behave like the other expiring documents
  src := pg_get_functiondef('app.ft_step_save(uuid,jsonb)'::regprocedure);
  src := replace(src, $r$('insurance','permit','nat_permit','fitness','road_tax')$r$, $r$('insurance','permit','nat_permit','fitness','road_tax','pucc','vltd')$r$);
  src := replace(src, $r$when 'fastag' then 'FASTag ID'$r$, $r$when 'fastag' then 'FASTag ID' when 'pucc' then 'PUCC certificate number' when 'vltd' then 'VLTD device / certificate number'$r$);
  if position('''pucc''' in src) = 0 then raise exception 'fl_02: could not patch ft_step_save'; end if;
  execute src;

  -- ft_import: new trucks get PUCC + VLTD rows; the sheet can carry them; extra truck fields filled after the truck exists
  src := pg_get_functiondef('app.ft_import(jsonb)'::regprocedure);
  src := replace(src, $r$'road_tax','gps','fastag']) s;$r$, $r$'road_tax','gps','fastag','pucc','vltd']) s;$r$);
  src := replace(src, $r$('fastag', nullif(trim(x->>'fastag_id'),''), null::date)) v(step, doc, exp)$r$,
                      $r$('fastag', nullif(trim(x->>'fastag_id'),''), null::date),
          ('pucc', nullif(trim(x->>'pucc_no'),''), nullif(x->>'pucc_expiry','')::date),
          ('vltd', nullif(trim(x->>'vltd_no'),''), nullif(x->>'vltd_expiry','')::date)) v(step, doc, exp)$r$);
  src := replace(src, $r$update public.ft_trucks set sys_truck_id = v_sys where id = t.id;$r$,
                      $r$update public.ft_trucks set sys_truck_id = v_sys where id = t.id;
      perform app.fl_import_extra(t.id, x);$r$);
  if position('fl_import_extra' in src) = 0 or position('''pucc_no''' in src) = 0 or position('''fastag'',''pucc'',''vltd'']' in src) = 0 then
    raise exception 'fl_02: could not patch ft_import'; end if;
  -- created first (below) so the patched import compiles against it
  create or replace function app.fl_import_extra(p_truck uuid, x jsonb) returns void language plpgsql security definer set search_path to '' as $f$
  declare t public.ft_trucks%rowtype; v_type text; v_gvw numeric;
  begin
    select * into t from public.ft_trucks where id = p_truck;
    v_type := nullif(upper(trim(coalesce(x->>'vehicle_type',''))), '');
    if v_type is not null then
      if v_type not in ('04WH-LCV','06WH-HCV','10WH','12WH','14WH','16WH-HCV','TRACTOR TRAILER') then
        raise exception 'vehicle type "%" not known (use 04WH-LCV, 06WH-HCV, 10WH, 12WH, 14WH, 16WH-HCV or TRACTOR TRAILER)', x->>'vehicle_type'; end if;
      update public.sys_trucks set truck_type = coalesce(truck_type, v_type) where id = t.sys_truck_id;
    end if;
    if nullif(trim(x->>'body_type'),'') is not null then
      update public.ft_steps set details = details || jsonb_build_object('body_type', upper(trim(x->>'body_type')))
       where ft_truck_id = p_truck and step = 'body' and coalesce(details->>'body_type','') = '';
    end if;
    if nullif(x->>'registration_date','') is not null then
      update public.ft_steps set issued_on = coalesce(issued_on, (x->>'registration_date')::date) where ft_truck_id = p_truck and step = 'perm_reg';
    end if;
    v_gvw := nullif(x->>'gvw_ton','')::numeric;
    if v_gvw is not null and t.model_id is not null then
      if v_gvw <= 0 or v_gvw > 100 then raise exception 'GVW % ton is not plausible', v_gvw; end if;
      update public.ft_models set gvw_kg = coalesce(gvw_kg, round(v_gvw * 1000)::int) where id = t.model_id;
    end if;
  end $f$;
  execute src;
end $$;

-- 3 ---------------------------------------------------------------------------------------------
create table if not exists public.ft_truck_transfers (
  id uuid primary key default gen_random_uuid(),
  ft_truck_id uuid not null references public.ft_trucks(id),
  old_registration_no text not null,
  new_registration_no text not null,
  from_date date not null,
  remarks text,
  created_by uuid, created_at timestamptz, updated_by uuid, updated_at timestamptz,
  check (old_registration_no <> new_registration_no)
);
create index if not exists ft_truck_transfers_truck on public.ft_truck_transfers(ft_truck_id, from_date);
alter table public.ft_truck_transfers enable row level security;
create policy ft_truck_transfers_read on public.ft_truck_transfers for select to authenticated using (true);
select app.stamp_install('public.ft_truck_transfers'::regclass);  -- no-op if the event trigger already did it

create or replace function app.fl_truck_transfer(p_truck uuid, p_new_no text, p_from date, p_remarks text)
 returns uuid language plpgsql security definer set search_path to '' as $f$
declare t public.ft_trucks%rowtype; v_new text := upper(regexp_replace(coalesce(p_new_no,''), '[^A-Za-z0-9]', '', 'g')); v_last date; v_id uuid;
begin
  perform app.wh_require('ft_entry');
  select * into t from public.ft_trucks where id = p_truck for update;
  if t.id is null then raise exception 'Choose the truck'; end if;
  if t.status <> 'ready' then raise exception 'Truck % is still in onboarding; change its registration there', t.registration_no; end if;
  if length(v_new) < 6 then raise exception 'Enter the full new truck number'; end if;
  if v_new = t.registration_no then raise exception 'New number is the same as the present number'; end if;
  if p_from is null then raise exception 'Enter the date from which the new number applies'; end if;
  if p_from > (now() at time zone 'Asia/Kolkata')::date then raise exception 'Date cannot be in the future'; end if;
  if exists (select 1 from public.ft_trucks where registration_no = v_new) or exists (select 1 from public.sys_trucks where upper(regexp_replace(registration_no, '[^A-Za-z0-9]', '', 'g')) = v_new) then
    raise exception 'Truck number % is already in the fleet', v_new; end if;
  if exists (select 1 from public.ft_truck_transfers where old_registration_no = v_new) then raise exception 'Truck number % was used before by an own truck', v_new; end if;
  if exists (select 1 from public.vn_market_trucks where truck_no = v_new and to_date is null) then raise exception 'Truck number % is a market truck with a vendor', v_new; end if;
  select max(from_date) into v_last from public.ft_truck_transfers where ft_truck_id = p_truck;
  if v_last is not null and p_from < v_last then raise exception 'Date is before the last number change (%)', to_char(v_last, 'DD-MM-YYYY'); end if;
  insert into public.ft_truck_transfers(ft_truck_id, old_registration_no, new_registration_no, from_date, remarks)
  values (p_truck, t.registration_no, v_new, p_from, nullif(trim(p_remarks),'')) returning id into v_id;
  update public.ft_trucks set registration_no = v_new where id = p_truck;
  update public.sys_trucks set registration_no = v_new where id = t.sys_truck_id;
  update public.ft_steps set doc_no = v_new where ft_truck_id = p_truck and step = 'perm_reg';
  return v_id;
end $f$;
create or replace function public.fl_truck_transfer(p_truck uuid, p_new_no text, p_from date, p_remarks text default null)
 returns uuid language sql security definer set search_path to '' as $f$ select app.fl_truck_transfer(p_truck, p_new_no, p_from, p_remarks) $f$;
revoke all on function public.fl_truck_transfer(uuid, text, date, text) from public, anon;
grant execute on function public.fl_truck_transfer(uuid, text, date, text) to authenticated;

-- an own truck's old number is still "our own truck", never a market truck
do $$
declare src text;
begin
  src := pg_get_functiondef('app.vn_truck_link(text,uuid,date,text)'::regprocedure);
  src := replace(src, $r$raise exception 'Truck % is our own truck (Fleet), not a market truck', v_tno; end if;$r$,
                      $r$raise exception 'Truck % is our own truck (Fleet), not a market truck', v_tno; end if;
  if exists (select 1 from public.ft_truck_transfers where old_registration_no = v_tno) then
    raise exception 'Truck % is an earlier number of our own truck (Fleet), not a market truck', v_tno; end if;$r$);
  if position('earlier number of our own truck' in src) = 0 then raise exception 'fl_02: could not patch vn_truck_link'; end if;
  execute src;
end $$;

-- 4 ---------------------------------------------------------------------------------------------
create or replace function app.fl_truck_details(p_truck uuid, p jsonb)
 returns void language plpgsql security definer set search_path to '' as $f$
declare t public.ft_trucks%rowtype; v_type text := nullif(upper(trim(coalesce(p->>'vehicle_type',''))), ''); v_gvw numeric := nullif(p->>'gvw_ton','')::numeric;
begin
  perform app.wh_require('ft_entry');
  perform app.ft_truck_edit(p_truck, p);
  select * into t from public.ft_trucks where id = p_truck;
  if v_type is not null then
    if v_type not in ('04WH-LCV','06WH-HCV','10WH','12WH','14WH','16WH-HCV','TRACTOR TRAILER') then raise exception 'Choose the vehicle type'; end if;
    update public.sys_trucks set truck_type = v_type where id = t.sys_truck_id;
  end if;
  if p ? 'body_type' then
    update public.ft_steps set details = details || jsonb_build_object('body_type', upper(trim(coalesce(p->>'body_type',''))))
     where ft_truck_id = p_truck and step = 'body';
  end if;
  if nullif(p->>'registration_date','') is not null then
    if (p->>'registration_date')::date > (now() at time zone 'Asia/Kolkata')::date then raise exception 'Registration date cannot be in the future'; end if;
    update public.ft_steps set issued_on = (p->>'registration_date')::date where ft_truck_id = p_truck and step = 'perm_reg';
  end if;
  if v_gvw is not null then
    if t.model_id is null then raise exception 'Choose the model first: GVW belongs to the model'; end if;
    if v_gvw <= 0 or v_gvw > 100 then raise exception 'GVW % ton is not plausible', v_gvw; end if;
    update public.ft_models set gvw_kg = round(v_gvw * 1000)::int where id = t.model_id;
  end if;
end $f$;
create or replace function public.fl_truck_details(p_truck uuid, p jsonb)
 returns void language sql security definer set search_path to '' as $f$ select app.fl_truck_details(p_truck, p) $f$;
revoke all on function public.fl_truck_details(uuid, jsonb) from public, anon;
grant execute on function public.fl_truck_details(uuid, jsonb) to authenticated;

-- 5 ---------------------------------------------------------------------------------------------
create or replace view public.fl_truck_master with (security_invoker = true) as
 select t.id,
        t.source,
        t.status,
        t.company_id,
        t.registration_no,
        s.truck_type                                   as vehicle_type,
        nullif(b.details->>'body_type', '')            as body_type,
        round(m.gvw_kg / 1000.0, 2)                    as gvw_ton,
        nullif(m.make, '—')                            as manufacturer,
        c.code                                         as owner_code,
        c.name                                         as owner,
        t.chassis_no,
        m.model                                        as model_no,
        t.engine_no,
        r.issued_on                                    as registration_date,
        coalesce((select x.old_registration_no from public.ft_truck_transfers x where x.ft_truck_id = t.id
                   order by x.from_date, x.created_at limit 1), t.registration_no) as original_registration_no,
        (select count(*) from public.ft_truck_transfers x where x.ft_truck_id = t.id) as transfers,
        t.model_id,
        t.created_by, t.created_at, t.updated_by, t.updated_at
   from public.ft_trucks t
   join public.sys_companies c on c.id = t.company_id
   left join public.sys_trucks s on s.id = t.sys_truck_id
   left join public.ft_models m on m.id = t.model_id
   left join public.ft_steps b on b.ft_truck_id = t.id and b.step = 'body'
   left join public.ft_steps r on r.ft_truck_id = t.id and r.step = 'perm_reg';

create or replace view public.fl_transfer_list with (security_invoker = true) as
 select x.*, c.code as owner_code
   from public.ft_truck_transfers x join public.ft_trucks t on t.id = x.ft_truck_id join public.sys_companies c on c.id = t.company_id;

-- 6 ---------------------------------------------------------------------------------------------
create or replace function wh_test.part_fl(ids jsonb)
 returns jsonb language plpgsql set search_path to 'public', 'wh_test', 'app', 'pg_temp' as $f$
declare log jsonb := '[]'; res jsonb; tid uuid; a uuid;
begin
  perform wh_test.as_user('d021a30f-98f2-4130-9c55-767137cfb277');
  res := public.ft_import(jsonb_build_array(jsonb_build_object('registration_no','WB99FL0001','company',(select code from public.sys_companies order by code limit 1),
    'make','TATA','model','FLTEST 4825','chassis_no','FLCH0001','engine_no','FLEN0001','vehicle_type','10wh','body_type','high side','gvw_ton','25',
    'registration_date','2021-03-04','pucc_no','PU1','pucc_expiry','2027-01-31','vltd_no','VL1','vltd_expiry','2027-02-28')));
  log := log || wh_test.eq('FL: import creates the truck with the new fields', (res->>'imported') || '/' || jsonb_array_length(res->'errors'), '1/0');
  select id into tid from public.ft_trucks where registration_no = 'WB99FL0001';
  log := log || wh_test.eq('FL: master row in the owner''s columns',
    (select concat_ws('|', registration_no, vehicle_type, body_type, gvw_ton, manufacturer, model_no, chassis_no, engine_no, registration_date, original_registration_no) from public.fl_truck_master where id = tid),
    'WB99FL0001|10WH|HIGH SIDE|25.00|TATA|FLTEST 4825|FLCH0001|FLEN0001|2021-03-04|WB99FL0001');
  log := log || wh_test.eq('FL: PUCC and VLTD recorded with expiry from import',
    (select string_agg(step || ':' || status || ':' || expiry_on, ',' order by step) from public.ft_steps where ft_truck_id = tid and step in ('pucc','vltd')),
    'pucc:done:2027-01-31,vltd:done:2027-02-28');
  log := log || wh_test.err('FL: transfer needs a different number', format($s$select public.fl_truck_transfer(%L, 'wb 99 fl 0001', '2026-01-01')$s$, tid), '%same as the present%');
  log := log || wh_test.err('FL: transfer date not in the future', format($s$select public.fl_truck_transfer(%L, 'JH05FL0002', '2099-01-01')$s$, tid), '%future%');
  perform public.fl_truck_transfer(tid, 'jh 05 fl 0002', '2026-02-01', 'Re-registered in Jharkhand');
  log := log || wh_test.eq('FL: transfer changes the current number everywhere, keeps the original',
    (select concat_ws('|', f.registration_no, s.registration_no, r.doc_no, f.original_registration_no) from public.fl_truck_master f
       join public.ft_trucks t on t.id = f.id join public.sys_trucks s on s.id = t.sys_truck_id
       join public.ft_steps r on r.ft_truck_id = f.id and r.step = 'perm_reg' where f.id = tid),
    'JH05FL0002|JH05FL0002|JH05FL0002|WB99FL0001');
  log := log || wh_test.err('FL: date before the last number change is refused', format($s$select public.fl_truck_transfer(%L, 'WB99FL0003', '2026-01-15')$s$, tid), '%before the last number change%');
  perform public.fl_truck_transfer(tid, 'WB99FL0003', '2026-03-01', null);
  log := log || wh_test.eq('FL: second transfer keeps the very first number as original',
    (select original_registration_no || ' ' || transfers from public.fl_truck_master where id = tid), 'WB99FL0001 2');
  log := log || wh_test.err('FL: an old own number cannot be reused', format($s$select public.fl_truck_transfer(%L, 'JH05FL0002', '2026-03-05')$s$, tid), '%used before%');
  insert into public.sys_vendors(vendor_code, vendor_name, kinds, phone, pan) values ('TZ92','FL MT VENDOR','{transporter}','9830099102','ZFLMT9102Z') returning id into a;
  log := log || wh_test.err('FL: an old own number is not a market truck', format($s$select public.vn_truck_link('WB99FL0001', %L, '2026-03-05', null)$s$, a), '%earlier number of our own truck%');
  perform public.fl_truck_details(tid, '{"vehicle_type":"12WH","body_type":"Container","registration_date":"2021-03-05","gvw_ton":"28"}');
  log := log || wh_test.eq('FL: edit vehicle type, body type, registration date, GVW',
    (select concat_ws('|', vehicle_type, body_type, registration_date, gvw_ton) from public.fl_truck_master where id = tid), '12WH|CONTAINER|2021-03-05|28.00');
  return log;
end $f$;

do $$
declare src text;
begin
  select pg_get_functiondef('wh_test.run()'::regprocedure) into src;
  if position('part_fl(' in src) = 0 then
    src := replace(src, 'log := log || wh_test.part_stamp(ids);',
                        'log := log || wh_test.part_stamp(ids);' || chr(10) || '    log := log || wh_test.part_fl(ids);');
    if position('part_fl(' in src) = 0 then raise exception 'could not wire part_fl into wh_test.run()'; end if;
    execute src;
  end if;
end $$;
