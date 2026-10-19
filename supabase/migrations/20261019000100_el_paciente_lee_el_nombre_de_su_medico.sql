-- ============================================================================
-- Helios — El paciente lee el nombre de su médico, no el de la clínica
-- (2026-10-19, decidido por Javier)
--
-- Los nombres de las clínicas no le dicen nada al paciente («608», «3j»,
-- «Edificio Torre 18, piso 5…»). Los WhatsApp al paciente nombran al médico:
-- «la Dra. Nadia Khabbaze».
--
-- 1. `merchants.doctor_display_name`: cómo se nombra al médico ante el
--    paciente, con su tratamiento («Dra. Nadia Khabbaze», «Lcda. …»). Texto
--    libre: el sistema no sabe si es Dr. o Dra. Vacío, el nombre de la
--    clínica. Se edita en la ficha de la clínica (superadmin › Médico
--    titular) y las 15 clínicas de hoy quedan con los nombres que aprobó
--    Javier.
-- 2. `helios_doctor_name(merchant)` → «Dra. Nadia Khabbaze»;
--    `helios_doctor_ref(merchant)` → «la Dra. Nadia Khabbaze», para escribir
--    «de la consulta con {medico}». El nombre de una clínica va tal cual.
-- 3. La ficha lo lee (`admin_merchant_detail`) y lo guarda
--    (`admin_set_merchant_owner`, clave `doctor_display_name`).
-- ============================================================================

alter table public.merchants
  add column if not exists doctor_display_name text;

alter table public.merchants
  drop constraint if exists merchants_doctor_display_name_len;
alter table public.merchants
  add constraint merchants_doctor_display_name_len
  check (doctor_display_name is null or length(doctor_display_name) between 3 and 80);

comment on column public.merchants.doctor_display_name is
  'Cómo se nombra al médico ante el paciente, con su tratamiento («Dra. Nadia Khabbaze»). Vacío: el nombre de la clínica.';

-- Los nombres aprobados por Javier el 2026-10-19 (con el titular, para no
-- tocar otra clínica con el mismo nombre).
update public.merchants m
   set doctor_display_name = v.medico, updated_at = now()
  from (values
    ('Consultorio Dra. Cecil Palmero',              'Cecil Palmero',                        'Dra. Cecil Palmero'),
    ('Consultorio Dra. Nadia Khabbaze',             'Nadia Andi Khabbaze Alfaro',           'Dra. Nadia Khabbaze'),
    ('Consultorio Dr. AROLDO MACAREÑO STELLING',    'AROLDO MACAREÑO STELLING',             'Dr. Aroldo Macareño'),
    ('Carlos Cuenca',                               'Carlos Eduardo Cuenca Cabello',        'Dr. Carlos Cuenca'),
    ('Consultorio clínica los altos 5',             'Carlos Hafouri',                       'Dr. Carlos Hafouri'),
    ('Consultorio 103',                             'Jesus francisco vivas rodriguez',      'Dr. Jesús Vivas'),
    ('608',                                         'Andrea paola betancourt garrido',      'Dra. Andrea Betancourt'),
    ('ÓPTICA GIROS 2020 CA',                        'Dilia Maria Pereira Mujica',           'Dra. Dilia Pereira'),
    ('3j',                                          'Gustavo jose villasmil prieto',        'Dr. Gustavo Villasmil'),
    ('Hospital de Clínicas Caracas',                'Jesús Contreras S',                    'Dr. Jesús Contreras'),
    ('Derma Skin E&M',                              'Elizabeth Del valle ponte Castillo',   'Lcda. Elizabeth Ponte'),
    ('Jackson Arias',                               'Jackson arias',                        'Dr. Jackson Arias'),
    ('Edificio Torre 18, piso 5, consultorio 5F.',  'Alejandra Jackeline Vasquez Arrieche', 'Dra. Alejandra Vásquez'),
    ('Edgard castillo',                             'Edgard jose castillo gallardo',        'Dr. Edgard Castillo'),
    ('Dr. Hiram Rafael Padron',                     'Hiram Rafael Padron',                  'Dr. Hiram Padrón')
  ) as v(clinica, titular, medico)
 where m.name = v.clinica and m.owner_name = v.titular and m.doctor_display_name is null;

-- ---------------------------------------------------------------------------
-- 2. Cómo se nombra
-- ---------------------------------------------------------------------------

create or replace function public.helios_doctor_name(p_merchant_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(nullif(btrim(m.doctor_display_name), ''), m.name)
  from public.merchants m where m.id = p_merchant_id;
$$;

-- «la Dra. Nadia Khabbaze», «el Dr. Hiram Padrón», «la Lcda. …». Sin
-- tratamiento delante (el nombre de una clínica), tal cual.
create or replace function public.helios_doctor_ref(p_merchant_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case
           when n ~* '^(dra|lcda|licda|lda)\.?\s' then 'la ' || n
           when n ~* '^(dr|lcdo|licdo|ldo)\.?\s'  then 'el ' || n
           else n
         end
  from (select public.helios_doctor_name(p_merchant_id) as n) x;
$$;

revoke all on function public.helios_doctor_name(uuid) from public, anon, authenticated;
revoke all on function public.helios_doctor_ref(uuid) from public, anon, authenticated;
grant execute on function public.helios_doctor_name(uuid) to service_role;
grant execute on function public.helios_doctor_ref(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 3. La ficha de la clínica
-- ---------------------------------------------------------------------------

create or replace function public.admin_merchant_detail(p_merchant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_merchant public.merchants%rowtype;
  v_terms    public.merchant_settlement_terms%rowtype;
  v_staff    jsonb;
  v_owed     numeric(18,4);
begin
  if not public.is_platform_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  select * into v_merchant from public.merchants where id = p_merchant_id;
  if not found then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;

  select * into v_terms from public.merchant_settlement_terms
  where merchant_id = p_merchant_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', mu.user_id,
    'name', coalesce(nullif(trim(au.raw_user_meta_data ->> 'full_name'), ''), au.email),
    'email', au.email,
    'phone', au.phone,
    'role', mu.role,
    'branch', b.name
  ) order by mu.created_at), '[]'::jsonb) into v_staff
  from public.merchant_users mu
  join auth.users au on au.id = mu.user_id
  left join public.merchant_branches b on b.id = mu.branch_id
  where mu.merchant_id = p_merchant_id and mu.is_active;

  -- La misma cuenta que el guardia de `terminated`: es la cifra que la ficha
  -- enseña como «Le debes X» y la que decide si el botón de Terminar está vivo.
  select coalesce(sum(amount_usd - paid_usd), 0) into v_owed
  from public.settlements
  where merchant_id = p_merchant_id and status in ('pending', 'partial');

  return jsonb_build_object(
    'profile', jsonb_build_object(
      'category', v_merchant.category,
      'city', v_merchant.city,
      'handle', v_merchant.handle,
      'logo_url', v_merchant.logo_url,
      'social_url', v_merchant.social_url,
      'tax_id', v_merchant.tax_id,
      'specialty', v_merchant.specialty,
      'mpps_number', v_merchant.mpps_number,
      'phone', v_merchant.phone,
      'email', v_merchant.email,
      'address', v_merchant.address,
      -- (2026-10-09): el titular.
      'owner_name', v_merchant.owner_name,
      'owner_document', v_merchant.owner_document,
      'college_number', v_merchant.college_number,
      -- NUEVO (2026-10-19): cómo lo lee el paciente.
      'doctor_display_name', v_merchant.doctor_display_name
    ),
    'terms', jsonb_build_object(
      'upfront_pct', v_terms.upfront_pct,
      'per_installment_pct', v_terms.per_installment_pct,
      'commission_pct', v_terms.commission_pct,
      'policy', v_terms.policy,
      -- Helios: la comisión pactada (null = la global) y la que se aplica hoy.
      'staff_commission_usd', (select t.staff_commission_usd
                                 from public.helios_terms_at(p_merchant_id, public.helios_business_date(now())) t),
      'staff_commission_effective_usd', public.helios_staff_commission_for(p_merchant_id, public.helios_business_date(now()))
    ),
    'staff', v_staff,
    'pending_usd', v_owed,
    'payout_account', public.admin_merchant_payout_account(p_merchant_id)
  );
end;
$$;

-- `p`: las claves que se tocan. Ausente o null = no tocar; '' = borrar (salvo
-- el nombre del titular, que no se borra).
create or replace function public.admin_set_merchant_owner(p_merchant_id uuid, p jsonb)
returns void
language plpgsql
security definer
set search_path = public, audit, pg_temp
as $$
declare
  v_actor  uuid := public.helios_assert_super_admin('editar clínicas');
  v_nombre text := nullif(btrim(regexp_replace(p->>'owner_name', '\s+', ' ', 'g')), '');
  v_raw    text := btrim(p->>'owner_document');
  v_doc    text;
  v_col    text := btrim(p->>'college_number');
  v_medico text := btrim(regexp_replace(p->>'doctor_display_name', '\s+', ' ', 'g'));
begin
  if v_nombre is not null and (length(v_nombre) < 3 or length(v_nombre) > 120) then
    raise exception 'El nombre del titular no es válido' using errcode = '22023';
  end if;
  if nullif(v_raw, '') is not null then
    v_doc := public.helios_documento(v_raw, 'VEP');
    if v_doc is null then
      raise exception 'La cédula o el pasaporte del titular no parecen válidos' using errcode = '22023';
    end if;
  elsif v_raw = '' then
    v_doc := '';
  end if;
  if v_col is not null and length(v_col) > 30 then
    raise exception 'El número del Colegio es demasiado largo' using errcode = '22023';
  end if;
  if v_medico <> '' and (length(v_medico) < 3 or length(v_medico) > 80) then
    raise exception 'El nombre para el paciente debe tener entre 3 y 80 caracteres' using errcode = '22023';
  end if;

  update public.merchants
     set owner_name          = coalesce(v_nombre, owner_name),
         owner_document      = case when v_doc is null then owner_document else nullif(v_doc, '') end,
         college_number      = case when v_col is null then college_number else nullif(v_col, '') end,
         doctor_display_name = case when v_medico is null then doctor_display_name else nullif(v_medico, '') end,
         updated_at          = now()
   where id = p_merchant_id;

  if not found then
    raise exception 'Clínica no encontrada' using errcode = 'P0002';
  end if;

  perform audit.log(v_actor, 'merchant.set_owner', p_merchant_id, jsonb_build_object(
    'owner_name', v_nombre, 'owner_document', v_doc, 'college_number', v_col,
    'doctor_display_name', v_medico));
end;
$$;

revoke all on function public.admin_merchant_detail(uuid) from public, anon;
grant execute on function public.admin_merchant_detail(uuid) to authenticated;
revoke all on function public.admin_set_merchant_owner(uuid, jsonb) from public, anon;
grant execute on function public.admin_set_merchant_owner(uuid, jsonb) to authenticated;
