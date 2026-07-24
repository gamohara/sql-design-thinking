/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 メール配信ステータス統合マスタ
  Email Delivery Status Integration — Intermediate Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  メール配信のログは、MAツールの自動行動ログと、運用担当者が管理するCSVファイルの
  2箇所に分散している。また、エラーによる「再配信」も発生する。本クエリでは、これら
  複数のデータソースを「顧客×特典予定日」で紐付け、複雑な優先順位ロジック（例：エラーに
  なっても再配信で成功していれば「成功」とする等）を用いて、最終的な配信・再配信
  ステータスを可視化する。

  ★【システムと人間の認識ズレ防止機能】
  運用担当者が手動で更新しているCSVリストのステータスと、本クエリが各種ログから
  自動判定した「真のステータス」を突き合わせる。「ステータス不一致」が検知された場合、
  手動リストの入力ミスや未確認のシステムエラーが発生している可能性が高いため、アラート
  として出力し運用にフィードバックする。

  Email logs are split across an MA tool's automatic activity log and an operator-managed
  CSV, with resend attempts adding further complexity. This query reconciles all sources by
  customer × gift date, applying a priority ladder (e.g., a resend success overrides an
  initial failure) to determine the final status, and flags mismatches between the system's
  computed status and the operator's manual record as a feedback loop for data quality.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
  1. target_present_list_base
     対象者リストの取得（近接期間に絞り込み済み）
  2. mail_activity_log
     MAツールの自動配信・行動ログの取得
  3. mail_delivery_csv / mail_resend_history_csv
     運用CSVからの配信・再配信ステータスの取得
  4. integrated_resend_status
     再配信履歴への開封有無ステータスの追加
  5. integrate_mail_status
     複数ログの競合解決と最終ステータス判定
  6. Final Output
     不一致アラートの付与と出力

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  user_id, product_subsc_ship_category

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  user_id, product_subsc_ship_category

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: CONVERT_TIMEZONE, multi-source reconciliation)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 配信ステータス統合中間テーブル
  int_email_delivery_status_integration
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [Target List] 対象者リストの基本データ取得
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
target_present_list_base AS (
    SELECT
        gift_seq_no, user_id, digital_gift_present_date, product_subsc_ship_category,
        RIGHT(product_subsc_ship_category, 12) AS subsc_ship_category,
        order_status, payment_status, serial_number,
        email_send_status_manu, -- 手動CSVのステータス
        time_line,
        digital_gift_present_date_adjusted,
        alert_status_main, alert_status_detail

    FROM
        stg_gift_target_near_term -- 【GUIパラメータ層】11の出力を「本日から10日以内」に絞り込んだ対象者リスト
),

----------------------------------------------------------------------
-- 2. [System Log] メール配信・行動履歴の取得
--    Data Grain: user_id, email_sent_date
----------------------------------------------------------------------
mail_activity_log AS (
    SELECT
        user_id,
        email_sent_date,
        MAX(is_sys_sent)     AS is_sys_sent,
        MAX(is_sys_opened)   AS is_sys_opened,
        MAX(is_sys_failed)   AS is_sys_failed,
        MAX(is_sys_rejected) AS is_sys_rejected,

        CASE
            WHEN MAX(is_sys_sent) = 1 AND MAX(is_sys_opened) = 1  THEN '配信済 → 開封済'
            WHEN MAX(is_sys_sent) = 1 AND MAX(is_sys_opened) <> 1 THEN '配信済'
            WHEN MAX(is_sys_failed) = 1                           THEN '配信失敗'
            WHEN MAX(is_sys_rejected) = 1                         THEN '配信拒否'
            ELSE NULL
        END AS sys_send_status

    FROM
        (
        SELECT
            customer_id AS user_id,
            CONVERT_TIMEZONE('UTC', 'Asia/Tokyo', delivery_time)::DATE AS email_sent_date,

            CASE WHEN act_type IN ('mail_tried', 'mail_opened', 'mail_clicked', 'mail_redirect_clicked') THEN 1 ELSE 0 END AS is_sys_sent,
            CASE WHEN act_type IN ('mail_opened', 'mail_clicked', 'mail_redirect_clicked') THEN 1 ELSE 0 END AS is_sys_opened,
            CASE WHEN act_type = 'mail_failed' THEN 1 ELSE 0 END AS is_sys_failed,
            CASE WHEN act_type = 'mail_unsubscribed' THEN 1 ELSE 0 END AS is_sys_rejected

        FROM
            raw_mail_activity_log -- メール行動ログデータ (MAツール)
        WHERE
            LOWER(REGEXP_SUBSTR(scenario_name, 'gift_campaign', 1, 1, 'i')) = 'gift_campaign'
        )

    GROUP BY
        user_id, email_sent_date
),

----------------------------------------------------------------------
-- 3. [Manual CSV] メール配信リスト管理データの取得
--    Data Grain: user_id, email_sent_date
----------------------------------------------------------------------
mail_delivery_csv AS (
    SELECT
        user_id,
        email_sent_date,
        MAX(is_csv_sent)     AS is_csv_sent,
        MAX(is_csv_failed)   AS is_csv_failed,
        MAX(is_csv_not_sent) AS is_csv_not_sent,

        CASE
            WHEN MAX(is_csv_sent) = 1     THEN '配信済'
            WHEN MAX(is_csv_failed) = 1   THEN '配信失敗'
            WHEN MAX(is_csv_not_sent) = 1 THEN '配信エラー'
            ELSE NULL
        END AS csv_send_status

    FROM
        (
        SELECT
            user_id,
            email_sent_date,
            CASE WHEN delivery_status = '配信済み' THEN 1 ELSE 0 END AS is_csv_sent,
            CASE WHEN delivery_status = '配信失敗' THEN 1 ELSE 0 END AS is_csv_failed,
            CASE WHEN delivery_status = '未配信'   THEN 1 ELSE 0 END AS is_csv_not_sent
        FROM
            map_email_delivery_log -- メール配信ログ
        )

    GROUP BY
        user_id, email_sent_date
),

----------------------------------------------------------------------
-- 4. [Resend CSV] メール再配信リストの取得
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
mail_resend_history_csv AS (
    SELECT
        user_id,
        product_subsc_ship_category,
        MAX(resend_date)     AS resend_date,
        RIGHT(MAX(resend_date)::VARCHAR, 8) || ': ' AS resend_date_char,
        MAX(resend_type)      AS resend_type,
        MAX(is_resend_success) AS is_resend_success,
        MAX(is_resend_failed)  AS is_resend_failed

    FROM
        (
        SELECT
            user_id,
            product_subsc_ship_category,
            resend_date,
            resend_type,
            CASE WHEN resend_status = '済'   THEN 1 ELSE 0 END AS is_resend_success,
            CASE WHEN resend_status = '不達' THEN 1 ELSE 0 END AS is_resend_failed
        FROM
            map_email_resend_log -- メール再配信ログ
        )

    GROUP BY
        user_id, product_subsc_ship_category
),

----------------------------------------------------------------------
-- 5. [Resend Status] 開封有無のステータス追加
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
integrated_resend_status AS (
    SELECT
        e.user_id, e.product_subsc_ship_category, e.resend_date, e.resend_date_char,
        e.resend_type, e.is_resend_success, e.is_resend_failed,

        CASE
            WHEN e.is_resend_success = 1 AND COALESCE(f.is_sys_opened, 0) = 1  THEN '済 → 開封済'
            WHEN e.is_resend_success = 1 AND COALESCE(f.is_sys_opened, 0) <> 1 THEN '済'
            WHEN e.is_resend_failed = 1  THEN '不達'
            ELSE NULL
        END AS resend_status_text

    FROM
        mail_resend_history_csv e -- 04. の情報

    LEFT JOIN
        mail_activity_log f -- 02. の情報
    ON e.user_id = f.user_id
    AND e.resend_date = f.email_sent_date
),

----------------------------------------------------------------------
-- 6. [Status Integration] 複数ログの競合解決と最終ステータス判定
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
integrate_mail_status AS (
    SELECT
        a.gift_seq_no, a.user_id, a.digital_gift_present_date, a.product_subsc_ship_category,
        a.subsc_ship_category, a.order_status, a.payment_status, a.serial_number,
        a.email_send_status_manu, a.time_line, a.digital_gift_present_date_adjusted,
        a.alert_status_main, a.alert_status_detail,

        CASE
            WHEN NULLIF(sys.sys_send_status, '') IS NOT NULL AND NULLIF(csv.csv_send_status, '') IS NULL     THEN sys.sys_send_status
            WHEN NULLIF(sys.sys_send_status, '') IS NULL     AND NULLIF(csv.csv_send_status, '') IS NOT NULL THEN csv.csv_send_status

            WHEN NULLIF(sys.sys_send_status, '') IS NOT NULL AND NULLIF(csv.csv_send_status, '') IS NOT NULL
             AND COALESCE(csv.is_csv_sent, 0) = 1 AND COALESCE(sys.is_sys_sent, 0) = 1  THEN sys.sys_send_status

            WHEN NULLIF(sys.sys_send_status, '') IS NOT NULL AND NULLIF(csv.csv_send_status, '') IS NOT NULL
             AND COALESCE(csv.is_csv_sent, 0) = 1 AND COALESCE(sys.is_sys_sent, 0) <> 1 THEN csv.csv_send_status

            WHEN NULLIF(sys.sys_send_status, '') IS NOT NULL AND NULLIF(csv.csv_send_status, '') IS NOT NULL
             AND COALESCE(csv.is_csv_not_sent, 0) = 1 THEN csv.csv_send_status

            WHEN NULLIF(sys.sys_send_status, '') IS NOT NULL AND NULLIF(csv.csv_send_status, '') IS NOT NULL
             AND (COALESCE(sys.is_sys_sent, 0) = 1 OR COALESCE(sys.is_sys_opened, 0) = 1)
             AND COALESCE(csv.is_csv_failed, 0) = 1 THEN csv.csv_send_status

            WHEN NULLIF(sys.sys_send_status, '') IS NOT NULL AND NULLIF(csv.csv_send_status, '') IS NOT NULL
             AND (COALESCE(sys.is_sys_failed, 0) = 1 OR COALESCE(sys.is_sys_rejected, 0) = 1)
             AND COALESCE(csv.is_csv_failed, 0) = 1 THEN sys.sys_send_status

            WHEN NULLIF(sys.sys_send_status, '') IS NULL AND NULLIF(csv.csv_send_status, '') IS NULL
             AND NULLIF(a.email_send_status_manu, '') IS NOT NULL AND a.time_line = '過去' THEN '不達'
            WHEN NULLIF(sys.sys_send_status, '') IS NULL AND NULLIF(csv.csv_send_status, '') IS NULL
             AND NULLIF(a.email_send_status_manu, '') IS NULL AND a.time_line = '過去'     THEN '未配信'
            WHEN NULLIF(sys.sys_send_status, '') IS NULL AND NULLIF(csv.csv_send_status, '') IS NULL
             AND a.time_line IN ('現在', '未来')                                            THEN '未配信'

            ELSE NULL
        END AS email_send_status,

        COALESCE(re.resend_date_char, '') ||
            COALESCE(re.resend_type, '') ||
                COALESCE(re.resend_status_text, '') AS email_re_send_status

    FROM
        target_present_list_base a -- 01. 対象者リスト

    LEFT JOIN
        mail_activity_log sys -- 02. システムログ
    ON a.user_id = sys.user_id
    AND a.digital_gift_present_date_adjusted = sys.email_sent_date

    LEFT JOIN
        mail_delivery_csv csv -- 03. 運用CSV
    ON a.user_id = csv.user_id
    AND a.digital_gift_present_date_adjusted = csv.email_sent_date

    LEFT JOIN
        integrated_resend_status re -- 05. 統合済みの再配信履歴
    ON a.user_id = re.user_id
    AND a.product_subsc_ship_category = re.product_subsc_ship_category
)

----------------------------------------------------------------------
-- 7. [Final Output] 分析・オペレーション確認用データの整形
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
SELECT
    gift_seq_no                         AS "No",
    user_id                             AS "ユーザーID",
    digital_gift_present_date           AS "プレゼント日_デジタルギフト",
    product_subsc_ship_category         AS "商品/定期/出荷_分類",

    CASE
        WHEN NULLIF(order_status, '') IS NULL THEN alert_status_main
        WHEN order_status = 'SHP_COMP'        THEN '出荷完了'
        WHEN order_status = 'DLV_COMP'        THEN '配達完了'
        ELSE NULLIF(order_status, '')
    END AS "注文ステータス",

    payment_status                      AS "入金ステータス",
    email_send_status                   AS "メール配信ステータス",
    NULLIF(email_re_send_status, '')    AS "メール再配信ステータス",
    digital_gift_present_date_adjusted  AS "実際のプレゼント日_デジタルギフト",
    serial_number                       AS "シリアルナンバー",

    time_line                           AS "タイムライン",

    CASE
        WHEN time_line = '過去'
         AND (
                CASE
                    WHEN email_send_status LIKE '%配信済%'
                      OR email_re_send_status LIKE '%済%'              THEN '済'
                    WHEN email_send_status IN ('配信失敗', '配信エラー') THEN '不達'
                    WHEN email_send_status = '未配信'                   THEN NULL
                    ELSE email_send_status
                END
             ) <> NULLIF(email_send_status_manu, '')
         THEN '配信ステータス_不一致'
        ELSE NULL
    END AS "配信ステータスチェック"

FROM
    integrate_mail_status -- 06. の情報

ORDER BY
    gift_seq_no ASC
;
