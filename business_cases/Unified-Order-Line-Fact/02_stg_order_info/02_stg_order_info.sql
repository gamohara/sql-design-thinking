/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 受注情報のクレンジング・定期判定・ID正規化マスタ
  Order Information Staging & Normalization


【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. データクレンジング
     エラーリスト（テスト注文、異常データ）と商品名「TEST」の除外。
     商品マスタ（dim_products）およびプロモ補正マスタを用いて名称やコードを補正。
  2. 定期購入商品の再分類
     旧ID形式（頭文字C）における定期同梱品の欠損情報を、
     注文内のRG品行数や各種フラグを組み合わせて推測・補正（Heuristic Classification）。
  3. 受注IDの正規化
     返品データ（枝番付きID: 例 `-001`）と元注文を紐付けるための
     「親子の絆キー（order_link_key）」を正規表現を用いて生成。
  4. データオブザーバビリティ
     定期判定ロジックの信頼度（classification_reliability）をスコアリングし、
     手動推測（MANUAL_HEURISTIC）の割合をメタデータとして出力。

  1. Data Cleansing
     Exclusion of test accounts and anomalous data based on error logs.
  2. Subscription Item Classification
     Heuristic logic to identify missing subscription flags in legacy ID formats (Prefix 'C') 
     by combining product categories and subscription IDs.
  3. Order ID Normalization
     Generating an 'Order Link Key' using Regex to link returns/exchanges (-001 suffix) 
     back to the original order for lifecycle analysis.
  4. Data Observability
     Scoring classification reliability to monitor the impact of heuristic logic on reporting.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
このクエリは以下の処理ステップで構成されています。
This query consists of the following processing layers.

  1. error_test_customer / error_abnormal_items
   エラー除外対象の特定  
   Identification of records to exclude based on error logs.

2. subsc_order_item_base
   定期購入情報の重複排除（結合増幅防止）  
   Deduplication of subscription information to prevent join amplification.

3. order_item_base
   商品明細の整理および商品マスタ補正  
   Item-level cleansing and enrichment using the product master.

4. order_base
   注文ヘッダ情報の整理と広告コード補正  
   Header-level cleansing including promo code correction.

5. base_table
   明細とヘッダの統合ベーステーブル  
   Early integration of item and header data to prevent redundant joins.

6. subsc_classification
   定期商品判定ロジック（ヒューリスティック分類エンジン）  
   Multi-step heuristic classification engine for subscription items.

7. order_id_normalization
   注文IDの正規化（返品・交換注文の親子関係の生成）  
   Regex-based normalization for linking returns and exchanges to original orders.

8. Final Output
   最終出力およびメタデータ生成  
   Final dataset generation with observability metadata.

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  Order Line Item (受注明細単位)

【主キー / Primary Key
----------------------------------------------------------------------------------------------
  user_id, order_id, line_no

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: window functions, REGEXP_LIKE)

【エラーコード定義 / Error Code Definition】
----------------------------------------------------------------------------------------------
 1.TEST_CUSTOMER 
  内部テスト用アカウント
  Internal test accounts

 2.ABNORMAL_ITEM_COUNT 
  システム不具合等による数量異常
  System glitches causing impossible quantities

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 受注正規化ステージングテーブル
  stg_order_normalized_master 
==============================================================================================
*/

WITH 
----------------------------------------------------------------------
-- 1. [Exclusion Lists] エラーデータの特定
----------------------------------------------------------------------
error_test_customer AS (
    SELECT order_id, error_flag 
    FROM source_error_log 
    WHERE error_reason = 'TEST_CUSTOMER'
),

error_abnormal_items AS (
    SELECT order_id, line_no, product_id, error_flag 
    FROM source_error_log 
    WHERE error_reason = 'ABNORMAL_ITEM_COUNT'
),

----------------------------------------------------------------------
-- 2. [Subscription Base] 定期購入情報のユニーク化 (結合増幅防止)
--    Data Grain: order_id, subsc_id, product_analysis_category_level_5
----------------------------------------------------------------------
subsc_order_item_base AS (
    SELECT
        user_id, 
        subsc_id, 
        product_analysis_category_level_5, 
        1 AS subsc_order_flag 
    FROM 
        dim_subscription_info
    GROUP BY
        user_id, subsc_id, product_analysis_category_level_5
),

----------------------------------------------------------------------
-- 3. [Order Items] 受注商品明細の整理とマスタ補正
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
order_item_base AS (
    SELECT
        ot.order_id,
        ot.line_no,
        LEFT(ot.order_id, 1) AS order_id_prefix,
        ot.product_id,

        COALESCE(NULLIF(pm.product_name, ''), ot.raw_product_name) AS product_name,
        COALESCE(NULLIF(pm.promo_category, ''), ot.raw_promo_category) AS product_external_id4,

        pm.product_analysis_category_level_5,
        pm.product_analysis_category_level_6,
        ot.quantity,
        ot.updated_at AS imported_at 

    FROM 
        raw_order_items ot
    LEFT JOIN 
        dim_products pm ON ot.product_id = pm.product_id

    -- エラー除外 (Anti-Join Logic)
    LEFT JOIN error_test_customer e1 ON ot.order_id = e1.order_id
    LEFT JOIN error_abnormal_items e2 ON ot.order_id = e2.order_id AND ot.line_no = e2.line_no AND ot.product_id = e2.product_id
    WHERE 
        e1.error_flag IS NULL 
        AND e2.error_flag IS NULL
),

----------------------------------------------------------------------
-- 4. [Order Header] 受注ヘッダの整理とプロモコード補正
--    Data Grain: order_id
----------------------------------------------------------------------
order_base AS (
    SELECT
        oh.user_id, 
        oh.order_id, 
        oh.order_type,
        oh.order_status,
        oh.payment_type,
        oh.member_rank_at_order,

        -- Promo Code Correction (Ad Code優先順位ロジック)
        CASE
            WHEN oh.raw_ad_code = pc.old_ad_code THEN pc.new_ad_code
            WHEN NULLIF(oh.raw_ad_code, '') IS NULL THEN oh.initial_ad_code
            ELSE oh.raw_ad_code
        END AS latest_ad_code,

        oh.operator_code,
        oh.ordered_at,
        oh.scheduled_ship_date,
        oh.delivered_at,
        oh.subsc_id,
        oh.subsc_cycle_at_order,
        oh.subsc_cycle_at_shipment,
        oh.return_exchange_status,
        oh.return_reason_note,
        oh.return_completed_at,

        -- Return Flag Logic (末尾が -0XX か判定)
        CASE WHEN REGEXP_LIKE(TRIM(oh.order_id), '.*-0[0-9]{2}$') THEN 1 ELSE 0 END AS is_return_order,
        oh.updated_at AS imported_at 

    FROM 
        raw_orders oh
    LEFT JOIN
        map_promo_code_correction pc ON oh.user_id = pc.user_id AND oh.order_id = pc.order_id
),

----------------------------------------------------------------------
-- 5. [Base Table] 明細とヘッダの早期統合 (Redundant Join防止)
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
base_table AS (
    SELECT
        h.user_id, 
        i.order_id, 
        i.line_no, 
        i.order_id_prefix, 
        i.product_id,
        i.product_name, 
        i.product_external_id4, 
        i.product_analysis_category_level_5, 
        i.product_analysis_category_level_6, 
        h.order_type, 
        h.order_status, 
        h.payment_type, 
        h.member_rank_at_order, 
        h.latest_ad_code, 

        -- ECプロモなし検知用
        CASE WHEN NULLIF(h.latest_ad_code, '') IS NULL THEN h.order_type ELSE '' END AS order_type_without_promo_code,
        h.operator_code, 
        h.ordered_at, 
        h.scheduled_ship_date, 
        h.delivered_at, 
        i.quantity, 
        h.subsc_id, 
        h.subsc_cycle_at_order, 
        h.subsc_cycle_at_shipment, 
        h.return_exchange_status, 
        h.return_reason_note, 
        h.return_completed_at, 
        h.is_return_order, 
        h.imported_at 

    FROM 
        order_item_base i
    LEFT JOIN 
        order_base h ON i.order_id = h.order_id
    WHERE 
        UPPER(COALESCE(i.product_name, '')) NOT LIKE '%TEST%'
),

----------------------------------------------------------------------
-- 6. [Subscription Classification] 定期区分判定ロジック (Heuristic)
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
subsc_classification_prepare AS (
    SELECT
        *,
        SUM(CASE WHEN product_external_id4 = 'RG' THEN 1 ELSE 0 END) OVER (PARTITION BY order_id) AS regular_product_line_count 
    FROM 
        base_table
    WHERE 
        product_external_id4 = 'RG' 
        AND NULLIF(subsc_id, '') IS NOT NULL 
        AND order_id_prefix = 'C'
),

subsc_classification_flags AS (
    SELECT
        i.user_id,
        i.order_id,
        i.line_no, 
        i.product_analysis_category_level_6, 
        i.regular_product_line_count, 
        
        -- Flag 1: Master Definition
        CASE WHEN i.product_analysis_category_level_6 IN ('200','300') THEN 1 ELSE 0 END AS subsc_flag_01, 
        -- Flag 2: DB Match
        CASE WHEN COALESCE(j.subsc_order_flag, 0) = 1 THEN 1 ELSE 0 END AS subsc_flag_02, 
        -- Flag 3: Manual Heuristic (旧ID形式約7000件の推測ロジック適用リスト)
        COALESCE(k.heuristic_flag, 0) AS subsc_flag_03 

    FROM 
        subsc_classification_prepare i
    LEFT JOIN 
        subsc_order_item_base j ON i.user_id = j.user_id AND i.subsc_id = j.subsc_id AND i.product_analysis_category_level_5 = j.product_analysis_category_level_5
    LEFT JOIN 
        map_subsc_heuristic_correction k ON i.user_id = k.user_id AND i.order_id = k.order_id AND i.line_no = k.line_no
),

subsc_classification_finalize AS (
    SELECT
        *,
        -- Final Category Decision
        CASE
            WHEN regular_product_line_count = 1 AND product_analysis_category_level_6 = '100' THEN '300'
            WHEN regular_product_line_count = 1 AND product_analysis_category_level_6 IN ('200','300') THEN product_analysis_category_level_6
            WHEN regular_product_line_count >= 2 AND subsc_flag_01 = 1 THEN product_analysis_category_level_6
            WHEN regular_product_line_count >= 2 AND (subsc_flag_02 = 1 OR subsc_flag_03 = 1) THEN '300'
            ELSE product_analysis_category_level_6 
        END AS adjusted_category_level_6, 

        -- Reliability Scoring
        CASE
            WHEN regular_product_line_count = 1 THEN 'ESTIMATED_SUBSC'
            WHEN subsc_flag_01 = 1 THEN 'SYSTEM_FACT'
            WHEN subsc_flag_02 = 1 THEN 'DB_MATCH_FACT'
            WHEN subsc_flag_03 = 1 THEN 'MANUAL_HEURISTIC'
            ELSE 'ORIGINAL'
        END AS classification_reliability,
        1 AS adjust_flag 
    FROM 
        subsc_classification_flags
),

----------------------------------------------------------------------
-- 7. [Order ID Normalization] 親子の絆キー（Order Link Key）の生成
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
order_id_normalization AS (
    SELECT
        *,
        TRIM(
            CASE 
                -- 末尾が -0XX の場合、枝番（ハイフン含む下4桁）を除去して元注文IDとする
                WHEN REGEXP_LIKE(TRIM(order_id), '.*-0[0-9]{2}$') THEN LEFT(TRIM(order_id), LENGTH(TRIM(order_id)) - 4)
                ELSE TRIM(order_id)
            END 
        ) AS order_link_key
    FROM
        base_table
)

----------------------------------------------------------------------
-- 8. [Final Output] 最終結果出力
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
SELECT
    -- ====== IDs ======
    x.user_id, 
    x.order_id, 
    z.order_link_key,
    x.line_no,

    -- ====== Product Info ======
    x.product_id, 
    x.product_name, 
    x.product_external_id4, 
    x.product_analysis_category_level_5,
    CASE WHEN y.adjust_flag = 1 THEN y.adjusted_category_level_6 ELSE x.product_analysis_category_level_6 END AS product_analysis_category_level_6,

    -- ====== Order Info ======
    x.order_type,
    x.order_status,
    CASE
        WHEN x.order_status = 'TMP'      THEN 1   -- 仮注文
        WHEN x.order_status = 'ODR'      THEN 2   -- 受注承認
        WHEN x.order_status = 'ODR_RECG' THEN 3   -- 受注確定
        WHEN x.order_status = 'SHP_ARGD' THEN 4   -- 出荷手配済み
        WHEN x.order_status = 'SHP_COMP' THEN 5   -- 出荷完了
        WHEN x.order_status = 'DLV_COMP' THEN 6   -- 配送完了
        WHEN x.order_status = 'ODR_CNSL' THEN 7   -- キャンセル
        WHEN x.order_status = 'TMP_CNSL' THEN 8   -- 仮注文キャンセル
        ELSE 9 
    END AS order_status_number, 

    x.payment_type,
    x.member_rank_at_order,
    x.latest_ad_code, 
    CASE WHEN x.order_type_without_promo_code IN ('PC','SP','gaibuE') THEN 1 ELSE 0 END AS is_ec_order_without_promo_code,
    x.operator_code,

    -- ====== Dates ======
    x.ordered_at,
    x.scheduled_ship_date,
    x.delivered_at,

    -- ====== Quantity & Subsc ======
    x.quantity,
    x.subsc_id,
    x.subsc_cycle_at_order,
    x.subsc_cycle_at_shipment,

    -- ====== Returns ======
    x.return_exchange_status,
    x.return_reason_note,
    x.return_completed_at,
    x.is_return_order,

    -- ====== Observability & Metadata ======
    COALESCE(NULLIF(TRIM(y.classification_reliability), ''), 'ORIGINAL') AS classification_reliability,
    ROUND(
        100.0 * SUM(CASE WHEN y.classification_reliability = 'MANUAL_HEURISTIC' THEN 1 ELSE 0 END) OVER () 
        / NULLIF(COUNT(*) OVER (), 0), 
    4) AS manual_heuristic_ratio_pct,
    x.imported_at 

FROM 
    base_table x
LEFT JOIN 
    subsc_classification_finalize y ON x.order_id = y.order_id AND x.line_no = y.line_no 
LEFT JOIN 
    order_id_normalization z ON x.order_id = z.order_id AND x.line_no = z.line_no 
;
