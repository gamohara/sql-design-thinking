/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
受注金額の案分計算および整合性検証を行うステージングテーブル
Order Amount Proration and Financial Validation (Staging Layer)

本クエリはEC注文データに対して以下の処理を実施し、
分析に耐えうる正確な明細価格データを生成する。

・注文単位割引の明細案分  
・再計算による金額整合性検証  
・データ品質エラー検出  

This query constructs a staging dataset that performs order-level discount proration,
financial recalculation, and data quality validation for e-commerce order data.

The goal is to transform raw transactional records into
accurate and analytically reliable line-level pricing data.

【ビジネスロジック / Business Logic】
----------------------------------------------------------------------------------------------
1. データクレンジング
   エラーログを参照し、テスト顧客や異常明細などの既知エラーを除外する。
2. 累積和を用いた案分   
   累積和（Running Total）を用いて注文割引を明細単位へ案分する。
3. 金額整合性検証  
   ECシステム計算値と手動再計算値を比較し、最終決済額に最も近い値を採用する。
4. エラー検知 
   再計算した注文金額が1円以上ずれた場合に、データ品質エラーを検出する。
5. 端数処理の調整ロジック  
   割引案分は明細金額の降順で累積計算することで、通貨計算による端数誤差を高額商品に吸収させる。

1. Error Exclusion
   Excludes known problematic orders (test customers, abnormal items)
   using an error registry table.
2. Cumulative Proration
   Allocates order-level discounts to each line item using
   a running total calculation.
3. Dynamic Value Selection
   Compares the EC system's calculated payment with manually
   recalculated values and selects the value closest to the
   final payment (Single Source of Truth).
4. Validation
   Re-aggregates validated values and raises a data quality flag
   if the recalculated order payment differs by more than 1 yen.
5. Rounding Adjustment Strategy
   Discount proration is performed using a running total ordered
   by line price in descending order so that rounding discrepancies
   are absorbed by higher priced items.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
このクエリは以下の処理ステップで構成されています。
This query consists of the following processing layers.

1. error_registry
   除外・補正対象リストの取得
   Retrieve exclusion/correction list

2. order_item_base
   明細データの整理と累積金額算出
   Cleanse items & calculate running sums

3. order_header
   注文単位のサマリー取得
   Aggregate order-level totals

4. proration_logic
   累積案分割引額の計算
   Calculate cumulative allocated discounts

5. final_pricing
   明細単位の割引額と価格の確定
   Finalize item-level discounts & pricing

6. validation_layer
   金額整合性の検証
   Validate total payment accuracy

7. Final Output
   最終出力と異常検知
   Output final dataset with integrity flags

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
1行は以下の粒度を表します
user_id × order_id × line_no

Each row represents:
user_id × order_id × line_no

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
(user_id, order_id, line_no)

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
本SQLは以下の分析系データベースを想定して設計されている。
・Snowflake  
・BigQuery  
・Redshift  
・PostgreSQL

This SQL is designed for modern analytical databases such as:
・Snowflake  
・BigQuery  
・Amazon Redshift  
・PostgreSQL  

【エラーコード定義 / Error Code Definition】
----------------------------------------------------------------------------------------------
1.MISSING_PRODUCT_MASTER  
  注文データに存在する商品が商品マスタに存在しない場合。
  Product referenced in transactions does not exist in the product master.

2.ORDER_SUBTOTAL_MISMATCH  
  明細小計と受注ヘッダ小計が一致しない場合。
  Aggregated line subtotal differs from the order header subtotal.

3.PAYMENT_AMOUNT_MISMATCH  
  最終検証後の注文合計がシステム決済額と1円以上乖離している場合。
  Recalculated payment differs from system payment by more than 1 yen.

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
後続の注文統合マスタ（Fact Table）に対する
「金額面の唯一の真実（Single Source of Truth）」として機能する中間テーブル
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

error_payment_override AS (
    SELECT user_id, order_id, override_subtotal_amount, error_flag 
    FROM source_error_log 
    WHERE error_reason = 'ABNORMAL_PAYMENT_AMOUNT'
),

----------------------------------------------------------------------
-- 2. [Order Items] 受注明細の整理と案分用累積金額の算出
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
order_item_base AS (
    SELECT
        -- IDs
        ot.order_id,
        ot.line_no,
        ot.product_id,
        COALESCE(NULLIF(pm.product_name, ''), ot.raw_product_name) AS product_name,

        -- Amounts & Tax
        ot.quantity,
        ot.line_subtotal_incl_tax,
        ot.line_tax_amount,
        ot.subsc_support_discount_amount,
        ot.system_discounted_incl_tax,     -- システム上の割引後金額(税込)
        ot.system_discounted_excl_tax,     -- システム上の割引後金額(税抜)
        COALESCE(pm.tax_rate, 100) AS tax_rate,

        -- Base Values for Calculation (継続割引除外後のベース価格)
        ot.line_subtotal_incl_tax - ot.subsc_support_discount_amount AS base_price_incl_tax,
        ot.line_subtotal_incl_tax - ot.line_tax_amount AS base_price_excl_tax,

        -- Proration Denominator (注文単位の合計額)
        SUM(ot.line_subtotal_incl_tax) OVER(PARTITION BY ot.order_id) AS total_order_subtotal_incl_tax,
        SUM(ot.line_subtotal_incl_tax - ot.line_tax_amount) OVER(PARTITION BY ot.order_id) AS total_order_subtotal_excl_tax,

        -- Proration Numerator (累積和: 金額降順で端数を吸収)
        SUM(ot.line_subtotal_incl_tax - ot.line_tax_amount) OVER(
            PARTITION BY ot.order_id 
            ORDER BY (ot.line_subtotal_incl_tax - ot.line_tax_amount) DESC, ot.line_no ASC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_subtotal_excl_tax,

        -- Flags
        CASE WHEN REGEXP_LIKE(TRIM(ot.order_id), '.*-0[0-9]{2}$') THEN 1 ELSE 0 END AS is_return_order,
        CASE WHEN NULLIF(pm.product_name, '') IS NULL THEN 1 ELSE 0 END AS is_missing_master

    FROM 
        raw_order_items ot
    LEFT JOIN 
        dim_products pm ON ot.product_id = pm.product_id

    -- エラーデータの除外 (LEFT JOIN & IS NULL に変換してパフォーマンス向上)
    LEFT JOIN error_test_customer e1 ON ot.order_id = e1.order_id
    LEFT JOIN error_abnormal_items e2 ON ot.order_id = e2.order_id AND ot.line_no = e2.line_no AND ot.product_id = e2.product_id
    WHERE 
        e1.error_flag IS NULL 
        AND e2.error_flag IS NULL
),

----------------------------------------------------------------------
-- 3. [Order Header] 受注ヘッダの整理と割引・手数料の集計
--    Data Grain: order_id
----------------------------------------------------------------------
order_header AS (
    SELECT
        oh.user_id, 
        oh.order_id, 

        -- Override if error exists
        CASE WHEN e3.error_flag = 1 THEN e3.override_subtotal_amount ELSE oh.subtotal_amount END AS order_subtotal_incl_tax,
        oh.total_payment_amount AS system_final_payment,

        -- Discount Totals
        (oh.promo_discount + oh.rank_discount + oh.coupon_discount + oh.point_discount) AS total_discount_incl_points,
        (oh.promo_discount + oh.rank_discount + oh.coupon_discount) AS total_discount_excl_points,

        -- Non-Product Fees (送料・手数料等の合算)
        (oh.shipping_fee + oh.cod_fee + oh.adjustment_amount) 
            - (oh.promo_shipping_discount + oh.promo_fee_discount) AS total_non_product_fees

    FROM 
        raw_orders oh
    LEFT JOIN 
        error_payment_override e3 ON oh.user_id = e3.user_id AND oh.order_id = e3.order_id
),

----------------------------------------------------------------------
-- 4. [Proration Calculation] 累積案分割引額の算出
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
proration_logic AS (
    SELECT
        i.*,
        h.user_id,
        h.total_discount_incl_points,
        h.total_discount_excl_points,
        h.system_final_payment,
        h.total_non_product_fees,
        h.order_subtotal_incl_tax,

        -- Cumulative Proration (ポイント込み)
        CASE WHEN i.total_order_subtotal_incl_tax = 0 THEN 0
        ELSE
            CAST(
                TRUNCATE(h.total_discount_incl_points * (i.cumulative_subtotal_excl_tax * 1.0 / NULLIF(i.total_order_subtotal_excl_tax, 0)), 6) 
            AS DECIMAL(18,6))
        END AS cum_alloc_discount_incl_points,

        -- Validation: 明細小計とヘッダ小計の不一致検知
        CASE WHEN i.total_order_subtotal_incl_tax <> h.order_subtotal_incl_tax THEN 1 ELSE 0 END AS is_subtotal_mismatch

    FROM 
        order_item_base i
    LEFT JOIN 
        order_header h ON i.order_id = h.order_id
    WHERE 
        i.is_return_order = 0
),

----------------------------------------------------------------------
-- 5. [Discount Finalization] 明細別・割引額の確定 (LAG関数による差分抽出)
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
finalize_discount AS (
    SELECT
        *,
        CAST(
            cum_alloc_discount_incl_points 
            - COALESCE(LAG(cum_alloc_discount_incl_points) OVER(PARTITION BY order_id ORDER BY base_price_excl_tax DESC, line_no ASC), 0)
        AS DECIMAL(18,6)) AS item_discount_incl_points
    FROM 
        proration_logic
),

----------------------------------------------------------------------
-- 6. [Price Calculation] 割引を加味した手動計算金額の算出
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
manual_price_calculation AS (
    SELECT
        *,
        -- 手動計算値 (税込)
        CAST((base_price_incl_tax - item_discount_incl_points) AS INTEGER) AS manual_discounted_incl_tax,
        -- 手動計算値 (税抜)
        CAST(((base_price_incl_tax - item_discount_incl_points) * 100.0) / NULLIF(tax_rate, 0) AS INTEGER) AS manual_discounted_excl_tax
    FROM 
        finalize_discount
),

----------------------------------------------------------------------
-- 7.[Validation & Selection] システム値と手動計算値の比較・採用
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
price_evaluation AS (
    SELECT
        *,
        -- Error Margin Calculation (正解との差分計算)
        system_final_payment - (SUM(system_discounted_incl_tax) OVER(PARTITION BY order_id) + total_non_product_fees) AS sys_payment_diff,
        system_final_payment - (SUM(manual_discounted_incl_tax) OVER(PARTITION BY order_id) + total_non_product_fees) AS manual_payment_diff
    FROM 
        manual_price_calculation
),

final_price_selection AS (
    SELECT
        *,
        -- Selection Logic: より正解に近い（差分が小さい）方を採用する
        CASE 
            WHEN ABS(sys_payment_diff) > ABS(manual_payment_diff) THEN manual_discounted_incl_tax
            ELSE system_discounted_incl_tax 
        END AS validated_discounted_incl_tax,

        CASE 
            WHEN ABS(sys_payment_diff) > ABS(manual_payment_diff) THEN manual_discounted_excl_tax
            ELSE system_discounted_excl_tax 
        END AS validated_discounted_excl_tax
    FROM 
        price_evaluation
)

----------------------------------------------------------------------
-- 8. [Final Output] 最終結果出力と品質フラグ
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
SELECT
    user_id,
    order_id,
    line_no,
    product_id,
    product_name,
    quantity,
    system_final_payment,
    validated_discounted_excl_tax,

    -- Error Aggregation (カンマ区切りでエラー内容を出力)
    RTRIM(
        CONCAT(
            CASE WHEN is_missing_master = 1 THEN 'MISSING_PRODUCT_MASTER, ' ELSE '' END,
            CASE WHEN is_subtotal_mismatch = 1 THEN 'ORDER_SUBTOTAL_MISMATCH, ' ELSE '' END,
            CASE WHEN ABS(system_final_payment - (SUM(validated_discounted_incl_tax) OVER(PARTITION BY order_id) + total_non_product_fees)) > 1 
                 THEN 'PAYMENT_AMOUNT_MISMATCH' ELSE '' END
        ), ', '
    ) AS error_detail

FROM 
    final_price_selection
;
