/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 アウトバウンドアップセルによる追加特典対象者マスタ
  Upsell-Driven Bonus Gift Eligibility Detection — Intermediate Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. アップセル対象パターンの特定
     「初回1本、2回目からは2本コース」で申し込んだ顧客に対し、コールセンターから
     定期2回目お届け前にアウトバウンド（電話営業）を行い「2回目から3本に変更しませんか」と
     案内する運用がある。成功した場合のみ特例で「定期2回目発送後に追加の特典」を付与する。
  2. コース変更（アップセル・ダウンセル）の厳密な検知
     1人の顧客が過去に何度も購入・解約を繰り返しているケースを想定し、「どの時点のF1で、
     どのコースを約束したか」を出荷日の時系列で厳密に比較し、本当の意味でのコース変更を検知する。
  3. 複数ファクトによる裏付けと運用漏れの検知
     同梱物の印字履歴、応対メモのアウトバウンド実施履歴、手動対応リストを横付けし、
     システムで拾い上げたのにリストに載っていない「対象漏れ」を検知する。

  1. Upsell Target Pattern Identification
     Identifies customers on the "1 bottle then 2 bottles" course who received a successful
     outbound upsell call before their 2nd shipment, qualifying them for a bonus gift.
  2. Strict Course-Change Detection
     Accounts for customers who repeatedly purchase and cancel by comparing course promises
     across time (shipment date) to detect genuine course changes, avoiding false positives.
  3. Multi-Fact Corroboration & Gap Detection
     Cross-references insert markers, CS outbound call history, and the manual target list
     to catch cases the system flagged but the operator's list missed.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
  1. extract_f2_orders
     F2（2回目）注文データの取得
  2. extract_f1_attributes
     F1時点のコース属性データの取得（複数回購入対応）
  3. extract_subsc_status
     現在の定期継続ステータスの取得
  4. extract_gift_promo_marker / extract_outbound_call_history
     ファクト（同梱物・OB履歴）の取得
  5. detect_upsell_customers
     F1重複購入によるコース変更の検知
  6. aggregate_upsell_facts
     ファクトの横付けと手動リストとの突合
  7. Final Output
     追加特典日の算出と出力

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  Order Level (F2の注文単位)

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  user_id, order_id

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: window functions)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 アップセル追加特典中間テーブル
  int_bonus_gift_upsell_detection
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [F2 Base] F2（定期2回目）データの取得
--    Data Grain: order_id
----------------------------------------------------------------------
extract_f2_orders AS (
    SELECT
        *,
        MAX(CASE WHEN order_no = 1 THEN ship_date ELSE NULL END)
            OVER(PARTITION BY user_id) AS ship_date_f1,
        CASE WHEN quantity >= 3 THEN 1 ELSE 0 END AS is_course_3bottle_in_orderid

    FROM
        (
            SELECT
                user_id, order_id, order_no, product_id, product_name,
                order_status, order_status_numbr, is_payment_received,
                ship_date, delivered_date, quantity, is_sys_return, return_completed_date,
                is_product_a_first_order, is_product_b_first_order,
                is_course_3bottle_first, is_course_upgraded_1_to_2, is_course_upgraded_1_to_3,
                product_category, subsc_category, ship_category,
                is_cus_black, is_cus_deleted_merged, is_cus_merged,
                order_type
            FROM
                int_customer_gift_journey_timeline -- 【前工程】05_int_customer_gift_journey_timeline
        )
    WHERE
        order_no = 2
),

----------------------------------------------------------------------
-- 2. [F1 Attributes] F1（初回）時の属性データの取得（複数回購入対応）
--    Data Grain: user_id
----------------------------------------------------------------------
extract_f1_attributes AS (
    SELECT
        user_id,
        MAX(is_course_3bottle_first)      AS max_is_course_3bottle_first,
        MAX(is_course_upgraded_1_to_2)    AS max_is_course_upgraded_1_to_2,
        MAX(is_course_upgraded_1_to_3)    AS max_is_course_upgraded_1_to_3,
        MIN(ship_date_course_3bottle)     AS ship_date_course_3bottle,
        MAX(ship_date_upgraded_1_to_2)    AS ship_date_upgraded_1_to_2,
        MIN(ship_date_upgraded_1_to_3)    AS ship_date_upgraded_1_to_3

    FROM
        (
            SELECT
                user_id,
                is_course_3bottle_first,
                is_course_upgraded_1_to_2,
                is_course_upgraded_1_to_3,

                MAX(CASE WHEN is_course_3bottle_first = 1 THEN ship_date ELSE NULL END)
                    OVER(PARTITION BY user_id) AS ship_date_course_3bottle,
                MAX(CASE WHEN is_course_upgraded_1_to_2 = 1 THEN ship_date ELSE NULL END)
                    OVER(PARTITION BY user_id) AS ship_date_upgraded_1_to_2,
                MAX(CASE WHEN is_course_upgraded_1_to_3 = 1 THEN ship_date ELSE NULL END)
                    OVER(PARTITION BY user_id) AS ship_date_upgraded_1_to_3
            FROM
                stg_gift_eligible_purchase_base -- 【前工程】01_stg_gift_eligible_purchase_base
        )
    GROUP BY
        user_id
),

----------------------------------------------------------------------
-- 3. [Subsc Status] 顧客の現在の定期ステータスの取得
--    Data Grain: user_id
----------------------------------------------------------------------
extract_subsc_status AS (
    SELECT
        user_id,
        MAX(is_subsc_active) AS is_subsc_active
    FROM
        dim_subscription_status -- 【マスタ】現行の定期契約ステータス
    WHERE
        is_subsc_active = 1
    GROUP BY
        user_id
),

----------------------------------------------------------------------
-- 4a. [Fact①] 追加特典同梱物マーカーの履歴取得
--     Data Grain: user_id
----------------------------------------------------------------------
extract_gift_promo_marker AS (
    SELECT
        user_id,
        1 AS is_bonus_gift_insert_marker
    FROM
        raw_catalog_gift_markers -- カタログ/プレゼント同梱物編集
    WHERE
        insert_product_code = 'GIFT_INSERT_CODE_BONUS' -- 明細書への追加特典印字用ダミー商品コード
    GROUP BY
        user_id
),

----------------------------------------------------------------------
-- 4b. [Fact②] アウトバウンド（電話営業）実施履歴の取得
--     Data Grain: user_id
----------------------------------------------------------------------
extract_outbound_call_history AS (
    SELECT
        user_id,
        MAX(incident_memo)   AS incident_memo,
        MAX(message_date)    AS message_date,
        1                     AS has_outbound_call_note
    FROM
        raw_cs_incident_notes -- CS応対履歴（応対メモ）
    WHERE
        incident_category_code = 'OUTBOUND_UPSELL' -- 応対メモにて「アウトバウンド/注文あり」のカテゴリ登録あり
    GROUP BY
        user_id
),

----------------------------------------------------------------------
-- 5. [Course Change Detection] F1重複購入によるコース変更検知
--    Data Grain: order_id
----------------------------------------------------------------------
detect_upsell_customers AS (
    SELECT
        c.*
    FROM
        extract_f2_orders c -- 01. F2の実績情報（最古のF1由来）

    LEFT JOIN
        extract_f1_attributes d -- 02. F1の約束（コース）情報（複数F1対応）
    ON c.user_id = d.user_id

    WHERE
        -- タイプ2(2本コース)だったのに、再購入でタイプ1やタイプ3にした顧客を除外
        (
            c.is_course_upgraded_1_to_2 = 1
        AND COALESCE(d.max_is_course_3bottle_first, 0) <> 1
        AND COALESCE(d.max_is_course_upgraded_1_to_3, 0) <> 1
        )
       OR
        -- (逆パターン) 本来タイプ1やタイプ3だったのに、再購入でタイプ2にした顧客を抽出
        (
          (
            (c.is_course_3bottle_first = 1 AND c.ship_date_f1 > d.ship_date_course_3bottle)
             OR (c.is_course_upgraded_1_to_3 = 1 AND c.ship_date_f1 > d.ship_date_upgraded_1_to_3)
          )
        AND (COALESCE(d.max_is_course_upgraded_1_to_2, 0) = 1 AND c.ship_date_f1 < d.ship_date_upgraded_1_to_2)
        )
),

----------------------------------------------------------------------
-- 6. [Fact Aggregation] ファクトデータの横付けと手動リストの突合
--    Data Grain: order_id
----------------------------------------------------------------------
aggregate_upsell_facts AS (
    SELECT
        e.*,

        COALESCE(f.is_subsc_active, 0)            AS is_subsc_active,
        COALESCE(g.is_bonus_gift_insert_marker, 0) AS is_bonus_gift_insert_marker,
        COALESCE(h.has_outbound_call_note, 0)      AS has_outbound_call_note,
        h.incident_memo,
        h.message_date,

        COALESCE(i.is_registered, 0) AS is_eligible_for_bonus_gift,

        CASE
            WHEN i.is_registered IS NULL THEN '追加特典_対象漏れ'
            ELSE NULL
        END AS check_for_bonus_gift

    FROM
        detect_upsell_customers e -- 05. アップセル候補者

    LEFT JOIN
        extract_subsc_status f -- 03. 定期ステータス
    ON e.user_id = f.user_id

    LEFT JOIN
        extract_gift_promo_marker g -- 04a. 同梱物履歴
    ON e.user_id = g.user_id

    LEFT JOIN
        extract_outbound_call_history h -- 04b. OB履歴
    ON e.user_id = h.user_id

    -- 通常のCSV突合（対象者リストとの紐付け）
    LEFT JOIN
        map_bonus_gift_manual_targets i -- 追加特典対象者リスト
    ON e.user_id = i.user_id
    AND e.order_id = i.order_id

    -- 特例追加のCSV突合（システム条件外の手動救済用）
    LEFT JOIN
        map_bonus_gift_manual_targets j -- 追加特典対象者リスト
    ON e.user_id = j.user_id
    AND e.order_id = j.order_id
    AND j.exception_type = 'IRREGULAR_ADD'

    WHERE
        e.is_course_3bottle_in_orderid = 1
       OR COALESCE(j.is_registered, 0) = 1
)

----------------------------------------------------------------------
-- 7. [Final Output] 分析用データの整形と「追加特典発送予定日」の算出
--    Data Grain: order_id
----------------------------------------------------------------------
SELECT
    user_id                    AS "ユーザーID",
    order_id                   AS "注文ID",
    ship_date_f1               AS "出荷日_F1",
    ship_date                  AS "出荷日_F2",

    -- ※運用ルールの歴史的変遷に合わせて、F2出荷日からの加算日数を動的に変更
    CASE
        WHEN ship_date BETWEEN '2024-01-01' AND '2024-11-30' THEN DATEADD(day, 7, ship_date)
        WHEN ship_date BETWEEN '2024-12-01' AND '2025-03-15' THEN DATEADD(day, 12, ship_date)
        WHEN ship_date BETWEEN '2025-03-16' AND '2025-12-10' THEN DATEADD(day, 15, ship_date)
        WHEN ship_date >= '2025-12-11' THEN DATEADD(day, 30, ship_date)
        ELSE NULL
    END AS "追加特典日_デジタルギフト",

    order_status                  AS "注文ステータス",
    is_payment_received           AS "入金済フラグ",
    is_course_3bottle_in_orderid  AS "3本定期フラグ_注文ID",
    is_subsc_active               AS "定期継続フラグ",
    is_sys_return                 AS "返品フラグ_システム基準",
    return_completed_date         AS "返品受付日",

    is_bonus_gift_insert_marker   AS "追加特典ダミー_同梱フラグ",
    has_outbound_call_note        AS "OB実施フラグ",
    message_date                  AS "OB実施日",
    incident_memo                 AS "OBメモ",

    is_cus_black                  AS "ブラックフラグ",
    is_cus_deleted_merged         AS "削除/統合フラグ",
    is_cus_merged                 AS "顧客統合フラグ",

    product_category               AS "商品_分類",
    subsc_category                 AS "定期_分類",
    '2回目出荷'                     AS "出荷_分類",

    is_eligible_for_bonus_gift     AS "追加特典フラグ",
    check_for_bonus_gift           AS "対象漏れチェック_追加特典"

FROM
    aggregate_upsell_facts -- 06. の情報

ORDER BY
    ship_date_f1 ASC, ship_date ASC, user_id ASC
;
