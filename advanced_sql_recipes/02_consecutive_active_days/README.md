# 🧩 SQL Challenge: 連続アクティブユーザーの抽出 (Consecutive Active Days)

## 📖 シナリオ / Scenario
あなたはアプリのユーザーエンゲージメントを分析するデータエンジニアです。
ユーザーのログイン（またはアクション）履歴が記録されたイベントログテーブルがあります。

あなたの任務は、このログデータから
**「3日以上連続してアクティブだったユーザー（user_id）」** をすべて抽出することです。

This is an advanced SQL challenge from StrataScratch (ID: 2054, Hard).
Your task is to analyze user engagement logs and find all the users who were active for 3 consecutive days or more.

---

## 📊 インプットデータ / Input Data
以下のようなイベントログテーブル `sf_events` が与えられます。
※同じ日に同じユーザーが複数回アクションを起こしている（重複レコードがある）可能性もあります。

| record_date | account_id | user_id |
| :--- | :--- | :--- |
| 2021-01-01 | A1 | U1 |
| 2021-01-01 | A1 | U2 |
| 2021-01-02 | A1 | U1 |
| 2021-01-03 | A1 | U1 |
| 2021-01-06 | A1 | U3 |
| 2021-01-07 | A1 | U3 |
| 2021-01-08 | A1 | U3 |

### 📅 視覚的イメージ (Visualizing the Timeline)
```text
Day: 01  02  03  04  05  06  07  08
 U1: 🟢--🟢--🟢                   -> [🎯 3日連続!]
 U2: 🟢                           -> [❌ 1日のみ]
 U3:                     🟢--🟢--🟢 -> [🎯 3日連続!]
 ```  

---

## 🎯 期待されるアウトプット / Expected Output  
3日以上連続でアクティブだった user_id のリストを出力してください（重複不可）。  

| user_id |
| :--- |
| U1 |
| U3 |  

---

## 💻 テストデータ (Test Data Generator)  
手元で試せるように、以下のCTEを使用してクエリを構築してください。  
Use the following CTE to test your query.  

```sql
WITH sf_events AS (
    -- U1: 1/1, 1/2, 1/3 (3日連続)
    SELECT CAST('2021-01-01' AS DATE) AS record_date, 'A1' AS account_id, 'U1' AS user_id UNION ALL
    SELECT CAST('2021-01-02' AS DATE), 'A1', 'U1' UNION ALL
    SELECT CAST('2021-01-03' AS DATE), 'A1', 'U1' UNION ALL
    -- U1: 同日重複のダミーデータ
    SELECT CAST('2021-01-01' AS DATE), 'A1', 'U1' UNION ALL
    
    -- U2: 1/1, 1/3, 1/4 (途切れているのでNG)
    SELECT CAST('2021-01-01' AS DATE), 'A1', 'U2' UNION ALL
    SELECT CAST('2021-01-03' AS DATE), 'A1', 'U2' UNION ALL
    SELECT CAST('2021-01-04' AS DATE), 'A1', 'U2' UNION ALL
    
    -- U3: 1/6, 1/7, 1/8 (3日連続)
    SELECT CAST('2021-01-06' AS DATE), 'A1', 'U3' UNION ALL
    SELECT CAST('2021-01-07' AS DATE), 'A1', 'U3' UNION ALL
    SELECT CAST('2021-01-08' AS DATE), 'A1', 'U3'
)
-- ここからクエリを記述してください / Write your query below
SELECT * FROM sf_events;
```  
