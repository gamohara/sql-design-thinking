/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 コホート別到達率分析マートテーブル
  Cohort-Based Conversion Rate Analysis — Marts Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  特典施策の全体像を把握し、未来の予測を立てるためには「2つの時間軸」が必要である。
    1. コホート分析（マーケティング・CRM視点）：
       「〇年〇月に受注した顧客の、1回目・2回目の特典到達率は何％か」
       「受注から配信までに平均して何日かかっているか」を追跡し、施策の歩留まりを評価する。
    2. カレンダー発生分析（経理・在庫管理視点）：
       「今月には全体で何件のギフトが配信されたのか」という、獲得時期を問わない
       実際の発生件数（コスト）を把握する。
  本クエリでは、この異なる2つの時間軸を「年月（YYYYMM）」という共通キーで1つの
  マトリクスに統合する。

  ★【コホート軸は「初回受注月」】
  費用予測システムがF1獲得件数を「受注日」ベースで予測するため、本クエリのコホート軸も
  初回出荷月ではなく「初回受注月」とし、予測側の起算点と完全に一致させている。

  ★【コース別のドリルダウン】
  お届け周期と特典タイミングがコースごとに異なるため、「初回3本」「初回1本→2本」
  「初回1本→3本」の3コース別に到達率やメール未登録率を細分化して算出している。

  Two time axes are needed to fully understand the campaign: cohort analysis (by order month,
  for marketing/CRM yield tracking) and calendar analysis (by delivery month, for cost/
  inventory purposes independent of when customers were acquired). This query unifies both
  axes on a common YYYYMM key, using the order month (not ship month) as the cohort axis to
  match the cost-forecasting system's own basis, and drills down by course type since
  delivery cadence and timing differ materially across courses.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
  1. prepared_cohort_base
     各タイミングの配信有無・エラー有無・所要日数の計算
  2. agg_by_cohort_month
     受注月×コース軸でのコホート集計
  3. integrated_cohort_and_monthly_actuals
     カレンダー月別実績の横付けと各種率の計算
  4. Final Output

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  ordered_year_month_f1, subsc_category

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  ordered_year_month_f1, subsc_category

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 コホート到達率分析マートテーブル
  mart_cohort_conversion_analysis
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [Base] 各特典回の実績・エラー判定と所要日数計算
--    Data Grain: user_id, subsc_category
----------------------------------------------------------------------
prepared_cohort_base AS (
    SELECT
        user_id,
        subsc_category,
        ordered_date_f1,
        ordered_year_month_f1,

        is_gift_present_1st,
        TO_NUMBER(TO_CHAR(gift_present_date_1st, 'YYYYMM')) AS gift_present_month_1st,
        DATEDIFF(day, ordered_date_f1, gift_present_date_1st) AS days_from_order_to_present_1st,

        CASE WHEN is_error_mail_1st = 1 THEN 1 ELSE 0 END AS is_error_mail_present_1st,
        CASE WHEN is_null_email_1st = 1 THEN 1 ELSE 0 END AS is_null_email_present_1st,

        is_gift_present_2nd,
        TO_NUMBER(TO_CHAR(gift_present_date_2nd, 'YYYYMM')) AS gift_present_month_2nd,
        DATEDIFF(day, ordered_date_f1, gift_present_date_2nd) AS days_from_order_to_present_2nd,

        CASE WHEN is_error_mail_2nd = 1 THEN 1 ELSE 0 END AS is_error_mail_present_2nd,
        CASE WHEN is_null_email_2nd = 1 THEN 1 ELSE 0 END AS is_null_email_present_2nd,

        is_null_email

    FROM
        (
            SELECT
                *,
                CASE WHEN product_subsc_category LIKE '%定期_初回3本%'      THEN '定期_初回3本'
                     WHEN product_subsc_category LIKE '%定期_初回1本→2本%' THEN '定期_初回1本→2本'
                     WHEN product_subsc_category LIKE '%定期_初回1本→3本%' THEN '定期_初回1本→3本'
                     ELSE NULL
                END AS subsc_category,
                CASE WHEN gift_present_date_1st IS NOT NULL THEN 1 ELSE 0 END AS is_gift_present_1st,
                CASE WHEN gift_present_date_2nd IS NOT NULL THEN 1 ELSE 0 END AS is_gift_present_2nd
            FROM
                mart_customer_gift_status_pivot -- 【前工程】16_mart_customer_gift_status_pivot
        )
),

----------------------------------------------------------------------
-- 2. [Cohort Aggregation] 受注月・コースベースの歩留まり・エラー集計
--    Data Grain: ordered_year_month_f1, subsc_category
----------------------------------------------------------------------
agg_by_cohort_month AS (
    SELECT
        ordered_year_month_f1,
        subsc_category,
        COUNT(user_id)                                AS count_target_customer,
        SUM(is_gift_present_1st)                      AS sum_gift_present_1st_orderbase,
        SUM(is_error_mail_present_1st)                AS sum_error_mail_present_1st,
        SUM(is_null_email_present_1st)                AS sum_null_email_present_1st,
        AVG(days_from_order_to_present_1st)            AS avg_days_from_order_to_present_1st,
        SUM(is_gift_present_2nd)                       AS sum_gift_present_2nd_orderbase,
        SUM(is_error_mail_present_2nd)                 AS sum_error_mail_present_2nd,
        SUM(is_null_email_present_2nd)                 AS sum_null_email_present_2nd,
        AVG(days_from_order_to_present_2nd)             AS avg_days_from_order_to_present_2nd,
        SUM(is_null_email)                              AS sum_null_email

    FROM
        prepared_cohort_base -- 01. の情報

    GROUP BY
        ordered_year_month_f1, subsc_category
),

----------------------------------------------------------------------
-- 3. [Integration] カレンダー発生件数の結合とパーセンテージ計算
--    Data Grain: ordered_year_month_f1 (= カレンダー月), subsc_category
----------------------------------------------------------------------
integrated_cohort_and_monthly_actuals AS (
    SELECT
        a.ordered_year_month_f1,
        a.subsc_category,
        a.count_target_customer,
        a.sum_gift_present_1st_orderbase,
        a.sum_error_mail_present_1st,
        a.sum_null_email_present_1st,
        a.avg_days_from_order_to_present_1st,
        a.sum_gift_present_2nd_orderbase,
        a.sum_error_mail_present_2nd,
        a.sum_null_email_present_2nd,
        a.avg_days_from_order_to_present_2nd,
        a.sum_null_email,
        COALESCE(b.sum_gift_present_1st, 0) AS sum_gift_present_1st,
        COALESCE(c.sum_gift_present_2nd, 0) AS sum_gift_present_2nd,

        ROUND((a.sum_gift_present_1st_orderbase)::FLOAT / NULLIF(a.count_target_customer, 0), 2)          AS gift_present_1st_rate,
        ROUND((a.sum_error_mail_present_1st)::FLOAT / NULLIF(a.sum_gift_present_1st_orderbase, 0), 2)      AS error_mail_present_1st_rate,
        ROUND((a.sum_null_email_present_1st)::FLOAT / NULLIF(a.sum_gift_present_1st_orderbase, 0), 2)      AS null_mail_present_1st_rate,

        ROUND((a.sum_gift_present_2nd_orderbase)::FLOAT / NULLIF(a.count_target_customer, 0), 2)           AS gift_present_2nd_rate,
        ROUND((a.sum_error_mail_present_2nd)::FLOAT / NULLIF(a.sum_gift_present_2nd_orderbase, 0), 2)       AS error_mail_present_2nd_rate,
        ROUND((a.sum_null_email_present_2nd)::FLOAT / NULLIF(a.sum_gift_present_2nd_orderbase, 0), 2)       AS null_mail_present_2nd_rate,

        ROUND((a.sum_null_email)::FLOAT / NULLIF(a.count_target_customer, 0), 2) AS null_email_rate

    FROM
        agg_by_cohort_month a -- 02. の受注コホート情報

    -- その月に「実際に1回目として配信された」件数の結合
    LEFT JOIN
        (
            SELECT gift_present_month_1st, subsc_category, SUM(is_gift_present_1st) AS sum_gift_present_1st
            FROM prepared_cohort_base
            GROUP BY gift_present_month_1st, subsc_category
        ) b
    ON a.ordered_year_month_f1 = b.gift_present_month_1st
    AND a.subsc_category = b.subsc_category

    -- その月に「実際に2回目として配信された」件数の結合
    LEFT JOIN
        (
            SELECT gift_present_month_2nd, subsc_category, SUM(is_gift_present_2nd) AS sum_gift_present_2nd
            FROM prepared_cohort_base
            GROUP BY gift_present_month_2nd, subsc_category
        ) c
    ON a.ordered_year_month_f1 = c.gift_present_month_2nd
    AND a.subsc_category = c.subsc_category
)

----------------------------------------------------------------------
-- 4. [Final Output] 分析ダッシュボード用データの整形
--    Data Grain: 受注月（ordered_year_month_f1）, 定期コース
----------------------------------------------------------------------
SELECT
    ordered_year_month_f1  AS "受注月",
    subsc_category         AS "定期コース_分類",
    count_target_customer  AS "対象者数",

    sum_null_email         AS "メール未登録件数",
    null_email_rate        AS "メール未登録率",

    sum_gift_present_1st_orderbase        AS "【特典_1回目】配信件数_受注月由来",
    gift_present_1st_rate                 AS "【特典_1回目】配信率_受注月由来",
    sum_error_mail_present_1st            AS "【特典_1回目】配信エラー件数_受注月由来",
    error_mail_present_1st_rate           AS "【特典_1回目】配信エラー率_受注月由来",
    sum_null_email_present_1st            AS "【特典_1回目】メール未登録件数_受注月由来",
    null_mail_present_1st_rate            AS "【特典_1回目】メール未登録率_受注月由来",
    avg_days_from_order_to_present_1st    AS "【特典_1回目】平均日数（受注→配信）",

    sum_gift_present_2nd_orderbase        AS "【特典_2回目】配信件数_受注月由来",
    gift_present_2nd_rate                 AS "【特典_2回目】配信率_受注月由来",
    sum_error_mail_present_2nd            AS "【特典_2回目】配信エラー件数_受注月由来",
    error_mail_present_2nd_rate           AS "【特典_2回目】配信エラー率_受注月由来",
    sum_null_email_present_2nd            AS "【特典_2回目】メール未登録件数_受注月由来",
    null_mail_present_2nd_rate            AS "【特典_2回目】メール未登録率_受注月由来",
    avg_days_from_order_to_present_2nd    AS "【特典_2回目】平均日数（受注→配信）",

    sum_gift_present_1st   AS "【特典_1回目】配信件数_配信月由来",
    sum_gift_present_2nd   AS "【特典_2回目】配信件数_配信月由来"

FROM
    integrated_cohort_and_monthly_actuals -- 03. の情報

ORDER BY
    ordered_year_month_f1 ASC, subsc_category ASC
;
