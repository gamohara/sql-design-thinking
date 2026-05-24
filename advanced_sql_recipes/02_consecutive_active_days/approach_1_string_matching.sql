/*
==============================================================================================
 Approach 1: 文字列パターンマッチング (String Pattern Matching)
==============================================================================================
 【ロジックの意図】
  日付の連続性を「数学的な計算」ではなく、「経過日数の配列」という直感的な状態に変換し、
  LIKE演算子による文字列検索で解決する「水平思考（ハッカー的アプローチ）」です。

 【処理のイメージ】
  1. [差分計算] 直前のアクセスから「何日空いたか」を計算する
     日付: 1/1   1/2   1/3   1/5   1/6
     差分: NULL   1     1     2     1
  2. [文字列化] ユーザーごとに差分を1つの文字列に繋げる
     U1_Diff_String = '1,1,2,1'
  3. [パターンマッチ] 「1日差が2回連続する（＝3日連続）」パターンを探す
     WHERE '1,1,2,1' LIKE '%1,1%'  -->  Match! (条件クリア🎯)
==============================================================================================
*/

WITH 
unique_events AS (
    -- 1. [前処理] 同日重複アクセスの排除
    SELECT DISTINCT user_id, record_date FROM sf_events
),

calc_date_diff AS (
    -- 2. [差分計算] 前回アクセスからの経過日数を算出してテキスト化
    SELECT 
        user_id,
        record_date,
        CAST((record_date - LAG(record_date) OVER (PARTITION BY user_id ORDER BY record_date ASC)) AS TEXT) AS diff_text
    FROM unique_events
),

aggregate_diff_strings AS (
    -- 3. [文字列集約] 経過日数をユーザーごとに1つの文字列に結合
    SELECT 
        user_id,
        ARRAY_TO_STRING(ARRAY_AGG(diff_text ORDER BY record_date ASC), ',') AS diff_text_agg
    FROM calc_date_diff
    GROUP BY user_id
)

-- 4. [最終出力] '1,1'（1日差が2回連続＝3日連続）を含むユーザーを抽出
SELECT user_id 
FROM aggregate_diff_strings
WHERE diff_text_agg LIKE '%1,1%';
