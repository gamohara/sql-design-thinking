/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 配信ステータス統合表（正常＋エラー）
  Consolidated Delivery Status Report (Success + Error) — Marts Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  特典配布対象者の「正常配信ステータス（配信済・不達等）」と、配信前に除外された「エラー
  保留ステータス」を統合し、外部システムや管理台帳にそのまま貼り付けて顧客情報を一括更新
  するための「最終ステータス更新リスト」を作成する。

  ★配信エラー判定の思想（「最終的に届いたか」基準）
  本クエリのエラーフラグは、途中経過ではなく「最終的に顧客へギフトが届いたか」という
  事実（＝費用発生の有無）を基準に判定する。
    ・メール不備による事前除外者（gift_seq_no = 999999999）は、無条件でエラーと判定する。
    ・「未配信」は未来の配信予定を意味するため、エラーには含めない（未確定とエラーの分離）。
    ・初回配信が不達等であっても「再配信」で救済され届いた場合は、エラー扱いしない。
  このフラグは運用上のエラー監視に加え、費用予測システムにおける「メアド未登録率・配信
  エラー率」算出の分子としても使用される。

  Consolidates the normal delivery-success path with pre-excluded email-error targets into a
  single "closing" report for CRM/ledger feedback. The error flag is defined by whether the
  gift *ultimately* reached the customer (cost-incurring event), not by intermediate status —
  pre-excluded targets are unconditionally errors, "not yet sent" future targets are not
  errors, and a successful resend clears an initial failure.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
  1. excluded_email_error_targets
     メール不備により事前除外された対象者の抽出（フォーマット統一）
  2. confirmed_delivery_targets
     正常に処理が進んだ対象者の配信ステータス取得
  3. combined_status_updates
     縦結合による統合
  4. Final Output
     動的な特典タイミング採番とエラーフラグの付与

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  user_id, product_subsc_ship_category

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  gift_seq_no

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: window functions)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 配信ステータス統合マートテーブル
  mart_delivery_status_summary
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [Error Targets] メール情報不備により配信対象から除外した対象者を追加
--    Data Grain: order_id
----------------------------------------------------------------------
excluded_email_error_targets AS (
    SELECT
        999999999                    AS gift_seq_no, -- エラー者をリスト下部にまとめるためのダミーNo
        a.user_id,
        a.digital_gift_present_date,
        CAST(NULL AS DATE)           AS actual_present_date,
        a.product_subsc_ship_category,

        CASE
            WHEN RIGHT(a.product_subsc_ship_category, 12) IN ('2本定期 : 3回目出荷', '3本定期 : 2回目出荷') THEN '1回目'
            WHEN RIGHT(a.product_subsc_ship_category, 12) IN ('2本定期 : 4回目出荷', '3本定期 : 3回目出荷') THEN '2回目'
            WHEN RIGHT(a.product_subsc_ship_category, 12) = '2本定期 : 2回目出荷'                          THEN '追加'
            ELSE NULL
        END AS present_timing_char,

        CASE
            WHEN a.order_status = 'SHP_COMP' THEN '出荷完了'
            WHEN a.order_status = 'DLV_COMP' THEN '配達完了'
            ELSE NULLIF(a.order_status, '')
        END AS order_status,

        CASE WHEN a.is_payment_received = 1 THEN '入金済' ELSE '未入金' END AS payment_status,

        '配信エラー' AS email_send_status,
        NULL         AS email_re_send_status,
        NULL         AS serial_number,
        a.email_issue_remarks AS remarks

    FROM
        int_predelivery_alert_check a -- 【前工程】10_int_predelivery_alert_check
        -- (email_issue_remarks は前工程の「顧客情報登録チェック」相当のメール不備テキスト)

    -- 重複排除: 確定リストにすでに存在している顧客はエラーリストから除外する
    LEFT JOIN
        (
            SELECT user_id, product_subsc_ship_category, 1 AS is_exist
            FROM int_email_delivery_status_integration -- 【前工程】13_int_email_delivery_status_integration
            GROUP BY user_id, product_subsc_ship_category
        ) b
    ON a.user_id = b.user_id
    AND a.product_subsc_ship_category = b.product_subsc_ship_category

    WHERE
        a.email_issue_remarks IS NOT NULL
      -- 未来の対象者は顧客が登録情報を変更する可能性があるため、確定する「過去・現在」のみを記録する
      AND a.time_line IN ('過去', '現在')
      AND COALESCE(b.is_exist, 0) <> 1
),

----------------------------------------------------------------------
-- 2. [Confirmed Targets] 確定済みプレゼント対象者の取得
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
confirmed_delivery_targets AS (
    SELECT
        gift_seq_no,
        user_id,
        digital_gift_present_date,
        digital_gift_present_date_adjusted AS actual_present_date,
        product_subsc_ship_category,

        CASE
            WHEN RIGHT(product_subsc_ship_category, 12) IN ('2本定期 : 3回目出荷', '3本定期 : 2回目出荷') THEN '1回目'
            WHEN RIGHT(product_subsc_ship_category, 12) IN ('2本定期 : 4回目出荷', '3本定期 : 3回目出荷') THEN '2回目'
            WHEN RIGHT(product_subsc_ship_category, 12) = '2本定期 : 2回目出荷'                          THEN '追加'
            ELSE NULL
        END AS present_timing_char,

        order_status,
        payment_status,
        email_send_status,
        email_re_send_status,
        NULLIF(serial_number, '') AS serial_number,
        NULL AS remarks

    FROM
        int_email_delivery_status_integration -- 【前工程】13_int_email_delivery_status_integration
),

----------------------------------------------------------------------
-- 3. [Union] テーブルの統合
--    Data Grain: order_id
----------------------------------------------------------------------
combined_status_updates AS (
    SELECT gift_seq_no, user_id, digital_gift_present_date, actual_present_date,
           product_subsc_ship_category, present_timing_char, order_status, payment_status,
           email_send_status, email_re_send_status, serial_number, remarks
    FROM excluded_email_error_targets -- 01. エラー情報

    UNION ALL

    SELECT gift_seq_no, user_id, digital_gift_present_date, actual_present_date,
           product_subsc_ship_category, present_timing_char, order_status, payment_status,
           email_send_status, email_re_send_status, serial_number, remarks
    FROM confirmed_delivery_targets -- 02. 正常情報
)

----------------------------------------------------------------------
-- 4. [Final Output] 分析・オペレーション確認用データの整形
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
SELECT
    gift_seq_no                  AS "No",
    user_id                      AS "ユーザーID",
    product_subsc_ship_category  AS "商品/定期/出荷_分類",

    ROW_NUMBER() OVER(
        PARTITION BY user_id
        ORDER BY (CASE WHEN actual_present_date IS NOT NULL THEN actual_present_date ELSE digital_gift_present_date END) ASC
    ) AS "プレゼント_タイミング",

    present_timing_char          AS "プレゼント_タイミング_文字準拠",
    digital_gift_present_date    AS "プレゼント日_デジタルギフト",

    CASE
        WHEN email_send_status = '未配信' THEN NULL
        ELSE actual_present_date
    END AS "実際のプレゼント日_デジタルギフト",

    order_status                 AS "注文ステータス",
    payment_status               AS "入金ステータス",
    email_send_status            AS "メール配信ステータス",
    email_re_send_status         AS "メール再配信ステータス",
    serial_number                AS "シリアルナンバー",
    remarks                      AS "備考",

    -- メール不備による事前除外者、もしくは初回も再配信も成功しておらず「未配信」でもない顧客をエラーとして検知
    CASE
        WHEN gift_seq_no = 999999999 THEN 1
        WHEN COALESCE(email_send_status, '') NOT LIKE '%配信成功%'
         AND COALESCE(email_send_status, '') <> '未配信'
         AND COALESCE(email_re_send_status, '') NOT LIKE '%再配信成功%' THEN 1
        ELSE 0
    END AS "メール配信エラーフラグ",

    CASE
        WHEN gift_seq_no = 999999999
         AND remarks LIKE '%未登録%' THEN 1
        ELSE 0
    END AS "メール未登録フラグ"

FROM
    combined_status_updates -- 03. の統合情報

ORDER BY
    gift_seq_no ASC, digital_gift_present_date ASC, user_id ASC
;
