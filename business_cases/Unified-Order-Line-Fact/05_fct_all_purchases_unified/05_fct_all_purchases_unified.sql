/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 全購入情報統合ファクトテーブル
  Unified All Purchases Fact Table

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. 注文基本データと金額データの統合
     返品レコード（マイナス売上）を除外したクリーンなベースデータに対し、
     累積案分で計算された「1円のズレもない正確な金額情報（stg_order_amount）」を結合。
  2. 返品・キャンセルステータスの反映
     別処理で隔離・判定されたキャンセル/返品フラグ（int_cancellation_return）を、
     「親子の絆キー（order_link_key）」を用いて出荷元データ（親注文）に転写。
  3. 返品理由（自由記述）の安全な集約
     複数回の返品（枝番複数）が発生した注文におけるJOIN爆発を防ぐため、
     サブクエリで返品理由をユニーク化した後、LISTAGG関数で1行の文字列に集約して結合。
  4. 分析用ディメンションの最終整形
     支払方法コードや受注経路コードを、BIツールで即座に分析可能な日本語ラベルへと変換。

  1. Integration of Base Order and Financial Data
     Joining the cleansed base order data (excluding negative return records) with 
     the highly accurate, prorated financial data (stg_order_amount).
  2. Reflection of Return/Cancellation Statuses
     Transferring cancellation and return flags (from int_cancellation_return) back to 
     the original parent order using the Order Link Key.
  3. Safe Aggregation of Return Reason Notes
     Preventing JOIN explosions for orders with multiple return iterations by deduplicating 
     return reason notes in a subquery, then concatenating them into a single string using LISTAGG.
  4. Final Dimension Formatting
     Translating system codes (e.g., payment methods, order channels) into 
     business-friendly Japanese labels ready for BI tool consumption.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
このクエリは以下の処理ステップで構成されています。
This query consists of the following processing layers.

  1. base_order_table
     注文情報の整理（返品マイナス売上レコードの除外）
     Preparation of order info (Excluding negative return records).

  2. base_order_price_table
     金額情報の取得（累積案分計算済みの実質売上）
     Retrieval of highly accurate financial data.

  3. cnsl_return_flags
     キャンセル・返品・全額返金フラグの取得
     Retrieval of aggregated cancellation, return, and refund eligibility flags.

  4. return_reason_aggregation
     返品理由メモのユニーク化と文字列集約（JOIN爆発の防止）
     Deduplication and string aggregation of return reason notes to prevent JOIN explosions.

  5. Final Output
     全てのステージングデータ・マスタ群の統合および最終出力
     Integration of all staging datasets and dimension masters for the final fact table.

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  Order Line Item (受注明細単位)

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  user_id, order_id, line_no

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: LISTAGG WITHIN GROUP)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 全購入情報統合ファクトテーブル
  fct_all_purchases_unified
==============================================================================================
*/

WITH 
----------------------------------------------------------------------
-- 1. [Base Order Info] 注文情報の整理
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
base_order_table AS (
    SELECT
        -- IDs
        user_id, 
        order_id, 
        order_link_key, --「親子の絆キー」
        line_no,

        -- Product Info
        product_id, 
        product_name, 
        product_external_id4, 
        product_analysis_category_level_5, 
        product_analysis_category_level_6, 

        -- Order Info
        order_type, 
        order_status, 
        order_status_number, 
        payment_type, 
        member_rank_at_order, 
        latest_ad_code, 
        is_ec_order_without_promo_code,
        operator_code, 

        -- Dates
        ordered_at, 
        scheduled_ship_date, 
        delivered_at, 

        -- Quantity & Subsc
        quantity, 
        CASE WHEN product_analysis_category_level_6 IN ('200','300') THEN 1 ELSE 0 END AS subsc_flag,
        subsc_id,
        subsc_cycle_at_order, 
        subsc_cycle_at_shipment 

    FROM 
        stg_order_info -- 【前工程】02_stg_order_info.sql
    WHERE
        is_return_order = 0 -- 返品レコード（マイナス売上）は分析のノイズになるため除外
),

----------------------------------------------------------------------
-- 2.[Financial Info] 金額情報の取得
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
base_order_price_table AS (
    SELECT
        user_id, 
        order_id, 
        line_no, 
        product_id, 
        product_name, 
        quantity, 
        system_total_payment AS total_payment_amount,
        discounted_amount_excl_point_excl_tax,
        validated_discounted_incl_point_excl_tax  -- 商品別金額（割引済・ポイント込み・税抜）
    FROM 
        stg_order_amount -- 【前工程】01_stg_order_amount.sql
),

----------------------------------------------------------------------
-- 3. [Status Flags] キャンセル/返品フラグの取得
--    Data Grain: order_link_key
----------------------------------------------------------------------
cnsl_return_flags AS (
    SELECT
        order_link_key,
        cnsl_flag,
        return_flag,
        refund_eligibility_flag,
        cus_black_flag,
        cus_deleted_merged_flag
    FROM 
        int_cancellation_return -- 【前工程】04_int_cancellation_return.sql
),

----------------------------------------------------------------------
-- 4. [Return Reason Aggregation] 返品理由メモのユニーク化と集約
--    Data Grain: order_link_key
----------------------------------------------------------------------
return_reason_aggregation AS (
    SELECT
        order_link_key,
        LISTAGG(return_reason_note, ' / ') WITHIN GROUP (ORDER BY min_order_id) AS return_reason_note 
    FROM (
        -- Subquery: Deduplication (重複排除)
        SELECT
            order_link_key,
            return_reason_note,
            MIN(order_id) AS min_order_id
        FROM 
            stg_return_history -- 【前工程】03_stg_return_history.sql
        GROUP BY 
            order_link_key, return_reason_note
    )            
    GROUP BY
        order_link_key
)

----------------------------------------------------------------------
-- 5. [Final Output] 全データの統合とディメンション整形
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
SELECT
    -- ====== IDs ======
    a.user_id                                  AS "ユーザーID", 
    a.order_id                                 AS "注文ID", 
    a.line_no                                  AS "注文商品枝番", 

    -- ====== Product Info ======
    a.product_id                               AS "商品ID", 
    a.product_name                             AS "商品名", 
    a.product_external_id4                     AS "商品連携ID4", 
    a.product_analysis_category_level_5        AS "分析用分類【第5階層】",
    a.product_analysis_category_level_6        AS "分析用分類【第6階層】",

    -- ====== Order Info ======
    CASE
        WHEN a.order_type = 'TEL'     THEN '電話(IN)' 
        WHEN a.order_type = 'hagaki' OR a.order_type = 'FAX' THEN 'ハガキ/FAX' 
        WHEN a.order_type = 'PC' OR a.order_type = 'SP'      THEN 'EC' 
        WHEN a.order_type = 'out'     THEN '電話(OUT)' 
        WHEN a.order_type = 'gaibuEC' THEN 'EC外部' 
        ELSE 'その他' 
    END                                        AS "受注経路", 

    a.order_status                             AS "注文ステータス",
    a.order_status_number                      AS "受注明細状態", 
    COALESCE(pmt.payment_method_name, '不明')  AS "支払方法",
    a.member_rank_at_order                     AS "注文時会員ランク",
    a.latest_ad_code                           AS "受注プロモ", 
    a.operator_code                            AS "受付者コード",
    a.is_ec_order_without_promo_code           AS "[プロモ空欄かつ経路EC]フラグ",
    COALESCE(ns.is_no_shipping, 0)             AS "実発送なしフラグ",

    -- ====== Dates ======
    a.ordered_at                               AS "受注日時",
    a.scheduled_ship_date                      AS "出荷日時",
    a.delivered_at                             AS "配達完了日時",

    -- ====== Quantity & Financials ======
    b.quantity                                 AS "注文数",
    b.total_payment_amount                     AS "支払合計金額 (税込)", 
    b.discounted_amount_excl_point_excl_tax    AS "P使用前_割引後金額 (税抜)", 
    b.validated_discounted_incl_point_excl_tax AS "P使用後_割引後金額 (税抜)",

    -- ====== Subscription ======
    a.subsc_flag                               AS "定期フラグ",
    a.subsc_id                                 AS "定期購入ID",
    a.subsc_cycle_at_order                     AS "定期購入回（注文時点）",
    a.subsc_cycle_at_shipment                  AS "定期購入回（出荷時点）",

    -- ====== Return & Cancellation Flags ======
    COALESCE(c.cnsl_flag, 0)                   AS "CNSLフラグ",
    COALESCE(c.return_flag, 0)                 AS "返品フラグ",
    COALESCE(c.refund_eligibility_flag, 0)     AS "全額返金フラグ", 
    d.return_reason_note                       AS "返品理由",

    -- ====== Customer Flags ======
    COALESCE(c.cus_black_flag, 0)              AS "ブラックフラグ", 
    COALESCE(c.cus_deleted_merged_flag, 0)     AS "削除/統合フラグ" 

FROM
    base_order_table a

-- Financials (金額情報)
LEFT JOIN
    base_order_price_table b ON a.order_id = b.order_id AND a.line_no = b.line_no 

-- Status Flags (ステータスフラグの転写)
LEFT JOIN
    cnsl_return_flags c ON a.order_link_key = c.order_link_key 

-- Return Reason (返品理由)
LEFT JOIN
    return_reason_aggregation d ON a.order_link_key = d.order_link_key 

-- Dimension Master (支払方法マスタ)
LEFT JOIN
    dim_payment_methods pmt ON a.payment_type = pmt.payment_method_code AND pmt.category_name = '支払い区分'

-- Exception List (実発送なしリスト)
LEFT JOIN
    list_no_shipping_orders ns ON a.order_id = ns.order_id 
;
