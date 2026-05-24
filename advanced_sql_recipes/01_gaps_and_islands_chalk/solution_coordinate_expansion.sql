/*
  Chalk Sidewalk Problem: Gaps and Islands Solution
  Approach: Coordinate Expansion (Point-in-time analysis)
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
    -- パターン検証用：すっぽり内包されるケース
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
