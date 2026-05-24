# 🧩 SQL Challenge: 歩道のチョーク塗り問題 (Overlapping Intervals & Gaps and Islands)

## 📖 シナリオ / Scenario
ある歩道（Sidewalk）に、子供たちが青色（Blue）と赤色（Red）のチョークで線を引きました。
記録には「何メートル地点から何メートル地点まで、何色で引いたか」が残っていますが、
子供たちは自由に線を引いたため、**同じ色が重なったり、別の色と被ったり、途切れたり**しています。

あなたの任務は、この重なり合う線データを整理し、
**「1つの繋がった大きな島（区間）」**としてガッチャンコ（Merge）し、
各区間が「青」「赤」または「青＋赤（混色）」のどの状態になっているかを出力することです。

This is an advanced SQL challenge focusing on the **Gaps and Islands problem** with overlapping intervals. 
Your task is to merge overlapping and contiguous chalk lines on a sidewalk and determine the color state ('Blue', 'Red', or 'Blue+Red') for each continuous segment.

---

## 📊 インプットデータ / Input Data
以下のような `chalkdrawing_table` が与えられます。

| sidewalk_id | start_no | end_no | color |
| :--- | :--- | :--- | :--- |
| 1 | 1 | 5 | blue |
| 1 | 3 | 7 | blue | (前の線と重なっている)
| 1 | 6 | 9 | red  | (青の線と一部重なっている)
| 1 | 12 | 15| red  | (離れた場所に引かれている)

### 🎨 視覚的イメージ (Visualizing the Overlaps)
```text
Meter: 1  2  3  4  5  6  7  8  9  10 11 12 13 14 15
Blue : 🟦-🟦-🟦-🟦-🟦
Blue :       🟦-🟦-🟦-🟦-🟦
Red  :                   🟥-🟥-🟥-🟥
Red  :                                     🟥-🟥-🟥-🟥
------------------------------------------------------
Result:【--- 青 ---】【-青+赤-】【-赤-】(Gap)【-- 赤 --】
```  

---

## 🎯 期待されるアウトプット / Expected Output
重なりを解消し、状態が変化する区間ごとに開始・終了地点を出力してください。  

| 歩道ID | 開始地点 | 終了地点 | 状態 |
| :--- | :--- | :--- | :--- |
| 1 | 1	| 5 | 青 |
| 1 | 6	| 7 | 青＋赤 |
| 1 | 8	| 9 | 赤 |
| 1 | 12 | 15 | 赤 |  

(※何色も塗られていないギャップ区間「10〜11」は出力から除外してください)  

---

## 💻 テストデータ (Test Data Generator)  
手元で試せるように、以下のCTE（または一時テーブル）を使用してクエリを構築してください。  
Use the following CTE to test your query.  

```SQL
WITH chalkdrawing_table AS (
    SELECT 1 AS sidewalk_id, 1 AS start_no, 5 AS end_no, 'blue' AS color UNION ALL
    SELECT 1, 3, 7, 'blue' UNION ALL
    SELECT 1, 6, 9, 'red' UNION ALL
    SELECT 1, 12, 15, 'red' UNION ALL
    -- パターン検証用：すっぽり内包されるケース
    SELECT 2, 2, 8, 'blue' UNION ALL
    SELECT 2, 4, 5, 'blue'
)
-- ここからクエリを記述してください / Write your query below
SELECT * FROM chalkdrawing_table;
```  

---

## 💡 ヒントと解法はこちら / Hint & Solution
<details>
<summary>✅ <b>ここをクリックして【解説】を表示 / Click to show Explanation</b></summary>  

# 💡 Solution: 点展開アプローチ (Coordinate Expansion Approach)

歩道のチョーク塗り（オーバーラップと Gaps and Islands）問題に対する、私の解答例です。
複雑な区間の重なり判定を避けるため、**「一度すべての区間を1歩ずつの『点』に展開し、状態を判定してから再び『区間』に圧縮する」**というアプローチを採用しています。

## 🧠 アーキテクチャの意図 / Design Thinking

通常、区間（Interval）同士の重なりをSQLで解こうとすると、「AがBを完全に内包する」「Aの終点がBの始点と被る」など、膨大な条件分岐（Allen's Interval Algebra）が必要になり、バグの温床となります。
そこで本解法では、**問題を1次元（点）に落とし込むパラダイムシフト**を行いました。

### 処理のイメージ (Visualizing the Logic)
```text
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
```  

## ⚖️ トレードオフの考察 / Trade-off Analysis  
このアプローチは **「ロジックの透明性と堅牢性」において最強ですが、データエンジニアリングの観点では「データ量（パフォーマンス）」**とのトレードオフが発生します。  

- Pros（利点）: どんなに複雑に何十色が重なっていても、絶対に判定バグが起きない。コードが直感的で保守性が極めて高い。
- Cons（欠点）: generate_series を使用するため、開始地点と終了地点の差が天文学的な数字（例: 1〜1億）の場合、中間のデータが1億行生成されてしまい、メモリと計算リソースを圧迫する。  

実務においては、対象となる区間の長さ（データ量）をプロファイリングした上で、この「点展開アプローチ」を採用するかを判断します。  

</details>
<details>
<summary>🚀 <b>ここをクリックして【実装SQL】を表示 / Click to show SQL Code</b></summary>  

## 💻 実装SQL / Implementation Code  
そのまま実行可能なテストデータを含んだ完全なSQLコードです。  

```sql
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
```  
