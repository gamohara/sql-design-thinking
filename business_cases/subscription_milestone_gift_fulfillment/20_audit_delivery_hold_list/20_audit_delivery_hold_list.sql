/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 配信保留リスト
  Delivery Hold List — Audit Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  当日配信予定であった特典対象者のうち、以下の条件に引っかかり「システムによって配信が
  ストップ（保留）された顧客」を抽出し、その原因を一覧化する。
    1. 配送業者の遅延等でまだ商品が届いていない顧客
    2. メールアドレスが未登録・配信失敗・購読解除の状態にある顧客
    3. 代金がまだ支払われていない（未入金）の顧客（持ち逃げ防止）
    4. 過去に実際に配信を行ったが、届かずに「不達」となった実績がある顧客

  このデータをただ削除して終わらせてしまうと、「なぜこの人に送られなかったのか」を
  追跡できなくなるため、本クエリは「配信ストップ時のスナップショット（証拠）」を記録し、
  運用担当者が事後確認やイレギュラー対応を行うための「配信保留台帳」として機能する。

  ★【運用負荷を最小化するタイムライン制御】
  システムの事前検知機能はプレゼント予定日より前の「未来」の時点からエラーの検知を
  始めるが、本クエリ（配信保留台帳）では、プレゼント予定日が「過去・現在」を迎えた
  データのみを出力する。これにより、まだ付与日を迎えていない未来のデータまで目視確認
  させられる無駄な手作業を排除し、当日対応が必要な「本当のTo-Doリスト」のみを集中管理する。

  ★【アラートのミュート機能】
  運用担当者がCSVに記録・対応済みのデータ、およびシステム上で既に「配信成功」の
  ステータスが付与されているデータは、最終出力から除外（ミュート）される。

  Extracts customers whose gift delivery was automatically held back for cause (delivery
  delay, email issues, non-payment, or a confirmed past bounce), producing a hold ledger for
  post-hoc investigation. Output is restricted to past/current timeline records to avoid
  cluttering the To-Do list with unconfirmed future data, and already-recorded or already-
  delivered targets are muted from the output.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
  1-4. shipped_not_delivered_alert_list ~ past_delivery_failed_alert_list
     各ストップ理由の抽出
  5. integrated_alert_list
     縦結合による統合
  6. exclude_recorded_alerts
     記録済み・配信済みの対象者のミュート
  7. Final Output

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  order_id

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  order_id, check_category

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: UNION ALL)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 配信保留リストテーブル
  audit_delivery_hold_list
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [Stop Reason①] 出荷止まりチェック
--    ★プレゼント予定日が「過去・現在」のもののみに絞り込む。
--    Data Grain: order_id
----------------------------------------------------------------------
shipped_not_delivered_alert_list AS (
    SELECT
        user_id, product_subsc_ship_category, order_id, ship_date, digital_gift_present_date,
        order_status,

        CASE WHEN is_payment_received = 1 THEN '入金済' ELSE '未入金' END AS payment_status,

        is_shipped_not_delivered,
        is_payment_pending,

        CASE
            WHEN is_null_email = 1 OR is_unreach_email = 1 OR is_unsubsc_email = 1 THEN 1
            ELSE 0
        END AS is_email_error,

        '①' || ship_hold_check AS check_category,
        NULL                     AS check_detail,
        hash_key

    FROM
        int_predelivery_alert_check -- 【前工程】10_int_predelivery_alert_check

    WHERE
        ship_hold_check IS NOT NULL
      AND time_line IN ('過去', '現在')
),

----------------------------------------------------------------------
-- 2. [Stop Reason②] メール情報不備チェック
--    Data Grain: order_id
----------------------------------------------------------------------
email_error_alert_list AS (
    SELECT
        user_id, product_subsc_ship_category, order_id, ship_date, digital_gift_present_date,
        order_status,

        CASE WHEN is_payment_received = 1 THEN '入金済' ELSE '未入金' END AS payment_status,

        is_shipped_not_delivered,
        is_payment_pending,

        CASE
            WHEN is_null_email = 1 OR is_unreach_email = 1 OR is_unsubsc_email = 1 THEN 1
            ELSE 0
        END AS is_email_error,

        '②' || email_issue_remarks AS check_category,
        NULL                        AS check_detail,
        hash_key

    FROM
        int_predelivery_alert_check -- 【前工程】10_int_predelivery_alert_check

    WHERE
        email_issue_remarks IS NOT NULL
      AND time_line IN ('過去', '現在')
),

----------------------------------------------------------------------
-- 3. [Stop Reason③] 未入金チェック
--    Data Grain: order_id
----------------------------------------------------------------------
payment_pending_alert_list AS (
    SELECT
        user_id, product_subsc_ship_category, order_id, ship_date, digital_gift_present_date,
        order_status,

        CASE WHEN is_payment_received = 1 THEN '入金済' ELSE '未入金' END AS payment_status,

        is_shipped_not_delivered,
        is_payment_pending,

        CASE
            WHEN is_null_email = 1 OR is_unreach_email = 1 OR is_unsubsc_email = 1 THEN 1
            ELSE 0
        END AS is_email_error,

        '③' || payment_hold_check AS check_category,
        NULL                        AS check_detail,
        hash_key

    FROM
        int_predelivery_alert_check -- 【前工程】10_int_predelivery_alert_check

    WHERE
        payment_hold_check IS NOT NULL
      AND time_line IN ('過去', '現在')
),

----------------------------------------------------------------------
-- 4. [Stop Reason④] 配信失敗チェック (実績からの逆流)
--    Data Grain: order_id
----------------------------------------------------------------------
past_delivery_failed_alert_list AS (
    SELECT
        a.user_id, a.product_subsc_ship_category, a.order_id, a.ship_date, a.digital_gift_present_date,
        a.order_status,

        CASE WHEN a.is_payment_received = 1 THEN '入金済' ELSE '未入金' END AS payment_status,

        a.is_shipped_not_delivered,
        a.is_payment_pending,

        CASE
            WHEN a.is_null_email = 1
              OR a.is_unreach_email = 1
              OR COALESCE(b.has_bounced, 0) = 1
              OR a.is_unsubsc_email = 1 THEN 1
            ELSE 0
        END AS is_email_error,

        '②メールアドレス_配信失敗' AS check_category,
        NULL                        AS check_detail,
        a.hash_key

    FROM
        int_predelivery_alert_check a -- 【前工程】10_int_predelivery_alert_check

    INNER JOIN
        stg_past_delivery_bounce b -- 【GUIパラメータ層】不達_過去
    ON a.user_id = b.user_id
    AND a.product_subsc_ship_category = b.product_subsc_ship_category

    WHERE
        a.time_line IN ('過去', '現在') -- ★未来の予定データが不達実績に引っ張られて出力されるのを防ぐ
),

-----------------------------------------------------------
-- 今後もチェックルールを追加する場合は、ここにCTEを新設してください
-----------------------------------------------------------

----------------------------------------------------------------------
-- 5. [Combine] チェックテーブルの統合
--    Data Grain: order_id
----------------------------------------------------------------------
integrated_alert_list AS (
    SELECT user_id, product_subsc_ship_category, order_id, ship_date, digital_gift_present_date,
           order_status, payment_status, is_shipped_not_delivered, is_payment_pending,
           is_email_error, check_category, check_detail, hash_key
    FROM shipped_not_delivered_alert_list -- 01. の情報

    UNION ALL

    SELECT user_id, product_subsc_ship_category, order_id, ship_date, digital_gift_present_date,
           order_status, payment_status, is_shipped_not_delivered, is_payment_pending,
           is_email_error, check_category, check_detail, hash_key
    FROM email_error_alert_list -- 02. メール不備

    UNION ALL

    SELECT user_id, product_subsc_ship_category, order_id, ship_date, digital_gift_present_date,
           order_status, payment_status, is_shipped_not_delivered, is_payment_pending,
           is_email_error, check_category, check_detail, hash_key
    FROM payment_pending_alert_list -- 03. 未入金

    UNION ALL

    SELECT user_id, product_subsc_ship_category, order_id, ship_date, digital_gift_present_date,
           order_status, payment_status, is_shipped_not_delivered, is_payment_pending,
           is_email_error, check_category, check_detail, hash_key
    FROM past_delivery_failed_alert_list -- 04. 配信失敗 (実績)

    -----------------------------------------------------------
    -- 今後もチェックルールを追加した場合は、ここに union all で新設してください
    -----------------------------------------------------------
),

----------------------------------------------------------------------
-- 6. [Mute Flag] 記録済・対応済アラートの除外
--    Data Grain: order_id
----------------------------------------------------------------------
exclude_recorded_alerts AS (
    SELECT
        z.*,
        COALESCE(y.is_already_recorded, 0) AS is_already_recorded, -- CSVファイルで記録済みのため、除外するフラグ
        COALESCE(x.is_email_send, 0)       AS is_email_send        -- 配信成功のため、除外するフラグ

    FROM
        integrated_alert_list z -- 05. の情報

    LEFT JOIN
        map_delivery_hold_ledger y -- △ 特典_配信停止リスト.csv
    ON z.user_id = y.user_id
    AND z.order_id = y.order_id

    LEFT JOIN
        int_gift_code_pii_distribution x -- 【前工程】14_int_gift_code_pii_distribution
    ON z.user_id = x.user_id
    AND z.product_subsc_ship_category = x.product_subsc_ship_category
    AND x.is_email_send <> 1 -- メール未配信は除く
)

----------------------------------------------------------------------
-- 7. [Final Output]
--    Data Grain: order_id
----------------------------------------------------------------------
SELECT
    user_id                      AS "ユーザーID",
    product_subsc_ship_category  AS "商品/定期/出荷_分類",
    order_id                     AS "注文ID",
    ship_date                    AS "出荷日",
    digital_gift_present_date    AS "プレゼント日_デジタルギフト",
    order_status                 AS "注文ステータス",
    payment_status                AS "入金ステータス",
    is_shipped_not_delivered     AS "出荷止まりフラグ",
    is_payment_pending           AS "未入金フラグ",
    is_email_error               AS "メールエラーフラグ",

    check_category               AS "チェック内容",
    check_detail                 AS "チェック詳細",

    hash_key                     AS "ハッシュ化キー"

FROM
    exclude_recorded_alerts -- 06. の情報

WHERE
    is_already_recorded <> 1 -- CSV記録済みのデータはミュート
  AND is_email_send <> 1     -- 配信成功のデータはミュート

ORDER BY
    check_category ASC,
    user_id ASC,
    ship_date ASC
;
