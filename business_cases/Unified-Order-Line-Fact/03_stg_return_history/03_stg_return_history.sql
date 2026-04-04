/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 返品情報の分離および金額情報付与テーブル
  Return Information Storage & Enrichment (Intermediate Layer)

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. Data Isolation
     前工程（stg_order_info）で正規化されたデータ群から、「返品注文（枝番付きID）」
     のみを安全に分離・抽出します。
  2. Financial Enrichment
     分離した返品データに対し、生のトランザクションテーブル（raw_orders, raw_order_items）
     を再結合し、返品処理に伴う決済金額や税抜金額の詳細情報を補完します。
  3. Audit & Analytics Readiness
     以降の売上集計パイプラインから返品によるノイズを完全に除去しつつ、
     単独での返品分析（返品率、理由分析、LTV補正等）や監査（Audit）に
     即座に利用できるストックテーブルとして保管します。

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
 このクエリは以下の処理ステップで構成されています。
 This query consists of the following processing layers.

  1. return_orders_extracted
     前工程テーブルからの返品データ抽出 (Extract return records using flags)
  2. Final Output
     生データとの結合による金額詳細の付与 (Enrich with raw financial data)

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  Order Line Item (受注明細単位)

【主キー / Primary Key
----------------------------------------------------------------------------------------------
  user_id, order_id, line_no

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (BigQuery / Snowflake / Redshift compatible)
==============================================================================================
*/

WITH 
----------------------------------------------------------------------
-- 1. [Return Data Extraction] 返品データの分離抽出
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
return_orders_extracted AS (
    SELECT
        -- IDs
        user_id,
        order_id,
        order_link_key,      -- 返品元を特定する親子の絆キー (Link key to original order)
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
        operator_code,

        -- Dates
        ordered_at,
        scheduled_ship_date,
        delivered_at,

        -- Quantity & Subsc
        quantity, 
        subsc_id,

        -- Returns
        return_exchange_status,
        return_reason_note, 
        return_completed_at,
        is_return_order 

    FROM
        stg_order_info   -- 【全購入情報】[注文ID/商品枝番]別_注文情報_SQL_1.0
    
    WHERE
        is_return_order = 1
)

----------------------------------------------------------------------
-- 2. [Final Output] 生データ結合と金額情報のエンリッチメント(Enrichment)
--    加工済みテーブルには含まれていない詳細な金額情報を取得するため、
--    生データ（Raw Tables）へアクセスして必要な金額カラムを付与します。
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
SELECT
    -- ====== IDs ======
    ext.user_id, 
    ext.order_id, 
    ext.order_link_key, 
    ext.line_no, 

    -- ====== Product Info ======
    ext.product_id, 
    ext.product_name, 
    ext.product_external_id4, 
    ext.product_analysis_category_level_5, 
    ext.product_analysis_category_level_6, 

    -- ====== Order Info ======
    ext.order_type, 
    ext.order_status, 
    ext.payment_type, 
    ext.member_rank_at_order, 
    ext.latest_ad_code, 
    ext.operator_code, 

    -- ====== Dates ======
    ext.ordered_at, 
    ext.scheduled_ship_date, 
    ext.delivered_at, 

    -- ====== Quantity & Financials ======
    ext.quantity, 

    -- 注文全体の最終支払金額(税込)(割引・配送料・決済手数料・調整金額 全て加味)
    ro.total_payment_amount AS system_return_payment_amount,

    -- 商品別、割引を加味した支払金額(税抜)
    roi.system_discounted_excl_tax AS item_return_discounted_excl_tax,

    -- ====== Subscription ======
    ext.subsc_id, 

    -- ====== Returns ======
    ext.return_exchange_status, 
    ext.return_reason_note, 
    ext.return_completed_at 

FROM
    return_orders_extracted ext 

-- 金額情報を取得するための生データ結合 (Enrichment from Raw Tables)
LEFT JOIN 
    raw_orders ro ON ext.order_id = ro.order_id 
LEFT JOIN 
    raw_order_items roi ON ext.order_id = roi.order_id AND ext.line_no = roi.line_no 
;
