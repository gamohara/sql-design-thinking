/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 実発送なし（ダミー出荷）と形式的返品の紐付け処理マスタ
  Dummy Shipment and Formal Return Matching (Staging Layer)

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. フィンガープリントの生成
     注文構成の同一性を評価するため、商品ID、カテゴリ、数量の配列を
     LISTAGGを用いて文字列化し、段階的な比較用フィンガープリントを生成。
  2. 多段階ゲート・マッチング
     厳格な条件から緩やかな条件まで、6段階（STRICT, FLEXIBLE, RELAXED, INCLUSIVE, GENERIC, POTENTIAL）
     の関門を設け、段階的にペア候補を特定しスコアリング。
  3. カスケード型貪欲法による競合解消
     同じ返品IDを複数のダミー出荷が取り合う「N対MのJOIN爆発」を防ぐため、
     スコアと時系列に基づく優先順位（Rank）を付与。上位ランクで確定した
     「使用済みID」を順次除外（Anti-Join）しながら、1対1の双方向ユニークを担保。
  4. データオブザーバビリティ
     マッチング強度ごとの分布（%）および UNMATCHED（紐付け失敗）の割合を算出し、
     パイプラインの健康状態を監視するためのSLI（Service Level Indicator）として出力。

  1. Fingerprint Generation
     Serializing arrays of Product IDs, categories, and quantities using LISTAGG 
     to generate multi-level fingerprints for order composition comparison.
  2. Multi-Gate Matching Evaluation
     Identifying and scoring pair candidates through 6 progressive gates 
     (STRICT to POTENTIAL) ranging from exact matches to heuristic estimations.
  3. Cascade Greedy Conflict Resolution
     Preventing N-to-M JOIN explosions by ranking candidates via scores and timestamps.
     Implementing a greedy algorithm via successive Anti-Joins to exclude already-matched IDs,
     ensuring strict 1-to-1 bidirectional uniqueness.
  4. Data Observability
     Calculating the percentage distribution of match strengths and UNMATCHED ratios 
     as Service Level Indicators (SLIs) to monitor pipeline health.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
このクエリは以下の処理ステップで構成されています。
This query consists of the following processing layers.

  1. base_order_dummy_table / base_order_return_table
     マッチング用基礎データの集計とフィンガープリント生成
     Aggregation and fingerprint generation for dummy shipments and formal returns.

  2. find_dummy_pairs_gate_1 ~ 6
     第1〜6関門の条件に基づくペア候補の抽出
     Extraction of pair candidates based on 6 progressive gate conditions.

  3. find_dummy_pairs_gate_union & evaluate_conflict_rank
     全候補の統合およびユーザー内での優先順位（Rank）付け
     Union of all candidates and calculation of conflict ranks per user.

  4. resolve_rank_X_pairs
     カスケード型の自己除外結合（Anti-Join）を用いた敗者復活戦（Rank 1 ~ 3）
     Cascade greedy resolution using anti-joins to establish 1-to-1 unique pairs.

  5. Final Output
     最終的な紐付け結果の出力およびモニタリング指標（SLI）の算出
     Final output of matched pairs alongside matching accuracy SLIs.

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  Order Level (ダミー出荷の親注文レベル)
  Aggregated to the Dummy Shipment Order Level

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  user_id, order_id (Dummy Shipment Order ID)

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: utilizes QUALIFY and LISTAGG WITHIN GROUP)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 実発送なし・返品紐付けステージングテーブル
  stg_no_real_ship_matching
==============================================================================================
*/

WITH 
----------------------------------------------------------------------
-- 1. [Dummy Base] ダミーテーブルの構成ハッシュ化
--    Data Grain: order_id
----------------------------------------------------------------------
base_order_dummy_table AS (
    SELECT
        user_id,
        order_id,
        order_id_prefix,
        MAX(shipment_date)  AS ship_date,
        
        -- Fingerprints (LISTAGG for Exact Matching)
        LISTAGG(product_id || ':' || TO_VARCHAR(quantity), '|') WITHIN GROUP (ORDER BY product_id) AS fp_product_qty,
        LISTAGG(product_cate_lvl_5 || ':' || TO_VARCHAR(quantity), '|') WITHIN GROUP (ORDER BY product_cate_lvl_5 ASC, quantity ASC) AS fp_cate_qty,
        LISTAGG(DISTINCT product_id, '|') WITHIN GROUP (ORDER BY product_id) AS fp_product_only,
        LISTAGG(DISTINCT product_cate_lvl_5, '|') WITHIN GROUP (ORDER BY product_cate_lvl_5) AS fp_cate_only,
        
        SUM(quantity)              AS rg_quantity, 
        MAX(total_payment_amount)  AS total_payment_amount,
        
        MAX(is_biz_cnsl)           AS is_biz_cnsl,
        MAX(is_biz_return)         AS is_biz_return,
        MAX(is_sys_cnsl)           AS is_sys_cnsl,
        MAX(is_sys_return)         AS is_sys_return,
        MAX(return_completed_date) AS return_completed_date,
        MAX(return_reason_note)    AS return_reason_note

    FROM (
        SELECT
            user_id, 
            order_id, 
            LEFT(order_id, 1) AS order_id_prefix,
            product_id,
            MAX(product_analysis_category_level_5) AS product_cate_lvl_5,
            MAX(scheduled_ship_date)  AS shipment_date,
            SUM(quantity)             AS quantity, 
            MAX(total_payment_amount) AS total_payment_amount, 
            MAX(is_biz_cnsl)          AS is_biz_cnsl,
            MAX(is_biz_return)        AS is_biz_return,
            MAX(is_sys_cnsl)          AS is_sys_cnsl,
            MAX(is_sys_return)        AS is_sys_return,
            MAX(return_completed_at)  AS return_completed_date,
            MAX(return_reason_note)   AS return_reason_note
        FROM 
            raw_no_real_ship_data -- 【元データ】ダミー出荷データ
        WHERE 
            product_external_id4 = 'RG'
        GROUP BY
            1, 2, 4 
    )
    -- Exclude system returns/cancellations to reduce noise
    WHERE NOT (is_sys_cnsl = 1 OR is_sys_return = 1)
    GROUP BY
        user_id, order_id, order_id_prefix
),

----------------------------------------------------------------------
-- 2. [Return Base] 返品候補準備（システム準拠の純粋な返品のみ）
--    Data Grain: order_id
----------------------------------------------------------------------
base_order_return_table AS (
    SELECT
        user_id, 
        order_id, 
        MAX(shipment_date)  AS ship_date,
        
        -- Fingerprints
        LISTAGG(product_id || ':' || TO_VARCHAR(quantity), '|') WITHIN GROUP (ORDER BY product_id) AS fp_product_qty,
        LISTAGG(product_cate_lvl_5 || ':' || TO_VARCHAR(quantity), '|') WITHIN GROUP (ORDER BY product_cate_lvl_5 ASC, quantity ASC) AS fp_cate_qty,
        LISTAGG(DISTINCT product_id, '|') WITHIN GROUP (ORDER BY product_id) AS fp_product_only,
        LISTAGG(DISTINCT product_cate_lvl_5, '|') WITHIN GROUP (ORDER BY product_cate_lvl_5) AS fp_cate_only,
        
        SUM(quantity)              AS rg_quantity,
        MAX(total_payment_amount)  AS total_payment_amount,
        
        MAX(is_biz_cnsl)    AS is_biz_cnsl,
        MAX(is_biz_return)  AS is_biz_return,
        MAX(is_sys_cnsl)    AS is_sys_cnsl,
        MAX(is_sys_return)  AS is_sys_return

    FROM (
        SELECT
            user_id, 
            order_id, 
            product_id, 
            MAX(product_analysis_category_level_5) AS product_cate_lvl_5,
            MAX(scheduled_ship_date)  AS shipment_date,
            SUM(quantity)             AS quantity, 
            MAX(total_payment_amount) AS total_payment_amount, 
            MAX(is_biz_cnsl)          AS is_biz_cnsl,
            MAX(is_biz_return)        AS is_biz_return,
            MAX(is_sys_cnsl)          AS is_sys_cnsl,
            MAX(is_sys_return)        AS is_sys_return
        FROM 
            stg_all_purchases_base -- 【前工程】05_fct_all_purchases_unified
        WHERE 
            product_external_id4 = 'RG'   
            AND is_sys_cnsl <> 1             
            AND is_sys_return = 1              
            AND is_dummy_shipment <> 1  
        GROUP BY
            1, 2, 3 
    )
    GROUP BY
        user_id, order_id
),

----------------------------------------------------------------------
-- 3~8. [Matching Gates] 第1〜6関門のマッチング処理
--    Data Grain: dummy_ship_order_id, fake_return_order_id
----------------------------------------------------------------------
find_dummy_pairs_gate_1 AS (
    -- [STRICT] 商品ID+数量 ＆ 金額
    SELECT
        a.user_id, a.order_id AS dummy_ship_order_id, b.order_id AS fake_return_order_id,
        a.ship_date AS ship_date_dummy_ship, b.ship_date AS ship_date_fake_return,
        100 AS match_score, 'STRICT' AS match_strength
    FROM base_order_dummy_table a   
    INNER JOIN base_order_return_table b ON a.user_id = b.user_id 
        AND a.fp_product_qty = b.fp_product_qty AND a.total_payment_amount = b.total_payment_amount                  
    WHERE a.ship_date > b.ship_date
), 

find_dummy_pairs_gate_2 AS (
    -- [FLEXIBLE] カテゴリ+数量 ＆ 金額
    SELECT
        c.user_id, c.order_id AS dummy_ship_order_id, d.order_id AS fake_return_order_id,
        c.ship_date AS ship_date_dummy_ship, d.ship_date AS ship_date_fake_return,
        80 AS match_score, 'FLEXIBLE' AS match_strength
    FROM base_order_dummy_table c   
    INNER JOIN base_order_return_table d ON c.user_id = d.user_id 
        AND c.fp_cate_qty = d.fp_cate_qty AND c.total_payment_amount = d.total_payment_amount                                        
    WHERE c.ship_date > d.ship_date
), 

find_dummy_pairs_gate_3 AS (
    -- [RELAXED] カテゴリ+数量 のみ（金額ズレ救済）
    SELECT
        e.user_id, e.order_id AS dummy_ship_order_id, f.order_id AS fake_return_order_id,
        e.ship_date AS ship_date_dummy_ship, f.ship_date AS ship_date_fake_return,
        60 AS match_score, 'RELAXED' AS match_strength
    FROM base_order_dummy_table e   
    INNER JOIN base_order_return_table f ON e.user_id = f.user_id 
        AND e.fp_cate_qty = f.fp_cate_qty  
    WHERE e.ship_date > f.ship_date
), 

find_dummy_pairs_gate_4 AS (
    -- [POTENTIAL] カテゴリ大枠 ＆ 合計数量（個別数量ズレ救済）
    SELECT
        g.user_id, g.order_id AS dummy_ship_order_id, h.order_id AS fake_return_order_id,
        g.ship_date AS ship_date_dummy_ship, h.ship_date AS ship_date_fake_return,
        10 AS match_score, 'POTENTIAL' AS match_strength
    FROM base_order_dummy_table g   
    INNER JOIN base_order_return_table h ON g.user_id = h.user_id 
        AND g.fp_cate_only = h.fp_cate_only AND g.rg_quantity = h.rg_quantity                                        
    WHERE g.ship_date > h.ship_date
),

find_dummy_pairs_gate_5 AS (
    -- [INCLUSIVE] 商品ID のみ（旧型式の注文情報対応）
    SELECT
        i.user_id, i.order_id AS dummy_ship_order_id, j.order_id AS fake_return_order_id,
        i.ship_date AS ship_date_dummy_ship, j.ship_date AS ship_date_fake_return,
        40 AS match_score, 'INCLUSIVE' AS match_strength
    FROM base_order_dummy_table i   
    INNER JOIN base_order_return_table j ON i.user_id = j.user_id 
        AND i.fp_product_only = j.fp_product_only AND i.order_id_prefix = 'L' 
    WHERE i.ship_date > j.ship_date
),

find_dummy_pairs_gate_6 AS (
    -- [GENERIC] カテゴリ大枠 のみ（旧型式の注文情報対応）
    SELECT
        k.user_id, k.order_id AS dummy_ship_order_id, l.order_id AS fake_return_order_id,
        k.ship_date AS ship_date_dummy_ship, l.ship_date AS ship_date_fake_return,
        30 AS match_score, 'GENERIC' AS match_strength
    FROM base_order_dummy_table k   
    INNER JOIN base_order_return_table l ON k.user_id = l.user_id 
        AND k.fp_cate_only = l.fp_cate_only AND k.order_id_prefix = 'L'
    WHERE k.ship_date > l.ship_date
),

----------------------------------------------------------------------
-- 9~10. [Union & Ranking] 全関門の統合と優先順位の確定
----------------------------------------------------------------------
find_dummy_pairs_gate_union AS (
    SELECT * FROM find_dummy_pairs_gate_1 UNION ALL
    SELECT * FROM find_dummy_pairs_gate_2 UNION ALL
    SELECT * FROM find_dummy_pairs_gate_3 UNION ALL
    SELECT * FROM find_dummy_pairs_gate_4 UNION ALL
    SELECT * FROM find_dummy_pairs_gate_5 UNION ALL
    SELECT * FROM find_dummy_pairs_gate_6
),

evaluate_conflict_rank AS (
    SELECT
        *,
        ROW_NUMBER() OVER(
            PARTITION BY user_id
            ORDER BY match_score DESC, ship_date_dummy_ship DESC, dummy_ship_order_id DESC, ship_date_fake_return DESC, fake_return_order_id DESC
        ) AS conflict_rank
    FROM
        find_dummy_pairs_gate_union
),

----------------------------------------------------------------------
-- 11~14. [Conflict Resolution] カスケード型貪欲法（Greedy Algorithm）による競合解消
----------------------------------------------------------------------
resolve_rank_1_pairs AS (
    -- [Rank 1] 最優先ペアの確定
    SELECT user_id, dummy_ship_order_id, fake_return_order_id, match_score, match_strength, 1 AS is_rank_1
    FROM evaluate_conflict_rank WHERE conflict_rank = 1
),

resolve_rank_2_pairs AS (
    -- [Rank 2] Rank 1で使われたIDを除外し、残りで1位を確定 (Anti-Join)
    SELECT
        m.user_id, m.dummy_ship_order_id, m.fake_return_order_id, m.match_score, m.match_strength, 1 AS is_rank_2
    FROM evaluate_conflict_rank m
    LEFT JOIN resolve_rank_1_pairs n ON m.dummy_ship_order_id = n.dummy_ship_order_id
    LEFT JOIN resolve_rank_1_pairs o ON m.fake_return_order_id = o.fake_return_order_id
    WHERE n.is_rank_1 IS NULL AND o.is_rank_1 IS NULL
    QUALIFY ROW_NUMBER() OVER(PARTITION BY m.user_id ORDER BY m.conflict_rank ASC) = 1 
),

resolve_rank_3_pairs AS (
    -- [Rank 3] Rank 1, 2で使われたIDを除外し、残りで1位を確定
    SELECT
        p.user_id, p.dummy_ship_order_id, p.fake_return_order_id, p.match_score, p.match_strength, 1 AS is_rank_3
    FROM evaluate_conflict_rank p
    LEFT JOIN resolve_rank_1_pairs q ON p.dummy_ship_order_id = q.dummy_ship_order_id
    LEFT JOIN resolve_rank_1_pairs r ON p.fake_return_order_id = r.fake_return_order_id
    LEFT JOIN resolve_rank_2_pairs s ON p.dummy_ship_order_id = s.dummy_ship_order_id
    LEFT JOIN resolve_rank_2_pairs t ON p.fake_return_order_id = t.fake_return_order_id
    WHERE q.is_rank_1 IS NULL AND r.is_rank_1 IS NULL AND s.is_rank_2 IS NULL AND t.is_rank_2 IS NULL
    QUALIFY ROW_NUMBER() OVER(PARTITION BY p.user_id ORDER BY p.conflict_rank ASC) = 1 
),

final_resolved_pairs AS (
    -- [Union] 1対1の双方向ユニークが担保された最終ペアリスト
    SELECT * FROM resolve_rank_1_pairs UNION ALL
    SELECT * FROM resolve_rank_2_pairs UNION ALL
    SELECT * FROM resolve_rank_3_pairs
)

----------------------------------------------------------------------
-- 15. [Final Output] 最終出力およびSLI（モニタリング指標）の算出
----------------------------------------------------------------------
SELECT
    -- ====== IDs ======
    z.user_id                           AS "ユーザーID", 
    z.order_id                          AS "注文ID",
    NULLIF(y.fake_return_order_id, '')  AS "注文ID_形式的返品", 
    
    -- ====== Dates & Financials ======
    z.ship_date              AS "出荷日",
    z.rg_quantity            AS "累計注文数", 
    z.total_payment_amount   AS "支払金額合計（税込）", 
    
    -- ====== Returns Info ======
    z.is_biz_cnsl            AS "CNSLフラグ",
    z.is_biz_return          AS "返品フラグ", 
    z.is_sys_cnsl            AS "CNSLフラグ_システム基準",
    z.is_sys_return          AS "返品フラグ_システム基準",
    z.return_completed_date  AS "返品受付日",
    z.return_reason_note     AS "返品理由",
    
    -- ====== Match Status & Scores ======
    CASE WHEN NULLIF(y.fake_return_order_id, '') IS NOT NULL THEN 1 ELSE 0 END AS "紐づけフラグ", 
    COALESCE(NULLIF(y.match_strength, ''), 'UNMATCHED') AS "紐づけ強度", 
    COALESCE(y.match_score, 0)  AS "データ信頼度", 
    
    -- ====== Data Observability (SLIs) ======
    ROUND(100.0 * SUM(CASE WHEN NULLIF(y.match_strength, '') = 'STRICT' THEN 1 ELSE 0 END) OVER () / NULLIF(COUNT(*) OVER (), 0), 4) AS "紐づけ強度「STRICT」の割合",
    ROUND(100.0 * SUM(CASE WHEN NULLIF(y.match_strength, '') = 'FLEXIBLE' THEN 1 ELSE 0 END) OVER () / NULLIF(COUNT(*) OVER (), 0), 4) AS "紐づけ強度「FLEXIBLE」の割合", 
    ROUND(100.0 * SUM(CASE WHEN NULLIF(y.match_strength, '') = 'RELAXED' THEN 1 ELSE 0 END) OVER () / NULLIF(COUNT(*) OVER (), 0), 4) AS "紐づけ強度「RELAXED」の割合", 
    ROUND(100.0 * SUM(CASE WHEN NULLIF(y.match_strength, '') = 'INCLUSIVE' THEN 1 ELSE 0 END) OVER () / NULLIF(COUNT(*) OVER (), 0), 4) AS "紐づけ強度「INCLUSIVE」の割合", 
    ROUND(100.0 * SUM(CASE WHEN NULLIF(y.match_strength, '') = 'GENERIC' THEN 1 ELSE 0 END) OVER () / NULLIF(COUNT(*) OVER (), 0), 4) AS "紐づけ強度「GENERIC」の割合", 
    ROUND(100.0 * SUM(CASE WHEN NULLIF(y.match_strength, '') = 'POTENTIAL' THEN 1 ELSE 0 END) OVER () / NULLIF(COUNT(*) OVER (), 0), 4) AS "紐づけ強度「POTENTIAL」の割合", 
    ROUND(100.0 * SUM(CASE WHEN NULLIF(y.match_strength, '') IS NULL THEN 1 ELSE 0 END) OVER () / NULLIF(COUNT(*) OVER (), 0), 4) AS "紐づけ強度「UNMATCHED」の割合" 

FROM
    base_order_dummy_table z   
LEFT JOIN
    final_resolved_pairs y ON z.order_id = y.dummy_ship_order_id
ORDER BY 
    z.ship_date DESC
;
