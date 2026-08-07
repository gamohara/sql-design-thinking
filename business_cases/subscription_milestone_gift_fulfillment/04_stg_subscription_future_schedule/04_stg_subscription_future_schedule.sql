/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 デジタルギフト特典対象者の定期購入_将来出荷予定展開マスタ
  Subscription Future Shipment Schedule Unpivot — Staging Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. 現在の定期契約状況の取得
     対象者の現在の定期マスタから「次回」「次々回」の出荷予定日を取得する。
  2. F1属性のフェイルセーフ結合
     定期ID（subsc_id）をキーに、F1時点のコース属性（初回3本等）を紐付ける。
     顧客が途中で定期を解約・再開し定期IDが変わってしまった場合に備え、
     定期IDでの結合に失敗した場合はユーザーID単位で属性を救済する2段構えとする。
  3. 未来予定の縦積み展開
     横持ち（カラム）で保持していた「次回」「次々回」出荷予定日を、それぞれ独立した
     1行に展開（アンピボット）し、後続で実績データと同様に扱えるようにする。

  1. Current Subscription Status Retrieval
     Retrieves the next and next-next scheduled shipment dates from the subscription master.
  2. Fail-Safe F1 Attribute Join
     Links F1-time course attributes via subscription ID, with a user-ID-based fallback for
     customers whose subscription ID changed after a cancel/restart.
  3. Future Schedule Unpivoting
     Unpivots the two future-date columns into independent rows so they can be treated
     uniformly alongside actual shipment records downstream.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
  1. purchase_f1_base
     起点(F1)データとコース属性の取得
  2. extract_subsc_status_base
     現在の定期契約ステータス（次回・次々回出荷日）の取得
  3. attempt_subsc_id_join
     定期IDベースの厳密な属性紐付け
  4. fallback_userid_join
     ユーザーIDベースの救済紐付け（フェイルセーフ）
  5. unpivot_future_shipments
     次回・次々回出荷予定日の縦積み展開
  6. Final Output
     状態カテゴリの付与と出力

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  subsc_id, ship_date (1定期につき最大2行)

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  user_id, subsc_id, ship_date

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: window functions, UNION ALL)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 定期購入_将来出荷予定ステージングテーブル
  stg_subscription_future_schedule
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [Anchor] 起点となるF1データとコース属性の取得
--    Data Grain: user_id
----------------------------------------------------------------------
purchase_f1_base AS (
    SELECT
        a.user_id,
        a.order_id,
        a.subsc_id,

        a.is_product_a_first_order,
        a.is_product_b_first_order,
        a.is_course_3bottle_first,
        a.is_course_upgraded_1_to_2,
        a.is_course_upgraded_1_to_3,

        a.product_category,
        a.subsc_category,
        a.ship_category,

        a.is_cus_black,
        a.is_cus_deleted_merged,
        a.is_cus_merged,

        1 AS is_joined -- 結合判定用フラグ

    FROM
        stg_gift_eligible_order_confirmed a -- 【前工程】02_stg_gift_eligible_order_confirmed

    INNER JOIN
        (
            SELECT
                user_id,
                MIN(order_id) AS min_order_id
            FROM
                stg_gift_eligible_order_confirmed
            GROUP BY
                user_id
        ) b
    ON a.order_id = b.min_order_id
),

----------------------------------------------------------------------
-- 2. [Base] 顧客の現在の定期ステータスの取得
--    Data Grain: subsc_id
----------------------------------------------------------------------
extract_subsc_status_base AS (
    SELECT
        c.user_id,
        c.subsc_id,
        c.product_id,
        c.product_name,
        c.next_scheduled_ship_date,
        c.next_next_scheduled_ship_date,
        c.quantity

    FROM
        dim_subscription_status c -- 【マスタ】現行の定期契約ステータス

    INNER JOIN
        purchase_f1_base d -- 01. の情報 (F1対象者のみに絞る)
    ON c.user_id = d.user_id

    WHERE
        c.is_subsc_active = 1 -- 定期継続フラグ「1」のみに絞る
),

----------------------------------------------------------------------
-- 3. [Attribute Join①] 厳密な紐付け（定期IDベース）
--    Data Grain: subsc_id
----------------------------------------------------------------------
attempt_subsc_id_join AS (
    SELECT
        e.user_id,
        e.subsc_id,
        e.product_id,
        e.product_name,
        e.next_scheduled_ship_date,
        e.next_next_scheduled_ship_date,
        e.quantity,

        f.is_product_a_first_order,
        f.is_product_b_first_order,
        f.is_course_3bottle_first,
        f.is_course_upgraded_1_to_2,
        f.is_course_upgraded_1_to_3,

        f.product_category,
        f.subsc_category,

        f.is_cus_black,
        f.is_cus_deleted_merged,
        f.is_cus_merged,

        COALESCE(f.is_joined, 0) AS is_joined_in_subscid,

        MAX(COALESCE(f.is_joined, 0)) OVER(PARTITION BY e.user_id) AS is_joined_in_userid

    FROM
        extract_subsc_status_base e -- 02. の情報

    LEFT JOIN
        purchase_f1_base f -- 01. の情報
    ON e.user_id = f.user_id
    AND e.subsc_id = f.subsc_id
),

----------------------------------------------------------------------
-- 4. [Attribute Join②] 救済紐付け（ユーザーIDベース・フェイルセーフ）
--    Data Grain: subsc_id
----------------------------------------------------------------------
fallback_userid_join AS (
    SELECT
        g.user_id,
        g.subsc_id,
        g.product_id,
        g.product_name,
        g.next_scheduled_ship_date,
        g.next_next_scheduled_ship_date,
        g.quantity,

        CASE WHEN g.is_joined_in_userid <> 1 THEN h.is_product_a_first_order ELSE g.is_product_a_first_order END AS is_product_a_first_order,
        CASE WHEN g.is_joined_in_userid <> 1 THEN h.is_product_b_first_order ELSE g.is_product_b_first_order END AS is_product_b_first_order,
        CASE WHEN g.is_joined_in_userid <> 1 THEN h.is_course_3bottle_first ELSE g.is_course_3bottle_first END AS is_course_3bottle_first,
        CASE WHEN g.is_joined_in_userid <> 1 THEN h.is_course_upgraded_1_to_2 ELSE g.is_course_upgraded_1_to_2 END AS is_course_upgraded_1_to_2,
        CASE WHEN g.is_joined_in_userid <> 1 THEN h.is_course_upgraded_1_to_3 ELSE g.is_course_upgraded_1_to_3 END AS is_course_upgraded_1_to_3,

        CASE WHEN g.is_joined_in_userid <> 1 THEN h.product_category ELSE g.product_category END AS product_category,
        CASE WHEN g.is_joined_in_userid <> 1 THEN h.subsc_category ELSE g.subsc_category END AS subsc_category,

        CASE WHEN g.is_joined_in_userid <> 1 THEN h.is_cus_black ELSE g.is_cus_black END AS is_cus_black,
        CASE WHEN g.is_joined_in_userid <> 1 THEN h.is_cus_deleted_merged ELSE g.is_cus_deleted_merged END AS is_cus_deleted_merged,
        CASE WHEN g.is_joined_in_userid <> 1 THEN h.is_cus_merged ELSE g.is_cus_merged END AS is_cus_merged,

        CASE
            WHEN g.is_joined_in_userid <> 1 THEN 1
            ELSE g.is_joined_in_subscid
        END AS is_joined

    FROM
        attempt_subsc_id_join g -- 03. の情報

    -- 救済用：ユーザーIDのみで結合
    LEFT JOIN
        purchase_f1_base h -- 01. の情報
    ON g.user_id = h.user_id
    AND g.is_joined_in_userid <> 1
),

----------------------------------------------------------------------
-- 5. [Unpivot] 未来予定の縦積み（アンピボット）
--    Data Grain: subsc_id, ship_date (1定期につき最大2行)
----------------------------------------------------------------------
unpivot_future_shipments AS (
    SELECT
        user_id, subsc_id, product_id, product_name,
        next_scheduled_ship_date AS ship_date,
        quantity,
        is_product_a_first_order, is_product_b_first_order,
        is_course_3bottle_first, is_course_upgraded_1_to_2, is_course_upgraded_1_to_3,
        product_category, subsc_category,
        is_cus_black, is_cus_deleted_merged, is_cus_merged, is_joined
    FROM
        fallback_userid_join -- 04. の情報

    UNION ALL

    SELECT
        user_id, subsc_id, product_id, product_name,
        next_next_scheduled_ship_date AS ship_date,
        quantity,
        is_product_a_first_order, is_product_b_first_order,
        is_course_3bottle_first, is_course_upgraded_1_to_2, is_course_upgraded_1_to_3,
        product_category, subsc_category,
        is_cus_black, is_cus_deleted_merged, is_cus_merged, is_joined
    FROM
        fallback_userid_join -- 04. の情報
)

----------------------------------------------------------------------
-- 6. [Final Output]
--    Data Grain: subsc_id, ship_date
----------------------------------------------------------------------
SELECT
    user_id                       AS "ユーザーID",
    subsc_id                      AS "定期購入ID",
    product_id                    AS "商品ID",
    product_name                  AS "商品名",
    ship_date                     AS "出荷日",
    quantity                      AS "注文数",
    is_product_a_first_order      AS "商品ラインA_新規フラグ",
    is_product_b_first_order      AS "商品ラインB_新規フラグ",

    is_course_3bottle_first       AS "初回3本_定期フラグ",
    is_course_upgraded_1_to_2     AS "初回1本→2本_定期フラグ",
    is_course_upgraded_1_to_3     AS "初回1本→3本_定期フラグ",
    product_category               AS "商品_分類",
    subsc_category                 AS "定期_分類",
    NULL                            AS "出荷_分類",
    is_cus_black                   AS "ブラックフラグ",
    is_cus_deleted_merged          AS "削除/統合フラグ",
    is_cus_merged                  AS "顧客統合フラグ"

FROM
    unpivot_future_shipments -- 05. の情報

WHERE
    is_joined = 1

ORDER BY
    user_id ASC, ship_date ASC
;
