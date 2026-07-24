/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 F2以降_継続出荷実績マスタ
  Subsequent Shipment History Extraction (F2+) — Staging Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. 起点(F1)アンカーの特定
     確定済みF1リストから、顧客ごとの最古の出荷日を「起点」として取得する。
  2. F2以降の実績抽出
     起点の出荷日より後に発生した定期購入の明細のみを、注文単位に集約して抽出する。
  3. 同日複数出荷の警告付与
     システムエラーや顧客操作ミス等による「同一顧客・同一出荷日の複数注文」を
     警告フラグとして可視化し、後続処理での精緻な例外判定を可能にする。

  1. F1 Anchor Identification
     Retrieves the earliest shipment date per customer from the confirmed F1 list as the anchor.
  2. F2+ Actuals Extraction
     Extracts subscription line items shipped after the F1 anchor date, aggregated to order grain.
  3. Same-Day Multi-Shipment Warning
     Flags cases where a customer has multiple orders shipped on the same date (e.g., due to
     system errors or duplicate operations), enabling precise downstream exception handling.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
  1. purchase_f1_base
     起点(F1)出荷日の取得
     Retrieval of the F1 anchor shipment date per customer.

  2. extract_f2_and_later_orders
     F1以降の定期購入明細の抽出
     Extraction of subscription line items shipped after F1.

  3. agg_and_flag_daily_orders
     注文単位への集約と同日複数出荷の検知
     Aggregation to order grain and same-day multi-shipment flagging.

  4. Final Output
     状態カテゴリの付与と出力

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  Order Level (F2以降の注文単位)

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  user_id, order_id

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: window functions, LISTAGG)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 F2以降_継続出荷実績ステージングテーブル
  stg_subsequent_shipment_history
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [Anchor] 起点となるF1出荷日の取得
--    Data Grain: user_id
----------------------------------------------------------------------
purchase_f1_base AS (
    SELECT
        user_id,
        MIN(ship_date) AS ship_date_f1
    FROM
        stg_gift_eligible_order_confirmed -- 【前工程】02_stg_gift_eligible_order_confirmed
    GROUP BY
        user_id
),

----------------------------------------------------------------------
-- 2. [Actuals Extraction] F2以降の対象商品の明細データの取得
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
extract_f2_and_later_orders AS (
    SELECT
        a.user_id,
        a.order_id,
        a.line_no,

        a.product_id,
        a.product_name,

        a.is_product_a_first_order,
        a.is_product_b_first_order,

        a.order_status,
        a.order_status_numbr,
        a.is_payment_received,
        a.ordered_at,
        a.ordered_date,
        a.ship_date,
        a.delivered_date,

        a.quantity,
        a.is_subsc,
        a.subsc_id,

        a.is_sys_return,
        a.return_completed_date

    FROM
        raw_gift_eligible_purchases a -- 【元データ】特典対象商品ラインの購入明細抽出

    INNER JOIN
        purchase_f1_base b -- 01. の情報
    ON a.user_id = b.user_id

    WHERE
        a.ship_date > b.ship_date_f1
      AND a.is_subsc = 1
),

----------------------------------------------------------------------
-- 3. [Aggregation & Flagging] 注文単位への集約と同日複数出荷の検知
--    Data Grain: order_id
----------------------------------------------------------------------
agg_and_flag_daily_orders AS (
    SELECT
        c.*,

        CASE
            WHEN COUNT(c.order_id) OVER(PARTITION BY c.user_id, c.ship_date) > 1 THEN 1
            ELSE 0
        END AS has_same_day_multiple_ship,

        CASE
            WHEN COUNT(c.order_id) OVER(PARTITION BY c.user_id, c.ship_date) > 1
             THEN
                 LISTAGG(c.order_id, ', ')
                     WITHIN GROUP (ORDER BY c.ordered_at ASC, c.order_id ASC)
                     OVER(PARTITION BY c.user_id, c.ship_date)
            ELSE NULL
        END AS orderid_in_ship_date

    FROM
    (
        SELECT
            user_id,
            order_id,
            LISTAGG(DISTINCT product_id, ' / ')   AS agg_product_id,
            LISTAGG(DISTINCT product_name, ' / ') AS agg_product_name,
            MAX(is_product_a_first_order)         AS is_product_a_first_order,
            MAX(is_product_b_first_order)         AS is_product_b_first_order,
            MAX(order_status)                     AS order_status,
            MAX(order_status_numbr)                AS order_status_numbr,
            MAX(is_payment_received)               AS is_payment_received,
            MAX(ordered_at)                        AS ordered_at,
            MAX(ordered_date)                      AS ordered_date,
            MAX(ship_date)                         AS ship_date,
            MAX(delivered_date)                    AS delivered_date,
            SUM(quantity)                          AS quantity,
            MAX(subsc_id)                          AS subsc_id,
            MAX(is_sys_return)                     AS is_sys_return,
            MAX(return_completed_date)             AS return_completed_date
        FROM
            extract_f2_and_later_orders -- 02. の情報
        GROUP BY
            user_id, order_id
    ) c

    -- 【手動対応】注文単位の削除リストを結合
    LEFT JOIN
        map_gift_manual_exceptions d -- 手動対応リスト（注文単位の削除）
    ON c.order_id = d.order_id
    AND d.exception_type = 'DELETE_BY_ORDER'

    WHERE
        COALESCE(d.is_deleted_by_order_list, 0) <> 1
      -- F2以降のデータとして抽出するため、誤って再度新規コードを利用した購入は除外
      AND c.is_product_a_first_order <> 1
      AND c.is_product_b_first_order <> 1
)

----------------------------------------------------------------------
-- 4. [Final Output] 分析・確認用データの整形
--    Data Grain: order_id
----------------------------------------------------------------------
SELECT
    user_id                    AS "ユーザーID",
    order_id                   AS "注文ID",
    agg_product_id             AS "商品ID",
    agg_product_name           AS "商品名",
    order_status               AS "注文ステータス",
    order_status_numbr         AS "受注明細状態",
    is_payment_received        AS "入金済フラグ",
    ordered_at                 AS "受注日時",
    ordered_date                AS "受注日",
    ship_date                  AS "出荷日",
    delivered_date              AS "配達完了日",
    subsc_id                   AS "定期購入ID",
    quantity                   AS "注文数",
    is_sys_return              AS "返品フラグ_システム基準",
    return_completed_date       AS "返品受付日",

    is_product_a_first_order   AS "商品ラインA_新規フラグ",
    is_product_b_first_order   AS "商品ラインB_新規フラグ",

    has_same_day_multiple_ship AS "同日複数出荷フラグ",

    CASE
        WHEN has_same_day_multiple_ship = 1 THEN '出荷内容_同日複数出荷'
        ELSE NULL
    END AS "同日出荷チェック_大分類",

    orderid_in_ship_date       AS "同日出荷チェック_詳細_注文ID"

FROM
    agg_and_flag_daily_orders -- 03. の情報
;
