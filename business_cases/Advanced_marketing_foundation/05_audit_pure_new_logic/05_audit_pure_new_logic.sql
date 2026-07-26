/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 純新規判定ロジック 監査・精度検証マスタ
  Pure-New Logic Audit & Accuracy Verification (Audit Layer)

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. ロジック有効性の可視化 (Visualization of Logic Efficacy)
     前工程（int_pure_new_classification_master）で実装した「獲得日基準の純新規判定」
     によって、顧客統合（名寄せ）起因の過去改変から「救済された顧客数」を可視化します。
  2. 潜在的バグの検知 (Detection of Potential Anomalies)
     判定の鍵となる「顧客統合フラグ（is_cus_merged）」はテキストマイニング（コメント抽出等）
     に依存しているため、抽出漏れ（False Negative）のリスクがあります。
     「統合フラグが無いにもかかわらず、全履歴と獲得日で判定が異なる層」を特定し、
     フラグ漏れの疑いがあるデータを自動検知します。
  3. 構成比の監視 (Ratio Monitoring for SLI)
     各判定パターンの構成比（%）をウィンドウ関数を用いて算出し、
     パイプラインの健康状態を監視するためのSLI（Service Level Indicator）を提供します。

  1. Visualization of Logic Efficacy
     Quantifies the number of customers whose "Pure-New" status was successfully 
     rescued from historical overwrites caused by operational customer merges.
  2. Detection of Potential Anomalies
     Because the "merge flag" depends on text mining (e.g., operator notes), there is a risk of 
     false negatives. The query identifies cohorts where the flag is absent, yet the 
     full-history and acquisition-anchored statuses conflict, highlighting potential data leaks.
  3. Ratio Monitoring for SLI
     Calculates the percentage distribution of each evaluation pattern using Window Functions 
     to serve as Service Level Indicators (SLIs) for pipeline health monitoring.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
このクエリは以下の処理ステップで構成されています。
This query consists of the following processing layers.

  1. check_base_table
     前工程から判定用フラグと統合フラグの抽出
     Extracting evaluation flags and merge flags from the previous step.

  2. add_pattern_label
     フラグの整合性チェックに基づく健康状態のラベリング（パターン分類）
     Cross-checking flag consistency and labeling the data's "health status" (Pattern Classification).

  3. Final Output
     判定パターンごとの対象ユーザー数および構成比（%）の集計
     Aggregating target user counts and calculating percentage distributions per pattern.

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  Evaluation Pattern Level (判定パターン単位の集約)
  Aggregated to the Evaluation Pattern Level

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: window functions)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 純新規判定 監査レポートテーブル
  rpt_audit_pure_new_logic
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [Base Extraction] 判定元データの抽出
--    Data Grain: user_id
----------------------------------------------------------------------
check_base_table AS (
    SELECT
        user_id, 
        is_cus_merged, 
        
        -- Full-History Baseline (全履歴基準)
        CASE WHEN total_order_no = 1 THEN 1 ELSE 0 END AS is_pure_new_total,
        
        -- Acquisition-Anchored Baseline (獲得日基準)
        CASE WHEN valid_order_no = 1 THEN 1 ELSE 0 END AS is_pure_new_valid
        
    FROM 
        int_pure_new_classification_master -- 【前工程】04_int_pure_new_classification.sql 相当
),

----------------------------------------------------------------------
-- 2. [Pattern Labeling] フラグ整合性チェックと健康状態ラベリング
--    Data Grain: user_id
----------------------------------------------------------------------
add_pattern_label AS (
    SELECT
        *, 
        CASE
            -- パターン①：【狙い通り】統合による過去データ混入を、獲得日基準で純新規に救済・固定できた層。
            -- (Success: Rescued Pure-New status despite customer merge)
            WHEN is_cus_merged = 1 AND is_pure_new_total <> 1 AND is_pure_new_valid = 1 
             THEN '①【SUCCESS】Rescued Pure-New status despite customer merge (狙い通りの救済)'
            
            -- パターン②：【正常】統合されているが、時系列的に今回の注文が最初の接触で矛盾がない層。
            -- (Normal: Merged, but chronologically the true first order)
            WHEN is_cus_merged = 1 AND is_pure_new_total = 1 AND is_pure_new_valid = 1 
             THEN '②【NORMAL】Merged but chronologically true first order (統合有/正常新規)'
            
            -- パターン③：【正常】統合されていない一般的な新規客。
            -- (Normal: Unmerged, standard Pure-New customer)
            WHEN is_cus_merged <> 1 AND is_pure_new_total = 1 AND is_pure_new_valid = 1 
             THEN '③【NORMAL】Unmerged, standard Pure-New customer (統合無/正常新規)'
            
            -- パターン④：【要注意】統合フラグが無いのに、獲得日以前に履歴がある層。
            -- ＝「フラグ抽出の網目から漏れて名寄せされている顧客」がいる可能性を示す。
            -- (Alert: Unmerged flag, but conflicting history. Potential logic leak.)
            WHEN is_cus_merged <> 1 AND is_pure_new_total <> 1 AND is_pure_new_valid = 1 
             THEN '④【ALERT!!】Conflict detected without merge flag. Potential logic leak (★フラグ漏れの疑い)'
            
            -- パターン⑤：2回目以降の購入者（リピーター）など、今回の新規判定の対象外。
            -- (Other: Repeaters, out of scope for Pure-New evaluation)
            ELSE '⑤【OTHER】Repeaters or out of scope (既存客など)'
        END AS pattern_label
        
    FROM 
        check_base_table
)

----------------------------------------------------------------------
-- 3. [Final Output] 判定パターンごとのインパクト（対象者数・構成比）集計
--    Data Grain: Evaluation Pattern Label
----------------------------------------------------------------------
SELECT
    is_cus_merged        AS "顧客統合フラグ",
    is_pure_new_total    AS "純新規フラグ(全履歴)",
    is_pure_new_valid    AS "純新規フラグ(分析対象)",
    pattern_label        AS "判定パターン_Health_Status",
    
    -- Target User Count
    COUNT(DISTINCT user_id) AS "対象者数",
    
    -- Percentage Distribution (Window function over aggregated results)
    ROUND(
        COUNT(DISTINCT user_id) * 100.0 / SUM(COUNT(DISTINCT user_id)) OVER () 
    , 2) AS "構成比_Percentage"

FROM
    add_pattern_label 

GROUP BY
    is_cus_merged,
    is_pure_new_total,
    is_pure_new_valid,
    pattern_label

ORDER BY
    pattern_label ASC
;
