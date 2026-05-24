/*
==============================================================================================
 Approach 2: 行番号グループ化 (ROW_NUMBER Grouping)
==============================================================================================
 【ロジックの意図】
  Gaps and Islands問題における世界標準の定石（王道）アプローチです。
  「日付」から「連番(ROW_NUMBER)」を引き算すると、連続している日はすべて「同じ基準日」に
  なるという数学的なトリックを利用して、連続区間をグループ化（ガッチャンコ）します。

 【処理のイメージ】
  日付 (A)      |  行番号 (B) |  差分 (A - B 日) = グループキー
  -------------------------------------------------------------
  2021-01-01  |  1          |  2020-12-31  (連続グループ1)
  2021-01-02  |  2          |  2020-12-31  (連続グループ1)
  2021-01-03  |  3          |  2020-12-31  (連続グループ1)  --> Count = 3!
  2021-01-06  |  4          |  2021-01-02  (連続グループ2)
==============================================================================================
*/

WITH 
unique_events AS (
    -- 1. [前処理] 同日重複アクセスの排除
    SELECT DISTINCT user_id, record_date FROM sf_events
),

grouped_events AS (
    -- 2. [グループキー生成] 日付 - 行番号（日数）で連続区間を特定
    -- ※ PostgreSQL環境等の場合。BigQuery等は DATE_SUB を使用
    SELECT 
        user_id,
        record_date,
        record_date - ROW_NUMBER() OVER(PARTITION BY user_id ORDER BY record_date ASC) AS grp_date
    FROM unique_events
),

consecutive_counts AS (
    -- 3. [集計] 同じグループキーごとに日数をカウント
    SELECT 
        user_id, 
        grp_date, 
        COUNT(*) AS consecutive_days
    FROM grouped_events
    GROUP BY user_id, grp_date
)

-- 4. [最終出力] 3日以上連続したグループを持つユーザーを抽出
SELECT DISTINCT user_id
FROM consecutive_counts
WHERE consecutive_days >= 3;
