-- vn_13: truck-vendor assignment timestamp + upload of the old truck-vendor log
-- 1. vn_market_trucks.assigned_at (old rows = created_at, new rows = now())
-- 2. vn_market_truck_list appends assigned_at
-- 3. vn_truck_import: rows applied oldest first, timestamps kept,
--    a later row for a truck already with another vendor moves it ("Moved by upload")
-- 4. part_mt test extended

alter table public.vn_market_trucks add column if not exists assigned_at timestamptz;
update public.vn_market_trucks set assigned_at = created_at where assigned_at is null;
alter table public.vn_market_trucks alter column assigned_at set default now();

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
    m.assigned_at
   FROM public.vn_market_trucks m
     JOIN public.sys_vendors v ON v.id = m.vendor_id;

-- Upload. Timestamp arrives as local India time without offset (app parser upDT): 'YYYY-MM-DDTHH:MM:SS'.
-- Returns created (new trucks), updated (trucks moved), skipped (same vendor), errors.
create or replace function app.vn_truck_import(p_rows jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare x jsonb; r int := 0; n int := 0; u int := 0; s int := 0; errs jsonb := '[]';
        v uuid; v_tno text; o record; v_ts timestamptz; v_date date; v_moved boolean;
begin
  perform app.wh_require('vn_trucks');
  for x in
    select e.val
      from jsonb_array_elements(p_rows) with ordinality e(val, ord)
     order by coalesce(
                case when nullif(e.val->>'assigned_at','') is not null
                     then (e.val->>'assigned_at')::timestamp at time zone 'Asia/Kolkata' end,
                case when nullif(e.val->>'from_date','') is not null
                     then (e.val->>'from_date')::date::timestamp at time zone 'Asia/Kolkata' end) nulls last,
              coalesce((e.val->>'_row')::int, e.ord::int)
  loop
    r := r + 1;
    begin
      v_tno := upper(regexp_replace(coalesce(x->>'truck_no',''), '[^A-Za-z0-9]', '', 'g'));
      v_ts := case when nullif(x->>'assigned_at','') is not null
                   then (x->>'assigned_at')::timestamp at time zone 'Asia/Kolkata' end;
      v_date := coalesce(nullif(x->>'from_date','')::date,
                         (v_ts at time zone 'Asia/Kolkata')::date,
                         current_date);
      v := null;
      select id into v from public.sys_vendors where vendor_code = upper(trim(coalesce(x->>'vendor_code','')));
      if v is null then raise exception 'vendor code "%" not found', x->>'vendor_code'; end if;

      select m.vendor_id, sv.vendor_code into o
        from public.vn_market_trucks m join public.sys_vendors sv on sv.id = m.vendor_id
       where m.truck_no = v_tno and m.to_date is null;
      v_moved := found;

      if v_moved and o.vendor_id = v then
        s := s + 1;
        continue;
      end if;

      perform app.vn_truck_link(v_tno, v, v_date,
        case when v_moved then 'Moved by upload' || coalesce(' — ' || nullif(trim(x->>'remarks'),''), '')
             else nullif(trim(x->>'remarks'),'') end);

      update public.vn_market_trucks
         set assigned_at = coalesce(v_ts, now())
       where truck_no = v_tno and vendor_id = v and to_date is null;

      if v_moved then u := u + 1; else n := n + 1; end if;
    exception when others then
      errs := errs || jsonb_build_object('row', coalesce((x->>'_row')::int, r), 'error', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('created', n, 'updated', u, 'skipped', s, 'errors', errs);
end $function$;

-- part_mt: earlier checks unchanged; the upload check now covers the old-log behaviour
create or replace function wh_test.part_mt(ids jsonb)
 returns jsonb
 language plpgsql
 set search_path to 'public', 'wh_test', 'app', 'pg_temp'
as $function$
declare log jsonb := '[]'; a uuid; b uuid; c uuid; res jsonb;
begin
  insert into public.sys_vendors(vendor_code, vendor_name, kinds, phone, pan) values ('TV51','MT VENDOR A','{transporter}','9830055001','MTVEA5001A') returning id into a;
  insert into public.sys_vendors(vendor_code, vendor_name, kinds, phone, pan) values ('TV52','MT VENDOR B','{transporter}','9830055002','MTVEB5002B') returning id into b;
  insert into public.sys_vendors(vendor_code, vendor_name, kinds, phone, pan) values ('TV53','MT BODY C','{body}','9830055003','MTBOC5003C') returning id into c;
  insert into public.sys_trucks(registration_no) values ('WB99MT0001');
  log := log || wh_test.err('MT: own truck cannot be a market truck', format($s$select public.vn_truck_link('WB99MT0001', %L, '2026-10-01', null)$s$, a), '%our own truck%');
  log := log || wh_test.err('MT: only truck vendors', format($s$select public.vn_truck_link('WB11MT1111', %L, '2026-10-01', null)$s$, c), '%not a truck vendor%');
  perform public.vn_truck_link('wb 11 mt 1111', a, '2026-10-01', null);
  log := log || wh_test.err('MT: already with the same vendor', format($s$select public.vn_truck_link('WB11MT1111', %L, '2026-10-05', null)$s$, a), '%already with%');
  log := log || wh_test.err('MT: move date not before present link', format($s$select public.vn_truck_link('WB11MT1111', %L, '2026-09-20', null)$s$, b), '%before the truck joined%');
  perform public.vn_truck_link('WB11MT1111', b, '2026-10-10', 'Sold to vendor B');
  log := log || wh_test.eq('MT: move closes old link on the date, new link has remarks and shows where it came from',
    (select string_agg(vendor_code || ':' || from_date || '→' || coalesce(to_date::text, 'now') || coalesce(' ' || remarks, '') || coalesce(' from ' || moved_from, ''), ' | ' order by from_date) from public.vn_market_truck_list where truck_no = 'WB11MT1111'),
    'TV51:2026-10-01→2026-10-10 | TV52:2026-10-10→now Sold to vendor B from TV51 · MT VENDOR A');
  log := log || wh_test.eq('MT: vendor of the truck on a date', (select string_agg(v.vendor_code, ',' order by x) from (values (1, app.vn_truck_vendor_on('WB11MT1111', '2026-10-05')), (2, app.vn_truck_vendor_on('WB11MT1111', '2026-10-10'))) z(x, id) join public.sys_vendors v on v.id = z.id), 'TV51,TV52');
  log := log || wh_test.eq('MT: a link made on the screen gets a timestamp',
    (select count(*)::text from public.vn_market_trucks where truck_no = 'WB11MT1111' and assigned_at is null), '0');

  -- old log, deliberately out of order: rows 6/7 are the same truck listed newest first
  res := public.vn_truck_import('[
    {"_row":2,"truck_no":"WB11MT2222","vendor_code":"TV51","from_date":"2026-09-01"},
    {"_row":3,"truck_no":"WB11MT1111","vendor_code":"TV52","assigned_at":"2026-10-12T11:00:00"},
    {"_row":4,"truck_no":"WB11MT1111","vendor_code":"TV51","assigned_at":"2026-10-20T09:30:00"},
    {"_row":5,"truck_no":"WB11MT3333","vendor_code":"NOPE"},
    {"_row":6,"truck_no":"WB11MT4444","vendor_code":"TV52","assigned_at":"2026-09-15T10:00:00"},
    {"_row":7,"truck_no":"WB11MT4444","vendor_code":"TV51","assigned_at":"2026-09-05T08:15:00"}]');
  log := log || wh_test.eq('MT: upload counts (created moved skipped errors)',
    (res->>'created') || ' ' || (res->>'updated') || ' ' || (res->>'skipped') || ' ' || jsonb_array_length(res->'errors'), '2 2 1 1');
  log := log || wh_test.eq('MT: upload applies oldest first and a later row moves the truck',
    (select string_agg(vendor_code || ':' || from_date || '→' || coalesce(to_date::text, 'now') || coalesce(' ' || remarks, ''), ' | ' order by from_date) from public.vn_market_truck_list where truck_no = 'WB11MT4444'),
    'TV51:2026-09-05→2026-09-15 | TV52:2026-09-15→now Moved by upload');
  log := log || wh_test.eq('MT: upload keeps the timestamp from the file (India time)',
    (select to_char(assigned_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI') from public.vn_market_trucks where truck_no = 'WB11MT4444' and to_date is null),
    '2026-09-15 10:00');
  log := log || wh_test.eq('MT: upload moves a truck already with another vendor',
    (select vendor_code || ' ' || remarks from public.vn_market_truck_list where truck_no = 'WB11MT1111' and to_date is null),
    'TV51 Moved by upload');
  return log;
end $function$;
