/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 デジタルギフト配信タイミング手動調整マスタ（経過割合アルゴリズム）
  Manual Gift Timing Adjustment via Elapsed-Ratio Algorithm — Intermediate Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. 問い合わせ対応の公平性確保
     特典の配信予定日について顧客から問い合わせがあった際、単純に「連絡してきた人だけ
     すぐに送る」運用は、延長前の期間から待ってくれている他の顧客との間で不公平を生む。
  2. 経過割合ベースの段階的短縮アルゴリズム
     「出荷日からどれくらいの日数が経過しているか（経過割合）」を算出し、その割合に
     応じて「残り日数を自動でN分割して短縮する」ことで、待機期間に比例した
     なだらかで公平な前倒し対応をシステム的に実現する。

  1. Fairness in Inquiry Handling
     Simply expediting delivery for whoever contacts support would be unfair to customers
     who have been waiting patiently since before any timing extension.
  2. Elapsed-Ratio Graduated Shortening Algorithm
     Computes the proportion of the standard wait period already elapsed and shortens the
     remaining wait by a graduated divisor based on that ratio, ensuring the acceleration is
     proportional to how long the customer has already waited.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
  1. import_base_journey
     ベースとなる購入ジャーニーと規定の特典予定日の取得
  2. csv_timing_adjust_list
     手動変更リスト（CSV）の取得と基礎日数の計算
  3. calc_elapsed_ratio
     経過割合（％）の算出
  4. calc_shorten_days
     前倒し日数の自動計算
  5. integrated_adjusted_timing
     調整済み予定日の上書き（オーバーライド）
  6. Final Output

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  user_id, order_id

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  user_id, order_id

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: DATEDIFF / DATEADD)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 配信タイミング調整済中間テーブル
  int_gift_timing_manual_override
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [Base] 全購入ジャーニーの読み込み
--    Data Grain: user_id, order_id
----------------------------------------------------------------------
import_base_journey AS (
    SELECT
        user_id, order_id, order_no, product_id, product_name,
        order_status, order_status_numbr, is_payment_received,
        ship_date, delivered_date, digital_gift_present_date,
        is_sys_return, return_completed_date,

        is_product_a_first_order, is_product_b_first_order,
        is_course_3bottle_first, is_course_upgraded_1_to_2, is_course_upgraded_1_to_3,
        is_eligible_for_bonus_gift,

        product_category, subsc_category, ship_category,
        is_cus_black, is_cus_deleted_merged, is_cus_merged,

        ship_interval_days -- 前回出荷日からの経過日数

    FROM
        stg_gift_timing_base -- 【GUIパラメータ層】07の出力に基礎リードタイム(7/12/15/30日)を適用した出荷情報
),

----------------------------------------------------------------------
-- 2. [Manual List] CS担当者による配信タイミング変更リストの取得
--    Data Grain: user_id, order_id
----------------------------------------------------------------------
csv_timing_adjust_list AS (
    SELECT
        user_id,
        order_id,
        ship_date,
        digital_gift_present_date, -- 既定の特典配信日

        product_subsc_ship_category,

        is_auto_timing_adjust,     -- 自動調整するかどうかのフラグ
        manual_timing_adjust_days, -- 手動調整したい場合の日数

        DATEDIFF(day, ship_date, CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE)             AS days_since_ship,
        DATEDIFF(day, CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE, digital_gift_present_date) AS days_until_gift_email,
        DATEDIFF(day, ship_date, digital_gift_present_date)                                            AS days_from_ship_to_gift_email

    FROM
        map_gift_timing_adjustments -- 配信タイミング変更リスト
),

----------------------------------------------------------------------
-- 3. [Elapsed Ratio] 経過割合（％）の算出
--    Data Grain: user_id, order_id
----------------------------------------------------------------------
calc_elapsed_ratio AS (
    SELECT
        *,
        COALESCE(
            ROUND(
                (days_since_ship)::FLOAT /
                NULLIF(days_from_ship_to_gift_email, 0)
            , 2)
        , 0.0) AS elapsed_ratio

    FROM
        csv_timing_adjust_list -- 02. の情報
),

----------------------------------------------------------------------
-- 4. [Shorten Days] 前倒し日数の自動計算
--    Data Grain: user_id, order_id
----------------------------------------------------------------------
calc_shorten_days AS (
    SELECT
        *,
        CASE
            WHEN is_auto_timing_adjust <> 1 THEN manual_timing_adjust_days
            ELSE
                CASE
                    WHEN elapsed_ratio <= 0.20 THEN GREATEST(ROUND(days_until_gift_email / 2.0), 1)
                    WHEN elapsed_ratio <= 0.40 THEN GREATEST(ROUND(days_until_gift_email / 3.0), 1)
                    WHEN elapsed_ratio <= 0.60 THEN GREATEST(ROUND(days_until_gift_email / 4.0), 1)
                    WHEN elapsed_ratio <= 0.80 THEN GREATEST(ROUND(days_until_gift_email / 5.0), 1)
                    WHEN elapsed_ratio <= 0.95 THEN 1
                    ELSE 0
                END
        END AS shorten_days

    FROM
        calc_elapsed_ratio -- 03. の情報
),

----------------------------------------------------------------------
-- 5. [Override] 調整済み予定日の上書き
--    Data Grain: user_id, order_id
----------------------------------------------------------------------
integrated_adjusted_timing AS (
    SELECT
        a.user_id, a.order_id, a.order_no, a.product_id, a.product_name,
        a.order_status, a.order_status_numbr, a.is_payment_received,
        a.ship_date, a.delivered_date,

        CASE
            WHEN b.digital_gift_present_date_adjusted IS NOT NULL THEN b.digital_gift_present_date_adjusted
            ELSE a.digital_gift_present_date
        END AS digital_gift_present_date,

        a.is_sys_return, a.return_completed_date,

        a.is_product_a_first_order, a.is_product_b_first_order,
        a.is_course_3bottle_first, a.is_course_upgraded_1_to_2, a.is_course_upgraded_1_to_3,
        a.is_eligible_for_bonus_gift,

        a.product_category, a.subsc_category, a.ship_category,
        a.is_cus_black, a.is_cus_deleted_merged, a.is_cus_merged,
        a.ship_interval_days

    FROM
        import_base_journey a -- 01. の情報

    LEFT JOIN
        (
            SELECT
                *,
                DATEADD(day, shorten_days,
                    CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE
                ) AS digital_gift_present_date_adjusted
            FROM
                calc_shorten_days -- 04. の情報
        ) b
    ON a.user_id = b.user_id
    AND a.order_id = b.order_id
)

----------------------------------------------------------------------
-- 6. [Final Output] 分析・確認用データの整形
--    Data Grain: user_id, order_id
----------------------------------------------------------------------
SELECT
    user_id                        AS "ユーザーID",
    order_id                       AS "注文ID",
    order_no                       AS "注文番号",
    product_id                     AS "商品ID",
    product_name                   AS "商品名",
    order_status                   AS "注文ステータス",
    order_status_numbr             AS "受注明細状態",
    is_payment_received            AS "入金済フラグ",
    ship_date                      AS "出荷日",
    delivered_date                 AS "配達完了日",
    digital_gift_present_date      AS "プレゼント日_デジタルギフト",
    is_sys_return                  AS "返品フラグ_システム基準",
    return_completed_date          AS "返品受付日",
    is_product_a_first_order       AS "商品ラインA_新規フラグ",
    is_product_b_first_order       AS "商品ラインB_新規フラグ",

    is_course_3bottle_first        AS "初回3本_定期フラグ",
    is_course_upgraded_1_to_2      AS "初回1本→2本_定期フラグ",
    is_course_upgraded_1_to_3      AS "初回1本→3本_定期フラグ",
    is_eligible_for_bonus_gift     AS "追加特典ダミー_同梱フラグ",
    product_category               AS "商品_分類",
    subsc_category                 AS "定期_分類",
    ship_category                  AS "出荷_分類",

    is_cus_black                   AS "ブラックフラグ",
    is_cus_deleted_merged          AS "削除/統合フラグ",
    is_cus_merged                  AS "顧客統合フラグ",

    ship_interval_days             AS "出荷リードタイム"

FROM
    integrated_adjusted_timing -- 05. の情報
;
