/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 ジャーニー返品補正マスタ（島分割法による注文番号再採番）
  Journey Return Adjustment via Island Method — Intermediate Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. 特典に関わらない返品の除外
     特典の条件は「初回から3本定期」等で2回目や3回目に付与されるが、顧客がその回を
     返品した場合、権利を失うのではなく「次の出荷が実質的にその回としてカウントされ、
     そこで特典が付与される」という運用ルールがある。特典に関わらないタイミングの
     返品だけを狙って除外し、有効な継続回数（注文番号）を繰り上げる。
  2. 連続返品への対応（島分割法）
     「2回目も3回目も連続して返品した」場合に3回目の返品が残ると採番がズレるため、
     初めて返品状態に突入した区間（最初の返品の島）を特定し、連続していようと
     一括で除外対象とする堅牢なロジックを実装する。
  3. コースごとの除外条件分岐
     「初回1本→2本コース」は特例で追加特典対象になっている場合は除外しない、
     「初回1本→3本コース」は3回目からの付与のため無条件で除外する、といった
     コースごとの業務ルールを反映する。

  1. Excluding Returns Irrelevant to Gift Eligibility
     A return of a gift-triggering shipment doesn't forfeit eligibility; the next shipment
     is treated as that milestone instead. This query excludes only the returns that don't
     affect gift eligibility, then renumbers the valid continuation count.
  2. Consecutive Return Handling (Island Method)
     Groups consecutive same-state (return vs. non-return) records into "islands" so that
     multi-shipment consecutive returns are excluded as a single block, preventing numbering
     drift.
  3. Course-Specific Exclusion Rules
     Applies different exclusion conditions depending on the course (e.g., bonus-gift
     recipients are exempt from the standard exclusion).

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
  1. combine_purchase_and_upsell_flags
     ジャーニーと追加特典対象者フラグの結合
  2. create_return_islands
     返品状態による島分割（Island Method）
  3. identify_first_return_island
     「最初の返品の島」の特定
  4. filter_and_recalculate_order_no
     不要な返品の除外と有効回数の再採番
  5. Final Output
     特典対象期間内のデータへの絞り込みと出力

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  Order Level

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  user_id, order_id

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: window functions — running sum island grouping)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 返品補正済ジャーニー中間テーブル
  int_journey_return_adjustment
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [Flag Join] 購入履歴と特例追加特典フラグの結合
--    Data Grain: order_id
----------------------------------------------------------------------
combine_purchase_and_upsell_flags AS (
    SELECT
        a.user_id, a.order_id, a.order_no, a.product_id, a.product_name,
        a.order_status, a.order_status_numbr, a.is_payment_received,
        a.ship_date, a.delivered_date, a.is_sys_return, a.return_completed_date,

        a.is_product_a_first_order, a.is_product_b_first_order,
        a.is_course_3bottle_first, a.is_course_upgraded_1_to_2, a.is_course_upgraded_1_to_3,

        COALESCE(b.is_eligible_for_bonus_gift, 0) AS is_eligible_for_bonus_gift,

        a.product_category, a.subsc_category, a.ship_category,
        a.is_cus_black, a.is_cus_deleted_merged, a.is_cus_merged,
        a.order_type

    FROM
        int_customer_gift_journey_timeline a -- 【前工程】05_int_customer_gift_journey_timeline
        -- (order_no は前工程で出荷日順に採番された継続回数)

    LEFT JOIN
        (
            SELECT user_id, order_id, is_eligible_for_bonus_gift
            FROM int_bonus_gift_upsell_detection -- 【前工程】06_int_bonus_gift_upsell_detection
            WHERE is_eligible_for_bonus_gift = 1
        ) b
    ON a.user_id = b.user_id
    AND a.order_id = b.order_id
),

----------------------------------------------------------------------
-- 2. [Return Islands] 返品状態による島分割（Island Method）
--    Data Grain: order_id
----------------------------------------------------------------------
create_return_islands AS (
    SELECT
        *,
        SUM(CASE
                WHEN is_sys_return <> is_sys_return_before THEN 1
                ELSE 0
            END) OVER(
                PARTITION BY user_id
                ORDER BY ship_date ASC, order_id ASC
            ) + 1 AS island_group_id

    FROM
        (
        SELECT
            *,
            COALESCE(
                LAG(is_sys_return) OVER(
                PARTITION BY user_id
                ORDER BY ship_date ASC, order_id ASC
            ), 0) AS is_sys_return_before
        FROM
            combine_purchase_and_upsell_flags -- 01. の情報
        )
),

----------------------------------------------------------------------
-- 3. [First Return Island] 「最初の返品の島」の特定
--    Data Grain: order_id
----------------------------------------------------------------------
identify_first_return_island AS (
    SELECT
        *,
        CASE
            WHEN island_group_id = 2
             AND island_group_id = min_order_no_in_island THEN 1
            ELSE 0
        END AS is_target_return

    FROM
        (
        SELECT
            *,
            MIN(order_no) OVER(PARTITION BY user_id, island_group_id) AS min_order_no_in_island
        FROM
            create_return_islands
        )
),

----------------------------------------------------------------------
-- 4. [Exclusion & Renumbering] 不要な返品の除外と有効回数の再採番
--    Data Grain: order_id
----------------------------------------------------------------------
filter_and_recalculate_order_no AS (
    SELECT
        *,

        ROW_NUMBER() OVER(
            PARTITION BY user_id
            ORDER BY ship_date ASC, order_id ASC
        ) AS order_no_adjusted,

        LAG(ship_date) OVER(
            PARTITION BY user_id
            ORDER BY ship_date ASC, order_id ASC
        ) AS previous_ship_date

    FROM
        identify_first_return_island -- 03. の情報

    WHERE
        -- 【除外条件1】初回1本→2本コースの「最初の返品(塊)」を除外する（追加特典対象は例外）
        NOT (
            is_target_return = 1
            AND is_course_upgraded_1_to_2 = 1
            AND is_eligible_for_bonus_gift <> 1
            )
        -- 【除外条件2】初回1本→3本コースの「最初の返品(塊)」は無条件で除外する
        AND NOT (
                is_target_return = 1
                AND is_sys_return = 1
                AND is_course_upgraded_1_to_3 = 1
                )
)

----------------------------------------------------------------------
-- 5. [Final Output] 特典対象期間内のデータへの絞り込みと出力
--    Data Grain: order_id
----------------------------------------------------------------------
SELECT
    user_id                        AS "ユーザーID",
    order_id                       AS "注文ID",
    order_no_adjusted              AS "注文番号",
    product_id                     AS "商品ID",
    product_name                   AS "商品名",
    order_status                   AS "注文ステータス",
    order_status_numbr             AS "受注明細状態",
    is_payment_received            AS "入金済フラグ",
    ship_date                      AS "出荷日",
    delivered_date                 AS "配達完了日",
    is_sys_return                  AS "返品フラグ_システム基準",
    return_completed_date          AS "返品受付日",
    previous_ship_date             AS "前回出荷日",
    is_product_a_first_order       AS "商品ラインA_新規フラグ",
    is_product_b_first_order       AS "商品ラインB_新規フラグ",

    is_course_3bottle_first        AS "初回3本_定期フラグ",
    is_course_upgraded_1_to_2      AS "初回1本→2本_定期フラグ",
    is_course_upgraded_1_to_3      AS "初回1本→3本_定期フラグ",
    is_eligible_for_bonus_gift     AS "追加特典ダミー_同梱フラグ",
    product_category               AS "商品_分類",
    subsc_category                 AS "定期_分類",

    CASE
        WHEN ship_category IS NULL THEN order_no_adjusted || '回目出荷'
        ELSE ship_category
    END AS "出荷_分類",

    is_cus_black                   AS "ブラックフラグ",
    is_cus_deleted_merged          AS "削除/統合フラグ",
    is_cus_merged                  AS "顧客統合フラグ",
    order_type                     AS "注文分類"

FROM
    filter_and_recalculate_order_no -- 04. の情報

WHERE
    -- 【特典対象期間フィルタ】コースごとの付与完了回数以降の不要なデータは切り捨てる
    (
    is_course_3bottle_first = 1
    AND order_no_adjusted < 4
    )
  OR
    (
    (is_course_upgraded_1_to_2 = 1 OR is_course_upgraded_1_to_3 = 1)
    AND order_no_adjusted < 5
    )

ORDER BY
    user_id ASC, ship_date ASC
;
