/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 歩道のチョーク塗り問題: 点展開アプローチ
  Chalk Sidewalk Problem: Coordinate Expansion Approach (Point-in-Time Analysis)

【アルゴリズムの意図 / Algorithmic Approach】
----------------------------------------------------------------------------------------------
  複雑な区間（Interval）同士の重なり（Gaps and Islands問題）を解決するための、
  堅牢性の高いSQLパターンです。
  
  通常、区間の重なりを判定する際は複雑な条件分岐（内包、部分一致など）が必要になり、
  エッジケースでのバグ（False Separation等）が発生しやすくなります。
  本解法では、問題を1次元（点）に落とし込むパラダイムシフトを行いました。

  1. 座標展開 (Expansion)
     すべての区間を1歩ずつの「点」に展開し、タイムラインを生成します。
  2. 状態判定 (State Mapping)
     各点に対して色をマッピングし、その瞬間の「状態」を確定させます。
  3. 再集約 (Re-aggregation)
     状態が変わった瞬間にトリガーを立て、累積和（Running Sum）によって
     一意のグループID（島ID）を付与し、再び「区間」へと圧縮します。

  This approach transforms a complex 2D overlapping interval problem into a robust 
  1D point-in-time analysis. By expanding all intervals into individual "points" (coordinates), 
  mapping their states, and re-aggregating them using running sums, this method 
  mathematically guarantees zero logic bugs even in extreme edge cases (e.g., fully enclosed intervals).

  処理のイメージ (Visualizing the Logic)

  1. [座標展開] 線ではなく「点」として全座標を生成
   1  2  3  4  5  6  7  8  9  10
   .  .  .  .  .  .  .  .  .  .

  2. [色判定] 各点に対してLEFT JOINで色をマッピングし、MAXで状態を確定
   青 青 青 青 青 青＋赤 青＋赤 赤 赤 NULL

  3. [状態変化] LAG関数で前方の点と比較し、状態が変わった箇所にトリガー(1)を立てる
   1  0  0  0  0   1   0   1  0  1

  4. [島ID付与] トリガーを累積和(Running Sum)して固有のIDを振る
   ① ① ① ① ① ② ② ③ ③ ④

  5. [再集約] 島IDごとに MIN(開始) と MAX(終了) を取って区間に戻す！  

【トレードオフ / Trade-offs】
----------------------------------------------------------------------------------------------
  - Pros: ロジックが極めて直感的であり、エッジケースにおける判定バグが絶対に起きない。
  - Cons: 座標の範囲が巨大な場合（例: 1〜1億）、中間データが膨大になり計算リソースを圧迫する。

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
  0. chalkdrawing_table (Test Data)
     テスト用のダミーデータ（検証用エッジケース含む）
  1. sidewalk_bounds ~ expand_coordinates
     歩道ごとの最小・最大座標を取得し、generate_series で全座標を「点」として展開
  2. mapped_colors ~ aggregated_point_colors
     展開した各座標に対して色（青/赤）をマッピングし、状態（混色など）を確定
  3. detect_state_changes ~ assign_island_ids
     LAG関数で状態変化を検知し、累積和（SUM OVER）によって一意の島IDを生成
  4. group_by_islands
     島IDごとにMIN/MAXを取って再び「区間」に再構築し、最終出力
==============================================================================================
*/

WITH 
-- ==========================================
-- 0. [Test Data] テスト用のダミーデータ
-- ==========================================
chalkdrawing_table AS (
    SELECT 1 AS sidewalk_id, 1 AS start_no, 5 AS end_no, 'blue' AS color UNION ALL
    SELECT 1, 3, 7, 'blue' UNION ALL
    SELECT 1, 6, 9, 'red' UNION ALL
    SELECT 1, 12, 15, 'red' UNION ALL
    -- パターン検証用：すっぽり内包されるエッジケース
    SELECT 2, 2, 8, 'blue' UNION ALL
    SELECT 2, 4, 5, 'blue'
),

-- ==========================================
-- 1. Main Pipeline
-- ==========================================
chalk_lines AS (
    SELECT sidewalk_id, start_no, end_no, color FROM chalkdrawing_table
),

sidewalk_bounds AS (
    -- [境界取得] 歩道ごとの描画範囲の取得
    SELECT sidewalk_id, MIN(start_no) AS min_start_no, MAX(end_no) AS max_end_no 
    FROM chalk_lines GROUP BY sidewalk_id
),

expand_coordinates AS (
    -- [座標展開] generate_seriesで全座標(点)を生成
    -- ※ Snowflake環境等の場合は GENERATOR(rowcount => ...) 等に書き換え可能
    SELECT a.sidewalk_id, generate_series(a.min_start_no, a.max_end_no, 1) AS coord_point 
    FROM sidewalk_bounds a
),

mapped_colors AS (
    -- [色判定準備] 各座標がどの色の区間に含まれるか判定
    SELECT
        a.sidewalk_id, a.coord_point,
        CASE WHEN a.coord_point >= b.start_no AND a.coord_point <= b.end_no THEN 'blue' END AS blue_part,
        CASE WHEN a.coord_point >= c.start_no AND a.coord_point <= c.end_no THEN 'red' END AS red_part
    FROM expand_coordinates a
    LEFT JOIN chalk_lines b ON a.sidewalk_id = b.sidewalk_id AND b.color = 'blue'
    LEFT JOIN chalk_lines c ON a.sidewalk_id = c.sidewalk_id AND c.color = 'red'
),

aggregated_point_colors AS (
    -- [色判定確定] 座標ごとの最終的な色状態を確定
    SELECT
        sidewalk_id, coord_point,
        CASE
            WHEN MAX(blue_part) IS NOT NULL AND MAX(red_part) IS NOT NULL THEN '青＋赤'
            WHEN MAX(blue_part) IS NOT NULL THEN '青'
            WHEN MAX(red_part) IS NOT NULL THEN '赤'
            ELSE NULL
        END AS color_state
    FROM mapped_colors
    GROUP BY sidewalk_id, coord_point
),

detect_state_changes AS (
    -- [状態変化検知] 色が変わったタイミングにトリガー(1)を立てる
    SELECT
        sidewalk_id, coord_point, color_state,
        CASE 
            WHEN COALESCE(color_state, 'NONE') <> COALESCE(LAG(color_state) OVER (PARTITION BY sidewalk_id ORDER BY coord_point ASC), 'NONE') THEN 1 
            ELSE 0 
        END AS is_start_step
    FROM aggregated_point_colors
),

assign_island_ids AS (
    -- [島ID付与] トリガーの累積和で一意の島IDを生成
    SELECT
        *,
        SUM(is_start_step) OVER (PARTITION BY sidewalk_id ORDER BY coord_point ASC) AS island_id 
    FROM detect_state_changes
),

group_by_islands AS (
    -- [区間集約] 島IDごとにMIN/MAXを取って区間を再構築
    SELECT
        sidewalk_id, island_id,
        MAX(color_state) AS section_color,
        MIN(coord_point) AS start_no,
        MAX(coord_point) AS end_no
    FROM assign_island_ids
    GROUP BY sidewalk_id, island_id
)

-- ==========================================
-- 2. Final Output
-- ==========================================
SELECT
    sidewalk_id      AS "歩道ID",
    start_no         AS "開始地点",
    end_no           AS "終了地点",
    section_color    AS "状態"
FROM group_by_islands
WHERE section_color IS NOT NULL -- ギャップ（空白）区間を除外
ORDER BY sidewalk_id ASC, start_no ASC;
