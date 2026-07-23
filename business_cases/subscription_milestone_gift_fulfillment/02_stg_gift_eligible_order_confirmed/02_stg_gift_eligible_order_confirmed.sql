/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 F1（起点）注文確定マスタ（注文単位例外対応・重複検知）
  Gift-Eligible Order Confirmation (Order-Level Exceptions & Duplicate Detection) — Staging Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. 注文単位の手動例外反映
     前工程（ユーザー単位の例外対応済み）の候補者リストに対し、手動運用リストによる
     「注文単位の削除」のみを適用する。粒度の異なる処理を混在させないための責務分離。
  2. 重複購入の可視化
     ウィンドウ関数を用いて、1人の顧客が複数回F1条件を満たす注文（重複）を行っている
     場合を検知し、後続でどちらの注文を有効とするかの判断材料を提供する。

  1. Order-Level Manual Exception Handling
     Applies order-level manual deletion from the operator-managed CSV to the already
     user-level-corrected candidate list, keeping grain-specific concerns separated.
  2. Duplicate Purchase Visibility
     Uses window functions to detect customers with multiple qualifying F1 orders,
     providing the evidence needed for downstream decisions on which order to honor.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
このクエリは以下の処理ステップで構成されています。
This query consists of the following processing layers.

  1. purchase_base
     前工程の候補者リストの取得
     Retrieval of the user-level-corrected candidate list from the previous step.

  2. filter_by_order_level_exceptions
     注文単位の手動除外の適用
     Application of order-level manual deletions.

  3. calculate_user_duplicates
     同一顧客の重複購入状況の算出
     Calculation of duplicate-order visibility per customer.

  4. Final Output
     状態カテゴリの付与と出力
     Final output with derived alert/classification labels.

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  Order Level (F1確定の注文単位)

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  user_id, order_id

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: window functions, LISTAGG)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 F1確定ステージングテーブル
  stg_gift_eligible_order_confirmed
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [Base] 候補者リストの取得
--    Data Grain: order_id
----------------------------------------------------------------------
purchase_base AS (
    SELECT
        user_id,
        order_id,
        product_id,
        product_name,
        order_status,
        order_status_numbr,
        is_payment_received,
        ordered_date,
        ship_date,
        delivered_date,
        is_sys_return,
        return_completed_date,
        quantity,
        subsc_id,

        is_product_a_first_order,
        is_product_b_first_order,
        is_course_3bottle_first,
        is_course_upgraded_1_to_2,
        is_course_upgraded_1_to_3,
        is_gift_eligible_code,
        has_product_name_gift_marker,

        is_manual_override_add,
        has_dm_gift_history,
        has_insert_gift_marker,
        is_cus_black,
        is_cus_deleted_merged,
        is_cus_merged,

        product_category,
        subsc_category,
        ship_category

    FROM
        stg_gift_eligible_purchase_base -- 【前工程】01_stg_gift_eligible_purchase_base
),

----------------------------------------------------------------------
-- 2. [Order-Level Correction] 注文単位の手動除外の適用
--    Data Grain: order_id
----------------------------------------------------------------------
filter_by_order_level_exceptions AS (
    SELECT
        a.*,

        COALESCE(c.is_deleted_by_order_list, 0) AS is_deleted_by_order_list

    FROM
        purchase_base a -- 01. の情報

    -- 【手動対応】注文単位の削除リストを結合
    LEFT JOIN
        map_gift_manual_exceptions c -- △ 特典_手動対応リスト.csv
    ON a.order_id = c.order_id
    AND c.exception_type = 'DELETE_BY_ORDER'

    WHERE
        COALESCE(c.is_deleted_by_order_list, 0) <> 1
),

----------------------------------------------------------------------
-- 3. [Duplicate Evaluation] 同一顧客の重複状況の再計算
--    Data Grain: order_id
----------------------------------------------------------------------
calculate_user_duplicates AS (
    SELECT
        *,

        COUNT(order_id) OVER(PARTITION BY user_id) AS order_count,

        LISTAGG(order_id, ', ')
            WITHIN GROUP (ORDER BY ship_date ASC, order_id ASC)
            OVER(PARTITION BY user_id)
        AS orderid_in_user,

        MAX(is_product_a_first_order) OVER(PARTITION BY user_id) AS max_is_product_a_first_order,
        MAX(is_product_b_first_order) OVER(PARTITION BY user_id) AS max_is_product_b_first_order

    FROM
        filter_by_order_level_exceptions -- 02. の情報
)

----------------------------------------------------------------------
-- 4. [Final Output] 分析・確認用データの整形
--    Data Grain: order_id
----------------------------------------------------------------------
SELECT
    -- ====== IDs ======
    user_id                        AS "ユーザーID",
    order_id                       AS "注文ID",
    product_id                     AS "商品ID",
    product_name                   AS "商品名",
    order_status                   AS "注文ステータス",
    order_status_numbr             AS "受注明細状態",
    is_payment_received            AS "入金済フラグ",
    ordered_date                   AS "受注日",
    ship_date                      AS "出荷日",
    delivered_date                 AS "配達完了日",
    is_sys_return                  AS "返品フラグ_システム基準",
    return_completed_date          AS "返品受付日",
    quantity                       AS "注文数",
    subsc_id                       AS "定期購入ID",

    -- ====== Gift Eligibility & Course Flags ======
    is_product_a_first_order       AS "商品ラインA_新規フラグ",
    is_product_b_first_order       AS "商品ラインB_新規フラグ",
    is_course_3bottle_first        AS "初回3本_定期フラグ",
    is_course_upgraded_1_to_2      AS "初回1本→2本_定期フラグ",
    is_course_upgraded_1_to_3      AS "初回1本→3本_定期フラグ",
    is_gift_eligible_code          AS "デジタルギフトフラグ",
    has_product_name_gift_marker   AS "商品名「ギフト表記」有フラグ",

    -- ====== Irregular / Check Flags ======
    is_manual_override_add         AS "イレギュラー追加フラグ",
    has_dm_gift_history             AS "DM履歴「ギフト対象」フラグ",
    has_insert_gift_marker          AS "同梱物「ギフト表記」有フラグ",
    is_cus_black                   AS "ブラックフラグ",
    is_cus_deleted_merged          AS "削除/統合フラグ",
    is_cus_merged                  AS "顧客統合フラグ",

    -- ====== Derived Category Labels ======
    product_category               AS "商品_分類",
    subsc_category                 AS "定期_分類",
    ship_category                  AS "出荷_分類",

    -- 1人の顧客が複数回対象注文を行っている場合の警告フラグ
    CASE
        WHEN order_count >= 2 THEN '重複注文_'
        ELSE NULL
    END AS "重複チェック_大分類",

    CASE
        WHEN order_count >= 2
         AND max_is_product_a_first_order = 1
         AND max_is_product_b_first_order = 1 THEN 'PRODUCT_A・PRODUCT_B'
        WHEN order_count >= 2
         AND max_is_product_a_first_order = 1
         AND max_is_product_b_first_order <> 1 THEN 'PRODUCT_A'
        WHEN order_count >= 2
         AND max_is_product_a_first_order <> 1
         AND max_is_product_b_first_order = 1 THEN 'PRODUCT_B'
        ELSE NULL
    END AS "重複チェック_中分類",

    CASE
        WHEN order_count >= 2 THEN orderid_in_user
        ELSE NULL
    END AS "重複チェック_詳細_注文ID",

    CASE
        WHEN has_dm_gift_history <> 1 THEN 'DM履歴_ギフト対象者なし'
        ELSE NULL
    END AS "DM履歴チェック",

    CASE
        WHEN is_cus_black = 1 THEN '顧客状態_ブラック'
        ELSE NULL
    END AS "顧客状態チェック",

    CASE
        WHEN is_cus_merged = 1 THEN '統合顧客'
        ELSE NULL
    END AS "統合顧客チェック"

FROM
    calculate_user_duplicates -- 03. の情報
;
