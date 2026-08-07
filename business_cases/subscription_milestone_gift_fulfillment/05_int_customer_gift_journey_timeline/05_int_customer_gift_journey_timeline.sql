/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 顧客ジャーニー統合タイムラインマスタ
  Customer Gift Journey Timeline Integration — Intermediate Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. F1属性の全履歴への伝播
     F1レコードのみが持つ「初期コースのフラグ」を、F2以降の実績・未来の予定にも
     コピー（伝播）させることで、後続クエリがどのレコードでも一発でコース条件を評価できるようにする。
  2. 実績と未来予定の統合タイムライン化
     すでに出荷済みの実績（F1・F2以降）だけでなく、定期マスタから取得した
     「未来の出荷予定日」も同じタイムライン上に縦積み（UNION ALL）する。
  3. 同日複数注文の安全な合算
     同日内に複数注文が発生した場合、返品状況を踏まえて「代表注文」を1件特定し、
     その属性を同日内の全レコードに伝播させることでマーケティング評価のブレを防ぐ。
  4. 継続回数の再採番
     F1を起点として、出荷日順に完全な連番（1, 2, 3...）を振り、後続処理が
     「何回目の注文か」を単純にカウントできるようにする。

  1. F1 Attribute Propagation
     Copies F1-only course flags to all subsequent actual and future records via window
     functions, so any row can be evaluated for course eligibility independently.
  2. Unified Actual + Future Timeline
     Unions shipped actuals (F1, F2+) with future scheduled shipments into one timeline.
  3. Safe Same-Day Order Consolidation
     When multiple orders occur on the same day, designates one "representative" order
     (accounting for returns) and propagates its attributes to avoid marketing-evaluation drift.
  4. Continuous Order Numbering
     Assigns a sequential order number (1, 2, 3...) per customer ordered by shipment date,
     starting from F1.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
  1. purchase_f1_base / extract_subsc_status_base / purchase_f2_and_later_orders
     F1・未来予定・F2以降の各ソースの取得
  2. prep_daily_duplicate_check ~ agg_daily_orders
     同日内の返品整理・代表注文の特定と属性伝播・1日1行化
  3. combine_f1_and_later_orders
     F1・F2以降・未来予定の縦結合（タイムライン生成）
  4. propagate_f1_attributes_to_all
     F1のコース属性を全履歴にウィンドウ関数でコピー
  5. Final Output
     継続回数（注文番号）の採番と出力

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  Order Level（実績）/ Scheduled Shipment Level（未来予定）

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  user_id, order_id, ship_date

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: window functions, LISTAGG, UNION ALL)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 顧客ジャーニー統合タイムライン中間テーブル
  int_customer_gift_journey_timeline
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [F1 Base] 起点となるF1データの取得
--    Data Grain: order_id
----------------------------------------------------------------------
purchase_f1_base AS (
    SELECT
        a.user_id, a.order_id, a.product_id, a.product_name,
        a.order_status, a.order_status_numbr, a.is_payment_received,
        a.ship_date, a.delivered_date, a.quantity,
        a.is_sys_return, a.return_completed_date,

        a.is_product_a_first_order, a.is_product_b_first_order,
        a.is_course_3bottle_first, a.is_course_upgraded_1_to_2, a.is_course_upgraded_1_to_3,

        a.product_category, a.subsc_category, a.ship_category,
        a.is_cus_black, a.is_cus_deleted_merged, a.is_cus_merged,

        'F1_出荷' AS order_type

    FROM
        stg_gift_eligible_order_confirmed a -- 【前工程】02_stg_gift_eligible_order_confirmed

    INNER JOIN
        (
            SELECT user_id, MIN(order_id) AS min_order_id
            FROM stg_gift_eligible_order_confirmed
            GROUP BY user_id
        ) b
    ON a.order_id = b.min_order_id
),

----------------------------------------------------------------------
-- 2. [Future Base] 顧客の現在の定期ステータス（未来の予定）の取得
--    Data Grain: user_id, ship_date
----------------------------------------------------------------------
extract_subsc_status_base AS (
    SELECT
        user_id,
        -- 定期購入IDの先頭の英字接頭辞を「99」に変換し、注文IDと同じ数値型で扱えるようにする
        REGEXP_REPLACE(subsc_id, '^[A-Za-z]+', 99) AS order_id,
        product_id,
        product_name,
        'Subsc_order'  AS order_status,
        NULL           AS order_status_numbr,
        0              AS is_payment_received, -- 定期予定のため、未入金
        ship_date,
        NULL           AS delivered_date,
        quantity,
        0              AS is_sys_return,
        NULL           AS return_completed_date,

        is_product_a_first_order,
        is_product_b_first_order,
        is_course_3bottle_first,
        is_course_upgraded_1_to_2,
        is_course_upgraded_1_to_3,

        product_category,
        subsc_category,
        ship_category,

        is_cus_black,
        is_cus_deleted_merged,
        is_cus_merged,

        '定期_出荷予定' AS order_type

    FROM
        stg_subscription_future_schedule -- 【前工程】04_stg_subscription_future_schedule
),

----------------------------------------------------------------------
-- 3. [F2+ Actuals] F2以降の対象商品の明細データの取得
--    Data Grain: order_id, ship_date
----------------------------------------------------------------------
purchase_f2_and_later_orders AS (
    SELECT
        user_id, order_id, product_id, product_name,
        order_status, order_status_numbr, is_payment_received,
        ordered_at, ordered_date, ship_date, delivered_date,
        quantity, is_sys_return, return_completed_date,
        is_product_a_first_order, is_product_b_first_order
    FROM
        stg_subsequent_shipment_history -- 【前工程】03_stg_subsequent_shipment_history
),

----------------------------------------------------------------------
-- 4. [Duplicate Prep] 同日内の返品状況確認と同日注文の採番
--    Data Grain: order_id
----------------------------------------------------------------------
prep_daily_duplicate_check AS (
    SELECT
        *,

        MIN(is_sys_return) OVER(
            PARTITION BY user_id, ship_date
        ) AS is_day_all_returned,

        ROW_NUMBER() OVER(
            PARTITION BY user_id, ship_date
            ORDER BY ordered_at ASC, order_id ASC
        ) AS daily_seq

    FROM
        purchase_f2_and_later_orders -- 03. の情報
),

----------------------------------------------------------------------
-- 5. [Return Filtering] 返品条件に基づく不要行の除外
--    Data Grain: order_id
----------------------------------------------------------------------
exclude_invalid_returns AS (
    SELECT
        *
    FROM
        prep_daily_duplicate_check -- 04. の情報
    WHERE
        (is_day_all_returned = 1 AND daily_seq = 1)
        OR
        (is_day_all_returned <> 1 AND is_sys_return <> 1)
),

----------------------------------------------------------------------
-- 6. [Representative Order] 同日最古の注文を「代表注文」として特定
--    Data Grain: order_id
----------------------------------------------------------------------
identify_daily_representative_order AS (
    SELECT
        *,
        ROW_NUMBER() OVER(
            PARTITION BY user_id, ship_date
            ORDER BY ordered_at ASC, order_id ASC
        ) AS valid_daily_seq
    FROM
        exclude_invalid_returns -- 05. の情報
),

----------------------------------------------------------------------
-- 7. [Attribute Propagation] 代表注文の属性を同日内の全レコードに伝播
--    Data Grain: order_id
----------------------------------------------------------------------
propagate_representative_attributes AS (
    SELECT
        *,
        MAX(CASE WHEN valid_daily_seq = 1 THEN order_id ELSE NULL END)
            OVER(PARTITION BY user_id, ship_date) AS daily_rep_order_id,
        MAX(CASE WHEN valid_daily_seq = 1 THEN order_status ELSE NULL END)
            OVER(PARTITION BY user_id, ship_date) AS daily_rep_order_status,
        MAX(CASE WHEN valid_daily_seq = 1 THEN order_status_numbr ELSE NULL END)
            OVER(PARTITION BY user_id, ship_date) AS daily_rep_order_status_numbr,
        MAX(CASE WHEN valid_daily_seq = 1 THEN is_payment_received ELSE NULL END)
            OVER(PARTITION BY user_id, ship_date) AS daily_rep_is_payment_received,
        MAX(CASE WHEN valid_daily_seq = 1 THEN quantity ELSE 0 END)
            OVER(PARTITION BY user_id, ship_date) AS daily_rep_quantity,
        MAX(CASE WHEN valid_daily_seq = 1 THEN is_product_a_first_order ELSE NULL END)
            OVER(PARTITION BY user_id, ship_date) AS daily_rep_is_product_a_first_order,
        MAX(CASE WHEN valid_daily_seq = 1 THEN is_product_b_first_order ELSE NULL END)
            OVER(PARTITION BY user_id, ship_date) AS daily_rep_is_product_b_first_order

    FROM
        identify_daily_representative_order -- 06. の情報
),

----------------------------------------------------------------------
-- 8. [Daily Aggregation] 購入情報の集約（1日1行化）
--    Data Grain: daily_rep_order_id
----------------------------------------------------------------------
agg_daily_orders AS (
    SELECT
        user_id,
        daily_rep_order_id AS order_id,

        LISTAGG(DISTINCT CASE WHEN order_id = daily_rep_order_id THEN product_id END, ' / ')   AS product_id,
        LISTAGG(DISTINCT CASE WHEN order_id = daily_rep_order_id THEN product_name END, ' / ') AS product_name,

        MAX(daily_rep_order_status)             AS order_status,
        MAX(daily_rep_order_status_numbr)       AS order_status_numbr,
        MAX(daily_rep_is_payment_received)      AS is_payment_received,
        MAX(ship_date)                          AS ship_date,
        MAX(delivered_date)                     AS delivered_date,
        MAX(daily_rep_quantity)                 AS quantity,
        MAX(is_sys_return)                      AS is_sys_return,
        MAX(return_completed_date)              AS return_completed_date,
        MAX(daily_rep_is_product_a_first_order) AS is_product_a_first_order,
        MAX(daily_rep_is_product_b_first_order) AS is_product_b_first_order,

        -- F2以降のレコードとしては持たない（F1から伝播させる）ダミーフラグ群
        0            AS is_course_3bottle_first,
        0            AS is_course_upgraded_1_to_2,
        0            AS is_course_upgraded_1_to_3,
        NULL         AS product_category,
        NULL         AS subsc_category,
        NULL         AS ship_category,
        0            AS is_cus_black,
        0            AS is_cus_deleted_merged,
        0            AS is_cus_merged,
        'F2以降_出荷' AS order_type

    FROM
        propagate_representative_attributes -- 07. の情報
    GROUP BY
        user_id, daily_rep_order_id
),

----------------------------------------------------------------------
-- 9. [Timeline Union] F1・F2以降・未来予定の縦結合
--    Data Grain: order_id, ship_date
----------------------------------------------------------------------
combine_f1_and_later_orders AS (
    SELECT user_id, order_id, product_id, product_name, order_status, order_status_numbr,
           is_payment_received, ship_date, delivered_date, quantity, is_sys_return, return_completed_date,
           is_product_a_first_order, is_product_b_first_order, is_course_3bottle_first,
           is_course_upgraded_1_to_2, is_course_upgraded_1_to_3, product_category, subsc_category,
           ship_category, is_cus_black, is_cus_deleted_merged, is_cus_merged, order_type
    FROM purchase_f1_base -- 01. (F1)

    UNION ALL

    SELECT user_id, order_id, product_id, product_name, order_status, order_status_numbr,
           is_payment_received, ship_date, delivered_date, quantity, is_sys_return, return_completed_date,
           is_product_a_first_order, is_product_b_first_order, is_course_3bottle_first,
           is_course_upgraded_1_to_2, is_course_upgraded_1_to_3, product_category, subsc_category,
           ship_category, is_cus_black, is_cus_deleted_merged, is_cus_merged, order_type
    FROM agg_daily_orders -- 08. (F2以降)

    UNION ALL

    SELECT user_id, order_id, product_id, product_name, order_status, order_status_numbr,
           is_payment_received, ship_date, delivered_date, quantity, is_sys_return, return_completed_date,
           is_product_a_first_order, is_product_b_first_order, is_course_3bottle_first,
           is_course_upgraded_1_to_2, is_course_upgraded_1_to_3, product_category, subsc_category,
           ship_category, is_cus_black, is_cus_deleted_merged, is_cus_merged, order_type
    FROM extract_subsc_status_base -- 02. (定期予定)
),

----------------------------------------------------------------------
-- 10. [Attribute Propagation] F1のコース属性を全履歴にコピー
--     Data Grain: order_id, ship_date
----------------------------------------------------------------------
propagate_f1_attributes_to_all AS (
    SELECT
        user_id, order_id, product_id, product_name, order_status, order_status_numbr,
        is_payment_received, ship_date, delivered_date, quantity, is_sys_return, return_completed_date,

        CASE
            WHEN is_product_a_first_order = 1 OR is_product_b_first_order = 1 THEN is_product_a_first_order
            ELSE MAX(is_product_a_first_order) OVER(PARTITION BY user_id)
        END AS max_is_product_a_first_order,

        CASE
            WHEN is_product_a_first_order = 1 OR is_product_b_first_order = 1 THEN is_product_b_first_order
            ELSE MAX(is_product_b_first_order) OVER(PARTITION BY user_id)
        END AS max_is_product_b_first_order,

        CASE
            WHEN is_product_a_first_order = 1 OR is_product_b_first_order = 1 THEN is_course_3bottle_first
            ELSE MAX(is_course_3bottle_first) OVER(PARTITION BY user_id)
        END AS max_is_course_3bottle_first,

        CASE
            WHEN is_product_a_first_order = 1 OR is_product_b_first_order = 1 THEN is_course_upgraded_1_to_2
            ELSE MAX(is_course_upgraded_1_to_2) OVER(PARTITION BY user_id)
        END AS max_is_course_upgraded_1_to_2,

        CASE
            WHEN is_product_a_first_order = 1 OR is_product_b_first_order = 1 THEN is_course_upgraded_1_to_3
            ELSE MAX(is_course_upgraded_1_to_3) OVER(PARTITION BY user_id)
        END AS max_is_course_upgraded_1_to_3,

        CASE
            WHEN is_product_a_first_order = 1 OR is_product_b_first_order = 1 THEN product_category
            ELSE MAX(product_category) OVER(PARTITION BY user_id)
        END AS max_product_category,

        CASE
            WHEN is_product_a_first_order = 1 OR is_product_b_first_order = 1 THEN subsc_category
            ELSE MAX(subsc_category) OVER(PARTITION BY user_id)
        END AS max_subsc_category,

        ship_category,

        CASE
            WHEN is_product_a_first_order = 1 OR is_product_b_first_order = 1 THEN is_cus_black
            ELSE MAX(is_cus_black) OVER(PARTITION BY user_id)
        END AS max_is_cus_black,

        CASE
            WHEN is_product_a_first_order = 1 OR is_product_b_first_order = 1 THEN is_cus_deleted_merged
            ELSE MAX(is_cus_deleted_merged) OVER(PARTITION BY user_id)
        END AS max_is_cus_deleted_merged,

        CASE
            WHEN is_product_a_first_order = 1 OR is_product_b_first_order = 1 THEN is_cus_merged
            ELSE MAX(is_cus_merged) OVER(PARTITION BY user_id)
        END AS max_is_cus_merged,

        order_type

    FROM
        combine_f1_and_later_orders -- 09. の情報
)

----------------------------------------------------------------------
-- 11. [Final Output] 分析・確認用データの整形
--     Data Grain: order_id, ship_date
----------------------------------------------------------------------
SELECT
    user_id                            AS "ユーザーID",
    order_id                           AS "注文ID",

    ROW_NUMBER() OVER(
        PARTITION BY user_id
        ORDER BY ship_date ASC, order_id ASC
    ) AS "注文番号",

    product_id                         AS "商品ID",
    product_name                       AS "商品名",
    order_status                       AS "注文ステータス",
    order_status_numbr                 AS "受注明細状態",
    is_payment_received                AS "入金済フラグ",
    ship_date                          AS "出荷日",
    delivered_date                     AS "配達完了日",
    quantity                           AS "注文数",
    is_sys_return                      AS "返品フラグ_システム基準",
    return_completed_date              AS "返品受付日",
    max_is_product_a_first_order       AS "商品ラインA_新規フラグ",
    max_is_product_b_first_order       AS "商品ラインB_新規フラグ",

    max_is_course_3bottle_first        AS "初回3本_定期フラグ",
    max_is_course_upgraded_1_to_2      AS "初回1本→2本_定期フラグ",
    max_is_course_upgraded_1_to_3      AS "初回1本→3本_定期フラグ",
    max_product_category               AS "商品_分類",
    max_subsc_category                 AS "定期_分類",
    ship_category                      AS "出荷_分類",
    max_is_cus_black                   AS "ブラックフラグ",
    max_is_cus_deleted_merged          AS "削除/統合フラグ",
    max_is_cus_merged                  AS "顧客統合フラグ",
    order_type                         AS "注文分類"

FROM
    propagate_f1_attributes_to_all -- 10. の情報

ORDER BY
    user_id ASC, ship_date ASC
;
