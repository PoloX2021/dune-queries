with

bonding_pools (pool, pool_name, initial_funder) as (
    select
        from_hex('0x8353713b6D2F728Ed763a04B886B16aAD2b16eBD') as pool,
        'Gnosis' as pool_name,
        from_hex('0x6c642cafcbd9d8383250bb25f67ae409147f78b2') as initial_funder
    union all
    select
        from_hex('0x5d4020b9261F01B6f8a45db929704b0Ad6F5e9E6') as pool,
        'CoW Services' as pool_name,
        from_hex('0x423cec87f19f0778f549846e0801ee267a917935') as initial_funder
),

first_event_after_timestamp as (
    select max(number)
    from
        ethereum.blocks
    where
        time > cast('2024-08-20 00:00:00' as timestamp) -- CIP-48 starts bonding pool timer at midnight UTC on 20/08/24
),

initial_vouches as (
    select
        evt_block_number,
        evt_index,
        solver,
        cowrewardtarget,
        bondingpool,
        sender,
        true as active,
        rank() over (
            partition by
                solver,
                bondingpool,
                sender
            order by
                evt_block_number asc,
                evt_index asc
        ) as rk
    from
        cow_protocol_ethereum.VouchRegister_evt_Vouch
    where
        evt_block_number <= (
            select *
            from
                first_event_after_timestamp
        )
        and bondingpool in (
            select pool
            from
                bonding_pools
        )
        and sender in (
            select initial_funder
            from
                bonding_pools
        )
),

joined_on_data as (
    select
        iv.solver,
        iv.cowrewardtarget as reward_target,
        iv.bondingpool as pool,
        iv.evt_block_number,
        iv.evt_index,
        iv.rk,
        true as active
    from
        initial_vouches as iv
    where
        iv.rk = 1
),

latest_vouches as (
    select
        evt_block_number,
        evt_index,
        solver,
        cowrewardtarget,
        bondingpool,
        sender,
        rank() over (
            partition by
                solver,
                bondingpool,
                sender
            order by
                evt_block_number desc,
                evt_index desc
        ) as rk,
        coalesce(event_type = 'Vouch', false) as active
    from
        (
            select
                evt_block_number,
                evt_index,
                solver,
                cowrewardtarget,
                bondingpool,
                sender,
                'Vouch' as event_type
            from
                cow_protocol_ethereum.VouchRegister_evt_Vouch
            where
                evt_block_number <= (
                    select *
                    from
                        first_event_after_timestamp
                )
                and bondingpool in (
                    select pool
                    from
                        bonding_pools
                )
                and sender in (
                    select initial_funder
                    from
                        bonding_pools
                )
            union distinct
            select
                evt_block_number,
                evt_index,
                solver,
                null as cowrewardtarget, -- Invalidation does not have a reward target
                bondingpool,
                sender,
                'InvalidateVouch' as event_type
            from
                cow_protocol_ethereum.VouchRegister_evt_InvalidateVouch
            where
                evt_block_number <= (
                    select *
                    from
                        first_event_after_timestamp
                )
                and bondingpool in (
                    select pool
                    from
                        bonding_pools
                )
                and sender in (
                    select initial_funder
                    from
                        bonding_pools
                )
        ) as unioned_events
),

valid_vouches as (
    select
        lv.solver,
        lv.cowrewardtarget as reward_target,
        lv.bondingpool as pool
    from
        latest_vouches as lv
    where
        lv.rk = 1
        and lv.active = true
),

joined_on as (
    select
        jd.solver,
        jd.reward_target,
        jd.pool,
        bp.pool_name,
        b.time as joined_on
    from
        joined_on_data as jd
    inner join ethereum.blocks as b on jd.evt_block_number = b.number
    inner join bonding_pools as bp on jd.pool = bp.pool
),

named_results as (
    select
        jd.solver,
        jd.pool_name,
        jd.pool,
        jd.joined_on,
        concat(environment, '-', s.name) as solver_name,
        date_diff('day', date(jd.joined_on), date(now())) as days_in_pool
    from
        joined_on as jd
    inner join cow_protocol_ethereum.solvers as s on jd.solver = s.address
    inner join valid_vouches
        as vv on jd.solver = vv.solver
    and jd.pool = vv.pool
),

ranked_named_results as (
    select
        nr.solver,
        nr.solver_name,
        nr.pool_name,
        nr.pool,
        nr.joined_on,
        nr.days_in_pool,
        row_number() over (
            partition by
                nr.solver_name
            order by
                nr.joined_on desc
        ) as rn,
        count(*) over (
            partition by
                nr.solver_name
        ) as solver_name_count
    from
        named_results as nr
),

filtered_named_results as (
    select
        rnr.solver,
        rnr.solver_name,
        rnr.pool,
        rnr.joined_on,
        rnr.days_in_pool,
        case
            when rnr.solver_name_count > 1 then 'Colocation'
            else rnr.pool_name
        end as pool_name,
        case
            when rnr.solver_name_count > 1 then date_add('month', 3, rnr.joined_on) -- Add 3 month grace period for colocated solvers
            else greatest(
                date_add('month', 6, rnr.joined_on), -- Add 6 month grace period to joined_on for non colocated solvers
                timestamp '2024-08-20 00:00:00' -- Introduction of CIP-48
            )
        end as expires
    from
        ranked_named_results as rnr
    where
        rnr.rn = 1
)

select
    fnr.solver,
    fnr.solver_name,
    fnr.pool_name,
    fnr.pool,
    fnr.joined_on,
    fnr.days_in_pool,
    case
        when fnr.pool_name = 'Gnosis' then timestamp '2028-10-08 00:00:00'
        else fnr.expires
    end as expires,
    coalesce(
        now() > fnr.expires
        and fnr.pool_name != 'Gnosis', false
    ) as service_fee
from
    filtered_named_results as fnr;