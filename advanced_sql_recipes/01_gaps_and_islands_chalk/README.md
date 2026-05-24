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
