/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 ギフトコード・個人情報安全結合マスタ
  Secure Gift Code & PII Distribution — Intermediate Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  特典条件を満たした顧客の確定リストに対し、実際にメール配信を行うための「個人情報
  （氏名・メールアドレス）」および「デジタルギフトコード情報」を結合し、最終的な配信
  リスト（メーリングリスト）を作成する。

  ★セキュリティを考慮した高度な結合ロジック
  デジタルギフトコードは「金券」と同等の機密情報である。もし未来の配信予定者に対して
  事前にコードを割り当ててしまうと、情報漏洩や誤配信のリスクが高まる。本クエリでは、
  LEFT JOINの結合条件で意図的に「過去・現在」の対象者にのみコードを紐付け、「未来」の
  対象者には絶対にコードが紐付かない（NULLになる）堅牢な安全設計を実装している。

  Joins confirmed gift-eligible customers with the PII (name, email) and gift code needed to
  actually send the email. As a security safeguard, the join condition deliberately links gift
  codes only to "past/current" timeline records — a JOIN condition, not a filter — ensuring
  "future" recipients can never have a code prematurely assigned (guaranteed NULL).

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
  1. extract_confirmed_target_list
     確定対象者リストの取得と配信ステータスフラグの生成
  2. extract_digital_gift_codes
     付与予定のギフトコードマスタの取得
  3. extract_customer_pii
     顧客マスタからの宛名・メールアドレスの取得
  4. join_gift_codes_and_pii
     タイムライン制限付きの安全な結合
  5. Final Output

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  user_id, product_subsc_ship_category

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  gift_seq_no

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 ギフトコード・PII配信中間テーブル
  int_gift_code_pii_distribution
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [Target List] 確定済みプレゼント対象者の取得
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
extract_confirmed_target_list AS (
    SELECT
        gift_seq_no, user_id, digital_gift_present_date, digital_gift_present_date_adjusted,
        product_subsc_ship_category, order_status, email_send_status,
        NULLIF(serial_number, '') AS serial_number, time_line,

        CASE WHEN order_status = '配達完了' THEN 1 ELSE 0 END AS is_dlv_comp,
        CASE WHEN email_send_status LIKE '%配信成功%' OR email_re_send_status LIKE '%配信成功%' THEN 1 ELSE 0 END AS is_email_send

    FROM
        int_email_delivery_status_integration -- 【前工程】13_int_email_delivery_status_integration
),

----------------------------------------------------------------------
-- 2. [Code Master] デジタルギフトコード一覧
--    Data Grain: gift_seq_no
----------------------------------------------------------------------
extract_digital_gift_codes AS (
    SELECT
        gift_seq_no,
        digital_gift_code,
        expiration_date,
        serial_number
    FROM
        map_gift_code_inventory -- デジタルギフトコード在庫一覧
),

----------------------------------------------------------------------
-- 3. [PII Master] 顧客属性マスタ (個人情報/PII)
--    Data Grain: user_id
----------------------------------------------------------------------
extract_customer_pii AS (
    SELECT
        user_id,
        customer_name,
        email,
        is_null_email
    FROM
        dim_customers_pii -- 【顧客マスタ】個人情報あり
),

----------------------------------------------------------------------
-- 4. [Secure Join] ギフトコードと個人情報の安全な結合
--    ★セキュリティ対策: ギフトコードは「過去」「現在」の対象者にのみ紐付ける。
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
join_gift_codes_and_pii AS (
    SELECT
        a.gift_seq_no, a.user_id, a.digital_gift_present_date, a.digital_gift_present_date_adjusted,
        a.product_subsc_ship_category,

        b.serial_number,
        TRIM(b.digital_gift_code) AS digital_gift_code,
        b.expiration_date,

        TRIM(c.customer_name) AS customer_name,
        c.email,

        a.is_dlv_comp, a.is_email_send,
        COALESCE(c.is_null_email, 0) AS is_null_email,

        CASE
            WHEN a.serial_number <> b.serial_number
             AND a.time_line = '過去' THEN 1
            ELSE 0
        END AS is_serial_number_mismatch

    FROM
        extract_confirmed_target_list a -- 01. 対象者リスト

    LEFT JOIN
        extract_digital_gift_codes b -- 02. ギフトコードマスタ
    ON a.gift_seq_no = b.gift_seq_no
    AND a.time_line IN ('過去', '現在') -- ★未来日の場合、重要情報の観点から紐付けない（NULLのまま）

    LEFT JOIN
        extract_customer_pii c -- 03. 顧客マスタ
    ON a.user_id = c.user_id
)

----------------------------------------------------------------------
-- 5. [Final Output] 分析・確認用データの整形と最適化
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
SELECT
    gift_seq_no                         AS "No",
    user_id                             AS "ユーザーID",
    digital_gift_present_date           AS "配信日_デジタルギフト",
    digital_gift_present_date_adjusted  AS "実際の配信日_デジタルギフト",
    product_subsc_ship_category         AS "商品/定期/出荷_分類",

    serial_number                       AS "シリアルナンバー",
    digital_gift_code                   AS "ギフトコード_デジタルギフト",
    expiration_date                     AS "有効期限_デジタルギフト券",

    customer_name                       AS "漢字氏名_対象者",
    email                                AS "メールアドレス_対象者",

    is_dlv_comp                         AS "配達完了_フラグ",
    is_email_send                       AS "メール配信成功_フラグ",
    is_null_email                       AS "メールアドレス未登録_フラグ",

    CASE
        WHEN is_null_email = 1 THEN 'メールアドレス_未登録'
        ELSE NULL
    END AS "顧客情報登録チェック",

    CASE
        WHEN is_serial_number_mismatch = 1 THEN 'シリアルナンバー_不一致'
        ELSE NULL
    END AS "シリアルナンバー不一致チェック"

FROM
    join_gift_codes_and_pii -- 04. の情報

ORDER BY
    gift_seq_no ASC
;
