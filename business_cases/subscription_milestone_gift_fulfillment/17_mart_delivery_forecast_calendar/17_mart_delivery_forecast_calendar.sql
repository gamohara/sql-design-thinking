/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 配信予定件数カレンダーと在庫枯渇シミュレーション
  Delivery Forecast Calendar & Stock-Out Simulation — Marts Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  特典の「配信予定日」ごとの対象者数（予測件数・予定件数）を出力する。BIツールで推移
  グラフを作成する際、対象者が「0人」の日でグラフが歯抜けになるのを防ぐため、カレンダー
  テーブルを自動生成してゼロ埋め補完を行う。

  ★【UI/UXへの配慮（カレンダーの月次丸め）】
  実績データの最初と最後の日付を基準にしつつ、カレンダーの範囲を強制的に「一番古い日付の
  月初（1日）」から「一番未来の日付の月末」まで拡張することで、ダッシュボード上で常に
  美しい「月単位の推移グラフ」が描画されるように設計している。

  ★【在庫枯渇の自動検知（実績＋未来予定の累積シミュレーション）】
  ギフトコードの総在庫から「いつ在庫が切れるか」をシミュレーションするため、過去の配信
  完了実績と現在・未来の配信予測を縦結合して1本の連続したタイムラインを構築する。日別の
  配信予定数を累積和（Running Sum）で足し合わせ、マスタの総在庫数から引き算していくこと
  で、在庫が足りなくなる日を完全に自動で算出・警告する。

  Outputs the daily count of targeted customers per gift delivery date, zero-filled across a
  gap-free calendar so BI trend charts never show a misleading gap on zero-target days. It
  also runs a stock-out simulation: combining confirmed past deliveries with current/future
  projections into one continuous timeline, then subtracting the running-sum delivery count
  from the total code inventory to automatically flag the first date stock runs out.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
  1. daily_targetlist_build
     過去実績と現在・未来予測の統合
  2. daily_target_counts
     日別の対象者数カウント
  3-4. actual_date_range / monthly_rounded_date_range
     実績期間の取得と月初〜月末への拡張
  5. generated_calendar_dates
     ギャップフリーの連続カレンダー生成
  6. calendar_joined_daily_counts
     カレンダーと実績のゼロ埋め結合
  7. calc_cumulative_and_stock
     累積和による在庫シミュレーション
  8. detect_out_of_stock_date
     在庫切れXデーの特定
  9. Final Output

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  digital_gift_present_date (連続した日付)

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  digital_gift_present_date

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: TABLE(GENERATOR), SEQ4, DATE_TRUNC)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 配信予定カレンダーマートテーブル
  mart_delivery_forecast_calendar
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [List Build] 過去実績（手動）と現在・未来予測（システム）の統合
--    ★重要: 未来予測に影響が出ないよう、未入金や出荷止まりの除外は「現在（当日）」のみに適用する。
--    Data Grain: user_id, digital_gift_present_date
----------------------------------------------------------------------
daily_targetlist_build AS (
    -- ① 現在・未来の予測データ（システム抽出）
    SELECT
        user_id,
        digital_gift_present_date
    FROM
        int_predelivery_alert_check -- 【前工程】10_int_predelivery_alert_check
    WHERE
        time_line IN ('現在', '未来')
      AND NOT (
          is_due_to_email_error = 1
          OR (time_line = '現在' AND is_shipped_not_delivered = 1)
          OR (time_line = '現在' AND is_payment_pending = 1)
      )

    UNION ALL

    -- ② 過去の確定配信実績（手動CSV）
    SELECT
        user_id,
        CASE
            WHEN irregular_gift_present_date IS NOT NULL THEN irregular_gift_present_date
            ELSE digital_gift_present_date
        END AS digital_gift_present_date
    FROM
        map_gift_target_ledger -- 対象者リスト
    WHERE
        DATEDIFF(day, digital_gift_present_date, CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE) > 0
),

----------------------------------------------------------------------
-- 2. [Daily Counts] 予定日・実績日ごとの対象者数カウント
--    Data Grain: digital_gift_present_date
----------------------------------------------------------------------
daily_target_counts AS (
    SELECT
        digital_gift_present_date,
        COUNT(user_id) AS present_cus_count
    FROM
        daily_targetlist_build -- 01. の情報
    GROUP BY
        digital_gift_present_date
),

----------------------------------------------------------------------
-- 3. [Date Range] 実績データの最小日と最大日の取得
--    Data Grain: 1行のみ
----------------------------------------------------------------------
actual_date_range AS (
    SELECT
        MIN(digital_gift_present_date) AS min_gift_present_date,
        MAX(digital_gift_present_date) AS max_gift_present_date
    FROM
        daily_target_counts -- 02. の情報
),

----------------------------------------------------------------------
-- 4. [Range Expansion] カレンダー出力範囲の「月初〜月末」への丸め
--    Data Grain: 1行のみ
----------------------------------------------------------------------
monthly_rounded_date_range AS (
    SELECT
        DATE_TRUNC('MONTH', min_gift_present_date) AS from_gift_present_date,
        DATEADD(day, -1,
            DATE_TRUNC('MONTH',
                DATEADD(month, +1, max_gift_present_date)
            )
        ) AS to_gift_present_date
    FROM
        actual_date_range -- 03. の情報
),

----------------------------------------------------------------------
-- 5. [Calendar Generation] ギャップフリーの連続日付テーブル作成
--    Data Grain: date_calendar (1日1行)
----------------------------------------------------------------------
generated_calendar_dates AS (
    SELECT
        DATEADD(day, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, a.from_gift_present_date) AS date_calendar,
        a.to_gift_present_date
    FROM
        TABLE(GENERATOR(ROWCOUNT => 3650)) -- 最大10年分（3650日）の枠を確保
    CROSS JOIN
        monthly_rounded_date_range a -- 04. の情報
),

----------------------------------------------------------------------
-- 6. [Zero-Fill] カレンダーと実績の結合（ゼロ埋め）
--    Data Grain: digital_gift_present_date (連続した日付)
----------------------------------------------------------------------
calendar_joined_daily_counts AS (
    SELECT
        b.date_calendar AS digital_gift_present_date,
        COALESCE(c.present_cus_count, 0) AS present_cus_count
    FROM
        generated_calendar_dates b -- 05. の情報
    LEFT JOIN
        daily_target_counts c -- 02. の情報
    ON b.date_calendar = c.digital_gift_present_date
    WHERE
        b.date_calendar <= b.to_gift_present_date
),

----------------------------------------------------------------------
-- 7. [Stock Simulation] 過去実績を含む累積和と在庫枯渇判定
--    Data Grain: digital_gift_present_date (連続した日付)
----------------------------------------------------------------------
calc_cumulative_and_stock AS (
    SELECT
        c.*,
        CASE
            WHEN d.all_present_count
                    - SUM(c.present_cus_count) OVER(ORDER BY c.digital_gift_present_date ASC) <= 0
             THEN 1
            ELSE 0
        END AS is_out_of_stock
    FROM
        calendar_joined_daily_counts c -- 06. のゼロ埋め済情報
    CROSS JOIN
        (
            SELECT COUNT(digital_gift_code) AS all_present_count
            FROM map_gift_code_inventory -- デジタルギフトコード在庫一覧
        ) d
),

----------------------------------------------------------------------
-- 8. [Alert Detection] 在庫切れXデーの特定
--    Data Grain: digital_gift_present_date (連続した日付)
----------------------------------------------------------------------
detect_out_of_stock_date AS (
    SELECT
        *,
        MIN(CASE WHEN is_out_of_stock = 1 THEN digital_gift_present_date ELSE NULL END) OVER() AS min_out_of_stock_date
    FROM
        calc_cumulative_and_stock -- 07. の情報
)

----------------------------------------------------------------------
-- 9. [Final Output] 分析・ダッシュボード表示用データの整形
--    Data Grain: digital_gift_present_date
----------------------------------------------------------------------
SELECT
    digital_gift_present_date AS "配信日_デジタルギフト",
    TO_NUMBER(TO_CHAR(digital_gift_present_date, 'YYYYMM')) AS "配信月_デジタルギフト",
    present_cus_count         AS "対象者数",

    CASE
        WHEN min_out_of_stock_date IS NOT NULL
            THEN TO_CHAR(min_out_of_stock_date, 'YY/MM/DD') || '_在庫切れ予定'
        ELSE '在庫あり（問題なし）'
    END AS "在庫切れアラート"

FROM
    detect_out_of_stock_date -- 08. の在庫判定済情報

ORDER BY
    digital_gift_present_date ASC
;
