-- ==========================================================
-- LEDS REGISTRY - LANDBANK ACCOUNT VERIFICATION UPDATE
-- Run this in Supabase > SQL Editor > New Query
-- ==========================================================

-- 1) Add separate LBP verification fields to the master table.
alter table public.leds_applicants
add column if not exists lbp_account_verification_status text
    not null default 'NOT CHECKED'
    check (lbp_account_verification_status in (
        'NOT CHECKED',
        'VERIFIED',
        'CORRECTION REQUESTED',
        'ACCOUNT SUBMISSION PENDING'
    ));

alter table public.leds_applicants
add column if not exists lbp_account_verified_at timestamptz;


-- 2) Recreate the secure public lookup.
--    This intentionally returns the FULL LBP account/reference number
--    after all six applicant lookup fields match.

drop function if exists public.lookup_leds_applicant(
    text, text, text, text, text, text
);

create function public.lookup_leds_applicant(
    p_last_name text,
    p_first_name text,
    p_middle_name text,
    p_extension_name text,
    p_year_level text,
    p_barangay text
)
returns table (
    public_id uuid,
    full_name text,
    barangay text,
    school text,
    year_level text,
    other_govt_scholarships text,
    lacking_documents text,
    applicant_type text,
    masked_contact_number text,
    lbp_account_number text,
    lbp_reference_number text,
    verification_status text,
    lbp_account_verification_status text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
    return query
    select
        a.public_id,
        coalesce(
            nullif(trim(a.full_name), ''),
            trim(concat_ws(
                ' ',
                a.first_name,
                a.middle_name,
                a.last_name,
                a.extension_name
            ))
        )::text,
        a.barangay::text,
        a.school::text,
        a.year_level::text,
        a.other_govt_scholarships::text,
        a.lacking_documents::text,
        a.applicant_type::text,

        case
            when nullif(
                regexp_replace(coalesce(a.contact_number,''), '\D', '', 'g'),
                ''
            ) is null
            then null
            else
                left(regexp_replace(a.contact_number, '\D', '', 'g'), 2)
                ||
                repeat(
                    '•',
                    greatest(
                        length(regexp_replace(a.contact_number, '\D', '', 'g')) - 6,
                        0
                    )
                )
                ||
                right(regexp_replace(a.contact_number, '\D', '', 'g'), 4)
        end::text,

        nullif(trim(a.lbp_account_number), '')::text,
        nullif(trim(a.lbp_reference_number), '')::text,
        a.verification_status::text,
        a.lbp_account_verification_status::text

    from public.leds_applicants a
    where lower(trim(a.last_name)) = lower(trim(p_last_name))
      and lower(trim(a.first_name)) = lower(trim(p_first_name))
      and lower(trim(coalesce(a.middle_name,''))) =
          lower(trim(coalesce(p_middle_name,'')))
      and lower(trim(coalesce(a.extension_name,''))) =
          lower(trim(coalesce(p_extension_name,'')))
      and lower(trim(a.year_level)) = lower(trim(p_year_level))
      and lower(trim(a.barangay)) = lower(trim(p_barangay))
    limit 2;
end;
$$;

revoke all
on function public.lookup_leds_applicant(text,text,text,text,text,text)
from public;

grant execute
on function public.lookup_leds_applicant(text,text,text,text,text,text)
to anon, authenticated;


-- 3) Function for a student to confirm the encoded LBP account number.
drop function if exists public.confirm_leds_lbp_account(uuid);

create function public.confirm_leds_lbp_account(
    p_public_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_applicant_id bigint;
begin
    select id
      into v_applicant_id
      from public.leds_applicants
     where public_id = p_public_id
       and nullif(trim(lbp_account_number), '') is not null;

    if v_applicant_id is null then
        return false;
    end if;

    update public.leds_applicants
       set lbp_account_verification_status = 'VERIFIED',
           lbp_account_verified_at = now()
     where id = v_applicant_id;

    return true;
end;
$$;

revoke all
on function public.confirm_leds_lbp_account(uuid)
from public;

grant execute
on function public.confirm_leds_lbp_account(uuid)
to anon, authenticated;


-- 4) Update correction-request RPC to allow:
--    - correction of an existing LBP account number
--    - submission of an LBP account number when none is on record
--    - correction/submission of an LBP reference number

drop function if exists public.submit_leds_correction(
    uuid, text, text, text, text, text
);

create function public.submit_leds_correction(
    p_public_id uuid,
    p_field_to_correct text,
    p_current_information text,
    p_requested_information text,
    p_reason text default null,
    p_requester_contact text default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_applicant_id bigint;
    v_request_id bigint;
    v_current_lbp text;
begin
    select id, nullif(trim(lbp_account_number), '')
      into v_applicant_id, v_current_lbp
      from public.leds_applicants
     where public_id = p_public_id;

    if v_applicant_id is null then
        raise exception 'Applicant record not found';
    end if;

    if p_field_to_correct not in (
        'barangay',
        'last_name',
        'first_name',
        'middle_name',
        'extension_name',
        'full_name',
        'other_govt_scholarships',
        'lacking_documents',
        'school',
        'year_level',
        'contact_number',
        'applicant_type',
        'lbp_account_number',
        'lbp_reference_number'
    ) then
        raise exception 'This field cannot be submitted for correction';
    end if;

    if nullif(trim(coalesce(p_requested_information,'')), '') is null then
        raise exception 'Requested information is required';
    end if;

    insert into public.leds_correction_requests (
        applicant_id,
        field_to_correct,
        current_information,
        requested_information,
        reason,
        requester_contact
    )
    values (
        v_applicant_id,
        p_field_to_correct,
        p_current_information,
        p_requested_information,
        p_reason,
        p_requester_contact
    )
    returning id into v_request_id;

    if p_field_to_correct = 'lbp_account_number' then
        update public.leds_applicants
           set lbp_account_verification_status =
               case
                   when v_current_lbp is null
                   then 'ACCOUNT SUBMISSION PENDING'
                   else 'CORRECTION REQUESTED'
               end
         where id = v_applicant_id;
    else
        update public.leds_applicants
           set verification_status = 'CORRECTION REQUESTED'
         where id = v_applicant_id;
    end if;

    insert into public.leds_verification_logs (
        applicant_id,
        action
    )
    values (
        v_applicant_id,
        'CORRECTION_REQUESTED'
    );

    return v_request_id;
end;
$$;

revoke all
on function public.submit_leds_correction(
    uuid, text, text, text, text, text
)
from public;

grant execute
on function public.submit_leds_correction(
    uuid, text, text, text, text, text
)
to anon, authenticated;


-- 5) Verification check
select
    count(*) as total_applicants,
    count(*) filter (
        where nullif(trim(lbp_account_number), '') is not null
    ) as with_lbp_account,
    count(*) filter (
        where nullif(trim(lbp_account_number), '') is null
    ) as without_lbp_account
from public.leds_applicants;
