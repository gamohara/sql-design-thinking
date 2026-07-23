/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 顧客別ステータス横持ち表
  Customer-Level Gift Status Pivot — Marts Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  特典対象者の「配信ステータス（1回目、2回目、追加分）」を、1人の顧客（1コース）につき
  1行で横並びに見れるように変換（ピボット）する。運用・CSの現場で「このお客様は、いつ、
  どの特典をもらっていて、次はいつ貰える予定なのか」というジャーニー全体像を一目で把握
  できるようにする。正常配信された顧客だけでなく、メール不備等で「配信エラー（保留）」
  となった顧客のステータスも横並びで確認できる。

  Pivots each customer's gift delivery history (1st, 2nd, bonus) from a vertically-stacked
  layout into one row per customer/course, giving support staff an at-a-glance view of what
  the customer has received and what's still pending — including customers held in error.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
  1. pivot_present_status_by_timing
     タイミング別のステータス横持ち化（疑似PIVOT）
  2. extract_f1_course_info
     F1対象者とコース区分の取得
  3. agg_pivoted_status
     横展開結果の1行化
  4. combine_status_and_f1_course
     ステータスとF1属性の統合
  5. Final Output
     ダッシュボード用表示の整形

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  user_id, product_subsc_category

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  user_id, product_subsc_category

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: window function pivot pattern, LISTAGG)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 顧客別ステータス横持ちマートテーブル
  mart_customer_gift_status_pivot
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [Pivot] タイミング別のステータス横持ち化
--    Data Grain: user_id, product_category (ウィンドウ関数展開のため行数は元のまま)
----------------------------------------------------------------------
pivot_present_status_by_timing AS (
    SELECT
        user_id,
        LEFT(product_subsc_ship_category, 7) AS product_category,
        present_timing_char,
        digital_gift_present_date,

        TO_CHAR(digital_gift_present_date, 'YY-MM-DD') || ': ' || remarks AS remarks_with_date,

        MAX(CASE WHEN present_timing_char = '1回目' THEN digital_gift_present_date ELSE NULL END) OVER(PARTITION BY user_id) AS gift_present_date_1st,
        MAX(CASE WHEN present_timing_char = '1回目' THEN order_status ELSE NULL END) OVER(PARTITION BY user_id) AS order_status_1st,
        MAX(CASE WHEN present_timing_char = '1回目' THEN payment_status ELSE NULL END) OVER(PARTITION BY user_id) AS payment_status_1st,
        MAX(CASE WHEN present_timing_char = '1回目' THEN email_send_status ELSE NULL END) OVER(PARTITION BY user_id) AS email_send_status_1st,
        MAX(CASE WHEN present_timing_char = '1回目' THEN email_re_send_status ELSE NULL END) OVER(PARTITION BY user_id) AS email_re_send_status_1st,
        MAX(CASE WHEN present_timing_char = '1回目' THEN serial_number ELSE NULL END) OVER(PARTITION BY user_id) AS serial_number_1st,
        MAX(CASE WHEN present_timing_char = '1回目' THEN is_error_mail ELSE NULL END) OVER(PARTITION BY user_id) AS is_error_mail_1st,
        MAX(CASE WHEN present_timing_char = '1回目' THEN is_null_email ELSE NULL END) OVER(PARTITION BY user_id) AS is_null_email_1st,

        MAX(CASE WHEN present_timing_char = '2回目' THEN digital_gift_present_date ELSE NULL END) OVER(PARTITION BY user_id) AS gift_present_date_2nd,
        MAX(CASE WHEN present_timing_char = '2回目' THEN order_status ELSE NULL END) OVER(PARTITION BY user_id) AS order_status_2nd,
        MAX(CASE WHEN present_timing_char = '2回目' THEN payment_status ELSE NULL END) OVER(PARTITION BY user_id) AS payment_status_2nd,
        MAX(CASE WHEN present_timing_char = '2回目' THEN email_send_status ELSE NULL END) OVER(PARTITION BY user_id) AS email_send_status_2nd,
        MAX(CASE WHEN present_timing_char = '2回目' THEN email_re_send_status ELSE NULL END) OVER(PARTITION BY user_id) AS email_re_send_status_2nd,
        MAX(CASE WHEN present_timing_char = '2回目' THEN serial_number ELSE NULL END) OVER(PARTITION BY user_id) AS serial_number_2nd,
        MAX(CASE WHEN present_timing_char = '2回目' THEN is_error_mail ELSE NULL END) OVER(PARTITION BY user_id) AS is_error_mail_2nd,
        MAX(CASE WHEN present_timing_char = '2回目' THEN is_null_email ELSE NULL END) OVER(PARTITION BY user_id) AS is_null_email_2nd,

        MAX(CASE WHEN present_timing_char = '追加' THEN digital_gift_present_date ELSE NULL END) OVER(PARTITION BY user_id) AS gift_present_date_plus,
        MAX(CASE WHEN present_timing_char = '追加' THEN order_status ELSE NULL END) OVER(PARTITION BY user_id) AS order_status_plus,
        MAX(CASE WHEN present_timing_char = '追加' THEN payment_status ELSE NULL END) OVER(PARTITION BY user_id) AS payment_status_plus,
        MAX(CASE WHEN present_timing_char = '追加' THEN email_send_status ELSE NULL END) OVER(PARTITION BY user_id) AS email_send_status_plus,
        MAX(CASE WHEN present_timing_char = '追加' THEN email_re_send_status ELSE NULL END) OVER(PARTITION BY user_id) AS email_re_send_status_plus,
        MAX(CASE WHEN present_timing_char = '追加' THEN serial_number ELSE NULL END) OVER(PARTITION BY user_id) AS serial_number_plus,
        MAX(CASE WHEN present_timing_char = '追加' THEN is_error_mail ELSE NULL END) OVER(PARTITION BY user_id) AS is_error_mail_plus,
        MAX(CASE WHEN present_timing_char = '追加' THEN is_null_email ELSE NULL END) OVER(PARTITION BY user_id) AS is_null_email_plus

    FROM
        mart_delivery_status_summary -- 【前工程】15_mart_delivery_status_summary
),

----------------------------------------------------------------------
-- 2. [F1 Course Info] F1対象者とコースの取得
--    Data Grain: user_id
----------------------------------------------------------------------
extract_f1_course_info AS (
    SELECT
        a.user_id,
        a.ordered_date AS ordered_date_f1,
        a.ship_date    AS ship_date_f1,
        a.product_category AS product_category_f1,

        CASE
            WHEN a.is_course_3bottle_first = 1     THEN '定期_初回3本'
            WHEN a.is_course_upgraded_1_to_2 = 1   THEN '定期_初回1本→2本'
            WHEN a.is_course_upgraded_1_to_3 = 1   THEN '定期_初回1本→3本'
            ELSE NULL
        END AS subsc_category

    FROM
        stg_gift_eligible_order_confirmed a -- 【前工程】02_stg_gift_eligible_order_confirmed

    INNER JOIN
        (
            SELECT user_id, MIN(order_id) AS min_order_id
            FROM stg_gift_eligible_order_confirmed
            GROUP BY user_id
        ) b
    ON a.order_id = b.min_order_id
),

----------------------------------------------------------------------
-- 3. [Aggregation] ピボット結果の1行化
--    Data Grain: user_id, product_category
----------------------------------------------------------------------
agg_pivoted_status AS (
    SELECT
        user_id,
        product_category,
        MAX(gift_present_date_1st) AS gift_present_date_1st,
        MAX(order_status_1st)      AS order_status_1st,
        MAX(payment_status_1st)    AS payment_status_1st,
        MAX(email_send_status_1st) AS email_send_status_1st,
        MAX(email_re_send_status_1st) AS email_re_send_status_1st,
        MAX(serial_number_1st)     AS serial_number_1st,
        MAX(is_error_mail_1st)     AS is_error_mail_1st,
        MAX(is_null_email_1st)     AS is_null_email_1st,
        MAX(gift_present_date_2nd) AS gift_present_date_2nd,
        MAX(order_status_2nd)      AS order_status_2nd,
        MAX(payment_status_2nd)    AS payment_status_2nd,
        MAX(email_send_status_2nd) AS email_send_status_2nd,
        MAX(email_re_send_status_2nd) AS email_re_send_status_2nd,
        MAX(serial_number_2nd)     AS serial_number_2nd,
        MAX(is_error_mail_2nd)     AS is_error_mail_2nd,
        MAX(is_null_email_2nd)     AS is_null_email_2nd,
        MAX(gift_present_date_plus) AS gift_present_date_plus,
        MAX(order_status_plus)      AS order_status_plus,
        MAX(payment_status_plus)    AS payment_status_plus,
        MAX(email_send_status_plus) AS email_send_status_plus,
        MAX(email_re_send_status_plus) AS email_re_send_status_plus,
        MAX(serial_number_plus)     AS serial_number_plus,
        MAX(is_error_mail_plus)     AS is_error_mail_plus,
        MAX(is_null_email_plus)     AS is_null_email_plus,

        -- 複数回のエラー履歴がある場合、予定日順にスラッシュ区切りでテキスト結合する
        LISTAGG(remarks_with_date, '/ ') WITHIN GROUP (ORDER BY digital_gift_present_date) AS remarks

    FROM
        pivot_present_status_by_timing -- 01. 横展開済みの情報

    GROUP BY
        user_id, product_category
),

----------------------------------------------------------------------
-- 4. [Combine] ステータスとF1属性の統合
--    Data Grain: user_id, product_subsc_category
----------------------------------------------------------------------
combine_status_and_f1_course AS (
    SELECT
        d.user_id,

        CASE WHEN NULLIF(c.product_category, '') IS NULL THEN d.product_category_f1
            ELSE COALESCE(c.product_category, '') END
         || d.subsc_category AS product_subsc_category,

        d.ordered_date_f1,
        TO_NUMBER(TO_CHAR(d.ordered_date_f1, 'YYYYMM')) AS ordered_year_month_f1,
        d.ship_date_f1,
        TO_NUMBER(TO_CHAR(d.ship_date_f1, 'YYYYMM'))    AS ship_year_month_f1,

        c.gift_present_date_1st, c.order_status_1st, c.payment_status_1st,
        c.email_send_status_1st, c.email_re_send_status_1st, c.serial_number_1st,
        c.gift_present_date_2nd, c.order_status_2nd, c.payment_status_2nd,
        c.email_send_status_2nd, c.email_re_send_status_2nd, c.serial_number_2nd,
        c.gift_present_date_plus, c.order_status_plus, c.payment_status_plus,
        c.email_send_status_plus, c.email_re_send_status_plus, c.serial_number_plus,

        NULLIF(c.remarks, '') AS remarks,

        COALESCE(c.is_error_mail_1st, 0)  AS is_error_mail_1st,
        COALESCE(c.is_null_email_1st, 0)  AS is_null_email_1st,
        COALESCE(c.is_error_mail_2nd, 0)  AS is_error_mail_2nd,
        COALESCE(c.is_null_email_2nd, 0)  AS is_null_email_2nd,
        COALESCE(c.is_error_mail_plus, 0) AS is_error_mail_plus,
        COALESCE(c.is_null_email_plus, 0) AS is_null_email_plus,
        COALESCE(e.is_null_email, 1)      AS is_null_email -- 顧客マスタにデータがない場合、メールアドレスは未登録とする

    FROM
        extract_f1_course_info d -- 02. F1コース情報

    LEFT JOIN
        agg_pivoted_status c -- 03. 集約済みのステータス
    ON c.user_id = d.user_id

    LEFT JOIN
        dim_customers_pii e -- 【顧客マスタ】個人情報あり
    ON d.user_id = e.user_id
)

----------------------------------------------------------------------
-- 5. [Final Output] ダッシュボード用表示の整形
--    Data Grain: user_id, product_subsc_category
----------------------------------------------------------------------
SELECT
    user_id                   AS "ユーザーID",
    product_subsc_category    AS "商品/定期_分類",
    ordered_date_f1           AS "【初回】受注日",
    ordered_year_month_f1     AS "【初回】受注年月",
    ship_date_f1              AS "【初回】出荷日",
    ship_year_month_f1        AS "【初回】出荷年月",

    gift_present_date_1st     AS "【特典_1回目】配信日",
    order_status_1st          AS "【特典_1回目】注文ステータス",
    payment_status_1st        AS "【特典_1回目】入金ステータス",
    email_send_status_1st     AS "【特典_1回目】配信ステータス",
    email_re_send_status_1st  AS "【特典_1回目】再配信ステータス",
    serial_number_1st         AS "【特典_1回目】シリアルナンバー",

    gift_present_date_2nd     AS "【特典_2回目】配信日",
    order_status_2nd          AS "【特典_2回目】注文ステータス",
    payment_status_2nd        AS "【特典_2回目】入金ステータス",
    email_send_status_2nd     AS "【特典_2回目】配信ステータス",
    email_re_send_status_2nd  AS "【特典_2回目】再配信ステータス",
    serial_number_2nd         AS "【特典_2回目】シリアルナンバー",

    gift_present_date_plus    AS "【特典_追加】配信日",
    order_status_plus         AS "【特典_追加】注文ステータス",
    payment_status_plus       AS "【特典_追加】入金ステータス",
    email_send_status_plus    AS "【特典_追加】配信ステータス",
    email_re_send_status_plus AS "【特典_追加】再配信ステータス",
    serial_number_plus        AS "【特典_追加】シリアルナンバー",

    remarks                   AS "備考",

    is_error_mail_1st         AS "【特典_1回目】メール配信エラーフラグ",
    is_null_email_1st         AS "【特典_1回目】メール未登録フラグ",
    is_error_mail_2nd         AS "【特典_2回目】メール配信エラーフラグ",
    is_null_email_2nd         AS "【特典_2回目】メール未登録フラグ",
    is_error_mail_plus        AS "【特典_追加】メール配信エラーフラグ",
    is_null_email_plus        AS "【特典_追加】メール未登録フラグ",
    is_null_email              AS "メール未登録フラグ_現在"

FROM
    combine_status_and_f1_course -- 04. の情報

ORDER BY
    ship_date_f1 ASC, user_id ASC
;
