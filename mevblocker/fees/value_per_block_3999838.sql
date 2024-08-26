-- Computes the value MEV Blocker transactions contribute for each block
-- Parameters:
--  {{start}} - the timestamp for which the analysis should start (inclusively)
--  {{end}} - the timestamp for which the analysis should end (exclusively)

WITH block_range AS (
    SELECT
        MIN(number) AS start_block,
        MAX(number) + 1 AS end_block -- range is exclusive
    FROM ethereum.blocks
    WHERE
        time >= TIMESTAMP '{{start}}'
        AND time < TIMESTAMP '{{end}}'
),

-- perfomance optimisation: all mempool tx according to flashbots during that timeframe
mempool AS (
    SELECT DISTINCT hash
    FROM dune.flashbots.dataset_mempool_dumpster
    WHERE
        included_at_block_height >= (SELECT start_block FROM block_range)
        AND included_at_block_height < (SELECT end_block FROM block_range)

),

-- perfomance optimisation: relevant mev blocker bundles during that timeframe
mev_blocker_filtered AS (
    SELECT *
    FROM mevblocker.raw_bundles
    WHERE
        blocknumber >= (SELECT start_block FROM block_range)
        AND blocknumber < (SELECT end_block FROM block_range)
),

-- perfomance optimisation: relevant ethereum transactions during that timeframe
ethereum_transactions_filtered AS (
    SELECT *
    FROM ethereum.transactions
    WHERE
        block_number >= (SELECT start_block FROM block_range)
        AND block_number < (SELECT end_block FROM block_range)
),

-- all mev blocker tx that made it on chain
mev_blocker_tx AS (
    SELECT
        jt.row_number,
        et."from" AS tx_from,
        et.index,
        et.block_number,
        et.block_time,
        et.gas_used,
        et.gas_price,
        FROM_HEX(CAST(JSON_EXTRACT(mb.transactions, '$[0].hash') AS VARCHAR)) AS tx_1,
        FROM_HEX(CAST(JSON_EXTRACT(mb.transactions, '$[0].from') AS VARCHAR)) AS tx_from_1,
        FROM_HEX(jt.hash) AS hash
    FROM
        mev_blocker_filtered AS mb
    CROSS JOIN
        JSON_TABLE(
            mb.transactions,
            'lax $[*]' COLUMNS(
                row_number for ordinality,
                hash VARCHAR(255) PATH 'lax $.hash'
            )
        ) AS jt
    INNER JOIN ethereum_transactions_filtered AS et
        ON FROM_HEX(jt.hash) = et.hash
    WHERE
        block_number >= (SELECT start_block FROM block_range)
        AND block_number < (SELECT end_block FROM block_range)
    -- remove duplicates
    GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
),

-- find last tx in mev blocker bundle 
-- based on the assumption that only the last tx in a bundle can be a searcher transaction
last_tx_in_bundle AS (
    SELECT
        tx_1,
        MAX(row_number) AS last_tx_number,
        MIN(row_number) AS first_row
    FROM mev_blocker_tx
    GROUP BY 1
),

-- find which of the last tx in a bundle are not from the same address AS the original tx 
-- assume these are searcher tx
searcher_txs AS (
    SELECT
        m.tx_1,
        m.hash AS search_tx,
        m.index,
        m.block_number,
        m.block_time
    FROM mev_blocker_tx AS m
    INNER JOIN last_tx_in_bundle AS l
        ON
            m.tx_1 = l.tx_1
            AND last_tx_number = row_number
            AND first_row = 1 -- making sure the original transaction happened
    WHERE tx_from != tx_from_1
),

kickback_txs AS (
    SELECT
        et.block_time,
        et.block_number,
        et.hash,
        st.search_tx,
        st.tx_1 AS target_tx,
        value AS backrun_value_wei,
        CAST(et.gas_used AS UINT256) * (et.gas_price - COALESCE(b.base_fee_per_gas, 0)) AS backrun_tip_wei
    FROM searcher_txs AS st
    INNER JOIN ethereum_transactions_filtered AS et
        ON
            st.block_number = et.block_number
            AND st.index + 1 = et.index
    INNER JOIN ethereum.blocks AS b
        ON
            st.block_number = number
            AND et."from" = b.miner
    WHERE
        et.block_number >= (SELECT start_block FROM block_range)
        AND et.block_number < (SELECT end_block FROM block_range)
),

-- all original (user) transactions, calculating the tip of these transactions
-- excluding transactions that were in the public mempool
user_txs AS (
    SELECT
        tx.block_time,
        tx.block_number,
        tx.hash,
        CAST(tx.gas_used AS UINT256) * (tx.gas_price - COALESCE(b.base_fee_per_gas, 0)) AS user_tip_wei
    FROM mev_blocker_tx AS tx
    LEFT JOIN ethereum.blocks AS b ON block_number = number
    WHERE
        tx.hash NOT IN (SELECT search_tx FROM searcher_txs)
        AND CAST(tx.hash AS VARCHAR) NOT IN (SELECT hash FROM mempool)
    -- deduplicate approve txs that appear in bundles and individually
    GROUP BY 1, 2, 3, 4
),

user_txs_per_block AS (
    SELECT
        b.time AS block_time,
        b.number AS block_number,
        SUM(user_tip_wei) AS user_tip_wei,
        ARRAY_AGG(ut.hash) AS user_txs
    FROM ethereum.blocks AS b
    INNER JOIN user_txs AS ut ON b.number = ut.block_number
    GROUP BY 1, 2
),

kickback_txs_per_block AS (
    SELECT
        b.time AS block_time,
        b.number AS block_number,
        SUM(COALESCE(k.backrun_value_wei, 0)) AS backrun_value_wei,
        SUM(COALESCE(k.backrun_tip_wei, 0)) AS backrun_tip_wei,
        ARRAY_AGG(k.search_tx) AS searcher_txs,
        ARRAY_AGG(k.hash) AS kickback_txs
    FROM ethereum.blocks AS b
    INNER JOIN kickback_txs AS k ON b.number = k.block_number
    GROUP BY 1, 2
)

-- final calculation of the fee per block 
-- the calculation: 20% of (original_tx_tip + 1/9 of backrun value)
SELECT
    ut.block_time,
    ut.block_number,
    user_tip_wei,
    backrun_value_wei,
    backrun_tip_wei,
    user_txs,
    searcher_txs,
    kickback_txs,
    CAST(0.2 * (user_tip_wei + (COALESCE(k.backrun_tip_wei + k.backrun_value_wei, 0) / 9)) AS UINT256) AS block_fee_wei
FROM user_txs_per_block AS ut
LEFT JOIN kickback_txs_per_block AS k ON ut.block_number = k.block_number
