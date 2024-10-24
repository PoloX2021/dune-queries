3641173--Error: Query is too long for wand tools. 
--Try shortening query to try again. 
-- BATCH REWARDS
with
  batch_rewards as (
    select
      date_add('day', 1, date_trunc('week', date_add('day', -1, time))) as week_start,
      winning_solver as solver,
      case
        when time >= cast('2024-03-19 12:00:00' as timestamp) then reward -- switch to CIP-38
        else reward - execution_cost
      end as reward,
      case
        when time >= cast('2024-07-23 00:00:00' as timestamp) then 'CIP-48' -- switch to CIP-48
        when time >= cast('2024-03-19 12:00:00' as timestamp) then 'CIP-38' -- switch to CIP-38
        when time >= cast('2024-02-06 00:00:00' as timestamp) then 'CIP-36' -- switch to CIP-36
        else 'CIP-27'
      end as cip,
      participating_solvers
    from
      query_2777544 bs
      join ethereum.blocks eb on bs.block_deadline = eb.number
    where
      time >= cast('2023-07-18 00:00:00' as timestamp) -- start of analysis
  ),
  participation_data as (
    SELECT 
      week_start,
      participant
    FROM batch_rewards br
    CROSS JOIN UNNEST(br.participating_solvers) AS t(participant)
  ),
  participation_counts as (
    SELECT
      week_start,
      participant as solver, 
      count(*) as num_participating_batches
    FROM participation_data
    group by
      week_start, participant
  ),
  batch_rewards_aggregate as (
    select
      br.week_start,
      br.solver,
      sum(reward) as performance_reward,
      max(num_participating_batches) as num_participating_batches, -- there is only one value and the maximum selects it
      max(cip) as cip -- there is only one value and the maximum selects it
    from
      batch_rewards br
    join participation_counts pc on br.week_start = pc.week_start and br.solver = pc.solver
    group by
      br.week_start, br.solver
  ),
  week_data as (
    select
      week_start,
      max(cip) as cip, -- there is only one value and the maximum selects it
      sum(performance_reward) as performance_reward,
      sum(num_participating_batches) as num_participating_batches
    from
      batch_rewards_aggregate
    group by
      week_start
  ),
  week_data_with_caps as (
    select
      *,
      case
        when cip = 'CIP-48' then 250000 -- switch to CIP-48
        when cip = 'CIP-38' then 250000 -- switch to CIP-38
        when cip = 'CIP-36' then 250000 -- switch to CIP-36
        else 306307-- 'CIP-27'
      end as reward_budget_cow,
      case
        when cip = 'CIP-48' then 0 -- switch to CIP-48
        when cip = 'CIP-38' then 6 -- switch to CIP-38
        when cip = 'CIP-36' then 6 -- switch to CIP-36
        else 1000 -- actually no cap in CIP-27
      end as consistency_cap_eth,
      case
        when cip = 'CIP-48' then 6 -- switch to CIP-38
        when cip = 'CIP-38' then 6 -- switch to CIP-38
        when cip = 'CIP-36' then 6 -- switch to CIP-36
        else 9 -- 'CIP-27'
      end as quote_reward_cow,
      case
        when cip = 'CIP-48' then 0.0006 -- switch to CIP-38
        when cip = 'CIP-38' then 0.0006 -- switch to CIP-38
        when cip = 'CIP-36' then 0.0006 -- switch to CIP-36
        else 1000 -- actually no cap in CIP-27
      end as quote_cap_eth
    from week_data
  ),
  conversion_prices as (
    select
      week_start,
      (
        select
          avg(price)
        from
          prices.usd
        where
          blockchain = 'ethereum'
          and contract_address = 0xdef1ca1fb7fbcdc777520aa7f396b4e015f497ab
          and date(minute) = date_add('day', 6, week_start)
      ) as cow_price,
      (
        select
          avg(price)
        from
          prices.usd
        where
          blockchain = 'ethereum'
          and contract_address = 0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2
          and date(minute) = date_add('day', 6, week_start)
      ) as eth_price
    from
      week_data
  ),
  -- BEGIN QUOTE REWARDS
  order_quotes as (
    select
      date_add('day', 1, date_trunc('week', date_add('day', -1, time))) as week_start,
      quote_solver as solver
    from
      query_3373259
      join ethereum.blocks on block_number = number
    where
      time >= cast('2023-07-18 00:00:00' as timestamp) -- start of analysis
      AND quote_solver != 0x0000000000000000000000000000000000000000
  ),
  quote_numbers as (
    select
      week_start,
      solver,
      count(*) as num_quotes
    from
      order_quotes
    group by
      week_start, solver
  ),
  results as (
    select
      batch_rewards_aggregate.week_start,
      batch_rewards_aggregate.solver,
      concat(cow_protocol_ethereum.solvers.environment, '-', cow_protocol_ethereum.solvers.name) as solver_name,
      eth_price / cow_price * batch_rewards_aggregate.performance_reward / pow(10, 18) as performance_reward,
      GREATEST(
        0,
        LEAST(
          eth_price / cow_price * consistency_cap_eth,
          reward_budget_cow - eth_price / cow_price * week_data_with_caps.performance_reward / pow(10, 18)
        )
      ) * batch_rewards_aggregate.num_participating_batches / week_data_with_caps.num_participating_batches as consistency_reward,
      LEAST(quote_reward_cow, quote_cap_eth * eth_price / cow_price) * num_quotes as quote_reward
    from
      batch_rewards_aggregate
      left outer join quote_numbers on quote_numbers.week_start = batch_rewards_aggregate.week_start
          and batch_rewards_aggregate.solver = quote_numbers.solver
      left outer join week_data_with_caps on week_data_with_caps.week_start = batch_rewards_aggregate.week_start
      left outer join conversion_prices on batch_rewards_aggregate.week_start = conversion_prices.week_start
      left outer join cow_protocol_ethereum.solvers on cow_protocol_ethereum.solvers.address = batch_rewards_aggregate.solver
  )
select
  *
from
  results
order by
  week_start, solver