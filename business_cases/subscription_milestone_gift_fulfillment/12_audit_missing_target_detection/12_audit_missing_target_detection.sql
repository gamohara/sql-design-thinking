/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 対象漏れ・復帰検知マスタ
  Missing Target & Recovery Detection — Audit Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  システムが自動抽出した「特典の権利を確実に満たしている対象者」と、運用担当者が手動管理
  している「実際の配信リスト（CSV）」を突き合わせ、CSVへの登録漏れ（配信漏れ）を検知する。

  ★【エラーからの「復帰（リカバリー）」の可視化】
  一度「出荷止まり」「未入金」「メール不備」で配信保留（エラー）となった顧客が、後日
  ステータスを解消（配達完了になる、入金される、メアドを登録する等）した場合、システム
  対象者に復活する。過去の「配信停止台帳（CSV）」と突合し、「出荷ステータス更新」
  「入金ステータス更新」といった【エラーからの復帰理由】をアラート詳細として可視化する
  ことで、運用担当者が「なぜ今日になってこの人が対象に追加されたのか」を即座に納得できる
  設計にしている。

  Cross-references the system's "confirmed eligible" list against the operator's manual
  delivery CSV to catch registration gaps. Additionally, when a previously-held customer
  (blocked by shipment delay, non-payment, or an email issue) recovers, this query cross-
  references the historical hold ledger to surface a human-readable recovery reason.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
  1. manual_target_list / auto_extracted_target_list
     比較対象データの取得（システム側は異常データを事前除外済み）
  2-3. missing_past_target_list / missing_current_target_list
     過去・現在における登録漏れの検知
  4. error_past_target_list
     過去に配信失敗した顧客のメールアドレス更新による復帰検知
  5. combine_all_missing_alerts
     すべての漏れ・復帰アラートの統合
  6. recovery_status_checker
     配信停止リストとの突合による復帰理由の詳細付与
  7. Final Output

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  user_id, product_subsc_ship_category

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  user_id, product_subsc_ship_category

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: string concatenation, hash-key comparison)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 対象漏れ・復帰検知テーブル
  audit_missing_target_detection
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [Manual List] 記録用の手動更新テーブル（CSV）
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
manual_target_list AS (
    SELECT
        gift_seq_no, user_id, digital_gift_present_date, product_subsc_ship_category,
        digital_gift_expiration_date, NULLIF(serial_number, '') AS serial_number,
        irregular_gift_present_date,

        CASE
            WHEN DATEDIFF(day, digital_gift_present_date, CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE) > 0 THEN '過去'
            WHEN DATEDIFF(day, digital_gift_present_date, CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE) = 0 THEN '現在'
            WHEN DATEDIFF(day, digital_gift_present_date, CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE) < 0 THEN '未来'
            ELSE NULL
        END AS time_line

    FROM
        map_gift_target_ledger -- 対象者リスト
),

----------------------------------------------------------------------
-- 2. [System List] 自動抽出された最新の対象者リスト（異常データ事前除外済み）
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
auto_extracted_target_list AS (
    SELECT
        user_id AS user_id_comp, order_id AS order_id_comp, order_no AS order_no_comp,
        order_status AS order_status_comp,

        CASE WHEN is_payment_received = 1 THEN '入金済' ELSE '未入金' END AS payment_status_comp,
        is_payment_received AS is_payment_received_comp,

        ship_date AS ship_date_comp, delivered_date AS delivered_date_comp,
        digital_gift_present_date AS digital_gift_present_date_comp,
        product_subsc_ship_category AS product_subsc_ship_category_comp,
        is_subsc_active AS is_subsc_active_comp,
        is_cus_black AS is_cus_black_comp, is_cus_deleted_merged AS is_cus_deleted_merged_comp,
        is_cus_merged AS is_cus_merged_comp,
        hash_key,
        time_line

    FROM
        int_predelivery_alert_check -- 【前工程】10_int_predelivery_alert_check

    WHERE
        is_shipped_not_delivered <> 1
      AND is_null_email <> 1
      AND is_unreach_email <> 1
      AND is_unsubsc_email <> 1
      AND is_payment_pending <> 1
),

----------------------------------------------------------------------
-- 3. [Missing Past] 過去分の対象漏れチェック
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
missing_past_target_list AS (
    SELECT
        a.user_id_comp AS user_id, a.product_subsc_ship_category_comp AS product_subsc_ship_category,
        a.order_id_comp AS order_id, a.ship_date_comp AS ship_date,
        a.digital_gift_present_date_comp AS digital_gift_present_date,
        a.order_status_comp AS order_status, a.payment_status_comp AS payment_status,
        a.is_payment_received_comp AS is_payment_received, a.is_cus_merged_comp AS is_cus_merged,
        a.hash_key,

        CASE
            WHEN NULLIF(a.user_id_comp, '') IS NOT NULL
             AND NULLIF(b.user_id, '') IS NULL          THEN '過去分_対象漏れ'
            ELSE NULL
        END  AS alert_status_main,

        NULL AS alert_status_detail

    FROM
        (SELECT * FROM auto_extracted_target_list WHERE time_line = '過去') a

    LEFT JOIN
        (SELECT * FROM manual_target_list WHERE time_line = '過去') b
    ON a.user_id_comp = b.user_id
    AND a.product_subsc_ship_category_comp = b.product_subsc_ship_category
),

----------------------------------------------------------------------
-- 4. [Missing Current] 現在（当日）分の対象漏れチェック
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
missing_current_target_list AS (
    SELECT
        c.user_id_comp AS user_id, c.product_subsc_ship_category_comp AS product_subsc_ship_category,
        c.order_id_comp AS order_id, c.ship_date_comp AS ship_date,
        c.digital_gift_present_date_comp AS digital_gift_present_date,
        c.order_status_comp AS order_status, c.payment_status_comp AS payment_status,
        c.is_payment_received_comp AS is_payment_received, c.is_cus_merged_comp AS is_cus_merged,
        c.hash_key,

        CASE
            WHEN NULLIF(c.user_id_comp, '') IS NOT NULL
             AND NULLIF(d.user_id, '') IS NULL          THEN '本日分_対象漏れ'
            ELSE NULL
        END  AS alert_status_main,

        NULL AS alert_status_detail

    FROM
        (SELECT * FROM auto_extracted_target_list WHERE time_line = '現在') c

    LEFT JOIN
        (SELECT * FROM manual_target_list WHERE time_line = '現在') d
    ON c.user_id_comp = d.user_id
    AND c.product_subsc_ship_category_comp = d.product_subsc_ship_category
),

----------------------------------------------------------------------
-- 5. [Recovery Past] 過去分の対象復活チェック（メアド更新による復帰）
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
error_past_target_list AS (
    SELECT
        g.user_id_comp AS user_id, g.product_subsc_ship_category_comp AS product_subsc_ship_category,
        g.order_id_comp AS order_id, g.ship_date_comp AS ship_date,
        g.digital_gift_present_date_comp AS digital_gift_present_date,
        g.order_status_comp AS order_status, g.payment_status_comp AS payment_status,
        g.is_payment_received_comp AS is_payment_received, g.is_cus_merged_comp AS is_cus_merged,
        g.hash_key,
        '過去分_配信失敗' AS alert_status_main,
        NULL              AS alert_status_detail

    FROM
        (SELECT * FROM auto_extracted_target_list WHERE time_line = '過去') g

    INNER JOIN
        (
            SELECT e.*
            FROM manual_target_list e
            INNER JOIN
                stg_past_delivery_bounce f -- 【GUIパラメータ層】不達_過去
            ON e.user_id = f.user_id
            AND e.product_subsc_ship_category = f.product_subsc_ship_category
            WHERE
                e.time_line = '過去'
        ) h
    ON g.user_id_comp = h.user_id
    AND g.product_subsc_ship_category_comp = h.product_subsc_ship_category

    INNER JOIN
        (
            SELECT *
            FROM map_delivery_hold_ledger -- 配信停止リスト
            WHERE
                NULLIF(recorded_hash_key, '') IS NOT NULL -- 過去実績があるため、アドレス未登録(NULL)は除外
        ) i
    ON g.user_id_comp = i.user_id
    AND g.order_id_comp = i.order_id
    AND g.hash_key <> i.recorded_hash_key -- アドレスが更新された（ハッシュが変更された）場合
),

----------------------------------------------------------------------
-- 6. [Combine] 対象漏れアラートの統合
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
combine_all_missing_alerts AS (
    SELECT user_id, product_subsc_ship_category, order_id, ship_date, digital_gift_present_date,
           order_status, payment_status, is_payment_received, is_cus_merged, hash_key,
           alert_status_main, alert_status_detail
    FROM missing_past_target_list WHERE alert_status_main IS NOT NULL

    UNION ALL

    SELECT user_id, product_subsc_ship_category, order_id, ship_date, digital_gift_present_date,
           order_status, payment_status, is_payment_received, is_cus_merged, hash_key,
           alert_status_main, alert_status_detail
    FROM missing_current_target_list WHERE alert_status_main IS NOT NULL

    UNION ALL

    SELECT user_id, product_subsc_ship_category, order_id, ship_date, digital_gift_present_date,
           order_status, payment_status, is_payment_received, is_cus_merged, hash_key,
           alert_status_main, alert_status_detail
    FROM error_past_target_list

    -----------------------------------------------------------
    -- 今後もチェックルールを追加する場合は、ここに UNION ALL で新設してください
    -----------------------------------------------------------
),

----------------------------------------------------------------------
-- 7. [Recovery Reason] 配信停止リストからの復帰理由の追記
--    Data Grain: order_id
----------------------------------------------------------------------
recovery_status_checker AS (
    SELECT
        z.*,

        COALESCE(
            NULLIF(
                TRIM(
                    CASE
                        WHEN COALESCE(y.had_shipping_hold, 0) = 1 AND z.order_status <> y.recorded_order_status
                         AND COALESCE(y.had_payment_hold, 0) = 1 AND z.payment_status = y.recorded_payment_status
                        THEN '出荷ステータス更新（以前は ' || y.recorded_order_status || '）→ 入金ステータス未更新' || ' / '
                        WHEN COALESCE(y.had_shipping_hold, 0) = 1 AND z.order_status <> y.recorded_order_status
                         AND COALESCE(y.had_payment_hold, 0) = 1 AND z.payment_status <> y.recorded_payment_status
                        THEN '出荷ステータス更新（以前は ' || y.recorded_order_status || '）→ 入金ステータス更新（以前は ' || y.recorded_payment_status || '）' || ' / '
                        WHEN COALESCE(y.had_shipping_hold, 0) = 1 AND z.order_status <> y.recorded_order_status
                        THEN '出荷ステータス更新（以前は ' || y.recorded_order_status || '）' || ' / '
                        WHEN COALESCE(y.had_payment_hold, 0) = 1 AND z.payment_status <> y.recorded_payment_status
                        THEN '入金ステータス更新（以前は ' || y.recorded_payment_status || '）' || ' / '
                        ELSE ''
                    END
                    ||
                    CASE
                        WHEN COALESCE(y.had_email_hold, 0) = 1 AND y.recorded_hash_key IS NULL AND z.hash_key IS NOT NULL
                        THEN 'メールアドレス未登録→登録 / '
                        WHEN COALESCE(y.had_email_hold, 0) = 1 AND z.hash_key <> y.recorded_hash_key
                        THEN 'メールアドレス更新 / '
                        ELSE ''
                    END
                , ' /')
            , '')
            , z.alert_status_detail
        ) AS alert_status_detail_adjusted

    FROM
        combine_all_missing_alerts z -- 06. 漏れアラート統合情報

    LEFT JOIN
        map_delivery_hold_ledger y -- 配信停止リスト
    ON z.user_id = y.user_id
    AND z.order_id = y.order_id
)

----------------------------------------------------------------------
-- 8. [Final Output]
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
SELECT
    user_id                       AS "ユーザーID",
    product_subsc_ship_category   AS "商品/定期/出荷_分類",
    order_id                      AS "注文ID",
    ship_date                     AS "出荷日",
    digital_gift_present_date     AS "プレゼント日_デジタルギフト",
    order_status                  AS "注文ステータス",
    payment_status                AS "入金ステータス",
    is_cus_merged                 AS "顧客統合フラグ",

    alert_status_main             AS "アラート_大分類",
    alert_status_detail_adjusted  AS "アラート_詳細"

FROM
    recovery_status_checker -- 07. の復帰判定済情報

ORDER BY
    digital_gift_present_date ASC,
    user_id ASC
;
