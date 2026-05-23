/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 実発送なしデータのオーバーライドおよびフラグ修復マスタ
  Dummy Shipment Override & Flag Restoration (Intermediate Layer)

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. データ欠損の修復 (Data Restoration)
     前工程（stg_no_real_ship_matching）で特定したペア情報を用い、旧システム（Legacy）起因で
     「返品時に欠損した（0円になった）金額や数量」に対して、対となるダミー出荷が持つ
     正しい実績値をウィンドウ関数（Window Functions）で安全に伝播・上書き（Override）します。
  2. ステータスの継承 (Status Inheritance)
     形式的返品レコードに対し、対になるダミー出荷の最終ステータス（本当に返品されたか等）
     を継承させ、ビジネス実態に基づいた正しい「返品フラグ」を再構築します。
  3. フェイルセーフ除外 (Fail-safe Exclusion)
     役割を終えたダミー出荷レコードを売上二重計上防止のために除外します。ただし、
     紐付けエラーとなったダミー出荷は売上消失防止のためあえて残す安全制御を行います。

  1. Data Restoration
     Using pair information from the previous matching stage, missing financial and quantity data 
     in legacy return records are safely overridden by propagating the correct actual values 
     from the paired dummy shipments via Window Functions.
  2. Status Inheritance
     Formal return records inherit the final status of their paired dummy shipments, 
     reconstructing accurate "Return Flags" based on actual business outcomes.
  3. Fail-safe Exclusion
     Matched dummy shipment records are excluded to prevent double-counting revenue. 
     However, unmatched dummy shipments are intentionally retained as a fail-safe to prevent revenue loss.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
このクエリは以下の処理ステップで構成されています。
This query consists of the following processing layers.

  1. base_order_table
     元データの取得（実発送なし対応前のベースデータ）
     Retrieval of base order data prior to dummy shipment processing.

  2. dummy_pairs_info
     ペア情報の取得と信頼度フィルタリング
     Retrieval of matched pairs filtered by reliability threshold.

  3. dummy_pairs_expanded
     ペア情報の縦展開（JOIN用共通キーの生成）
     Vertical expansion of pair information to create a common join key.

  4. window_values
     ウィンドウ関数を用いたダミー出荷実績値のグループ内伝播
     Propagation of dummy shipment actuals within the matched group via Window Functions.

  5. override_base_data
     旧形式データの欠損修復（金額・数量等のオーバーライド）
     Restoration of missing legacy data through value overriding.

  6. Final Output
     返品フラグの継承、派生フラグの生成、およびフェイルセーフ除外の適用
     Inheritance of return flags, generation of derived flags, and application of fail-safe exclusion.

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  Order Line Item (受注明細単位)

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  user_id, order_id, line_no

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (BigQuery / Snowflake / Redshift compatible)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 実発送なし・フラグ修復済 中間テーブル
  int_order_dummy_override_master
==============================================================================================
*/

WITH 
----------------------------------------------------------------------
-- 1. [Base Data] 基本データの取得と紐付けキーの生成
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
base_order_table AS (
    SELECT
        user_id, 
        order_id,
        LEFT(order_id, 1) AS order_id_prefix,
        line_no, 
        
        -- Generate internal matching key (row number by product)
        ROW_NUMBER() OVER(PARTITION BY order_id ORDER BY product_id ASC, line_no ASC) AS line_no_pairs,
        
        product_id, 
        product_name, 
        product_external_id4, 
        product_analysis_category_level_5,
        product_analysis_category_level_6,
        
        order_type, 
        order_status,
        order_status_numbr, 
        payment_method,
        member_rank_at_order,
        latest_ad_code, 
        operator_code,
        is_ec_order_without_promo_code,
        is_no_real_ship, 
        
        ordered_at,
        ordered_date,
        ordered_month,
        shipment_date,
        shipment_month,
        delivered_date,
        
        quantity,
        total_payment_amount, 
        discounted_amount_excl_point_excl_tax, 
        validated_discounted_incl_point_excl_tax,
        
        is_subsc,
        subsc_id,
        subsc_cycle_at_order,
        subsc_cycle_at_shipment,
        
        is_biz_cnsl,
        is_biz_return,
        is_sys_cnsl,
        is_sys_return,
        is_refund_eligible, 
        return_completed_date,
        return_reason_note

    FROM 
        stg_all_purchases_base -- 【前工程】全購入基本データ (05_fct_all_purchases_unified)
),

----------------------------------------------------------------------
-- 2. [Matched Pairs] 紐付け情報の取得と信頼度フィルタリング
--    Data Grain: dummy_ship_order_id
----------------------------------------------------------------------
dummy_pairs_info AS (
    SELECT
        order_id AS dummy_ship_order_id,
        fake_return_order_id,
        is_biz_return,
        is_sys_return,
        return_completed_date,
        return_reason_note,
        is_match,
        match_strength
    FROM
        stg_no_real_ship_matching -- 【前工程】実発送なし紐づけ処理 (01_stg_no_real_ship_matching)
    WHERE
        match_score >= 30  -- 信頼度閾値 (Reliability threshold)
),

----------------------------------------------------------------------
-- 3. [Pairs Expansion] 結合用キーの縦展開 (Unpivoting for JOIN)
--    Data Grain: join_order_id
----------------------------------------------------------------------
dummy_pairs_expanded AS (
    SELECT dummy_ship_order_id AS join_order_id, fake_return_order_id, is_biz_return, is_sys_return, return_completed_date, return_reason_note, is_match, match_strength
    FROM dummy_pairs_info
    UNION ALL
    SELECT fake_return_order_id AS join_order_id, fake_return_order_id, is_biz_return, is_sys_return, return_completed_date, return_reason_note, is_match, match_strength
    FROM dummy_pairs_info
),

----------------------------------------------------------------------
-- 4. [Value Propagation] ウィンドウ関数を用いたダミー情報のグループ内伝播
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
window_values AS (
    SELECT
        *,
        -- Propagate values from Dummy to Return within the same group
        MAX(CASE WHEN is_no_real_ship = 1 THEN payment_method END) OVER(PARTITION BY group_order_id) AS max_payment_method,
        MAX(CASE WHEN is_no_real_ship = 1 THEN subsc_id END) OVER(PARTITION BY group_order_id) AS max_subsc_id,
        MAX(CASE WHEN is_no_real_ship = 1 THEN quantity END) OVER(PARTITION BY group_order_id, line_no_pairs, product_id) AS max_quantity,
        MAX(CASE WHEN is_no_real_ship = 1 THEN total_payment_amount END) OVER(PARTITION BY group_order_id) AS max_total_payment_amount,
        MAX(CASE WHEN is_no_real_ship = 1 THEN discounted_amount_excl_point_excl_tax END) OVER(PARTITION BY group_order_id, line_no_pairs, product_id) AS max_discounted_amount_excl_point_excl_tax,
        MAX(CASE WHEN is_no_real_ship = 1 THEN validated_discounted_incl_point_excl_tax END) OVER(PARTITION BY group_order_id, line_no_pairs, product_id) AS max_validated_discounted_incl_point_excl_tax

    FROM (
        SELECT
            base.*,
            pair.fake_return_order_id AS paired_return_id,
            COALESCE(pair.fake_return_order_id, base.order_id) AS group_order_id, 
            pair.match_strength,
            COALESCE(pair.is_match, 0) AS is_match,
            COALESCE(pair.is_biz_return, 0) AS pair_biz_return,
            COALESCE(pair.is_sys_return, 0) AS pair_sys_return,
            pair.return_completed_date AS pair_return_completed_date,
            NULLIF(pair.return_reason_note, '') AS pair_return_reason_note
        FROM
            base_order_table base
        LEFT JOIN
            dummy_pairs_expanded pair ON base.order_id = pair.join_order_id
    )
),

----------------------------------------------------------------------
-- 5. [Data Override] 旧形式データの修復（オーバーライド）
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
override_base_data AS (
    SELECT
        *,
        -- Payment & Subsc ID Overrides
        -- 一般化対応: 決済手段変更(例.後払い等)に伴う再出荷レコードを判定する汎用コードに変更
        CASE 
            WHEN is_match = 1 AND max_payment_method IN ('CREDIT_CARD', 'CREDIT_CARD_UNKNOWN', 'CARRIER_BILLING', 'POSTPAY') 
            THEN max_payment_method 
            ELSE payment_method 
        END AS payment_method_override,

        CASE WHEN is_match = 1 THEN max_subsc_id ELSE subsc_id END AS subsc_id_override,

        -- Quantity & Financial Overrides 
        -- 一般化対応: プレフィックス 'L' (Legacy) に変更
        CASE WHEN is_match = 1 AND order_id_prefix = 'L' AND match_strength IN ('INCLUSIVE','GENERIC') THEN max_quantity ELSE quantity END AS quantity_override,
        CASE WHEN is_match = 1 AND order_id_prefix = 'L' AND match_strength IN ('INCLUSIVE','GENERIC') THEN max_total_payment_amount ELSE total_payment_amount END AS total_payment_amount_override,
        CASE WHEN is_match = 1 AND order_id_prefix = 'L' AND match_strength IN ('INCLUSIVE','GENERIC') THEN max_discounted_amount_excl_point_excl_tax ELSE discounted_amount_excl_point_excl_tax END AS discounted_amount_excl_point_excl_tax_override,
        CASE WHEN is_match = 1 AND order_id_prefix = 'L' AND match_strength IN ('INCLUSIVE','GENERIC') THEN max_validated_discounted_incl_point_excl_tax ELSE validated_discounted_incl_point_excl_tax END AS validated_discounted_incl_point_excl_tax_override

    FROM
        window_values
)

----------------------------------------------------------------------
-- 6. [Final Output] フラグ継承とフェイルセーフ適用
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
SELECT
    -- ====== IDs ======
    user_id                                  AS "ユーザーID", 
    order_id                                 AS "注文ID", 
    line_no                                  AS "注文商品枝番", 

    -- ====== Product Info ======
    product_id                               AS "商品ID", 
    product_name                             AS "商品名", 
    product_external_id4                     AS "商品連携ID4", 
    product_analysis_category_level_5        AS "分析用分類【第5階層】",
    product_analysis_category_level_6        AS "分析用分類【第6階層】",

    -- ====== Order Info ======
    order_type                               AS "受注経路", 
    order_status                             AS "注文ステータス",
    order_status_numbr                       AS "受注明細状態", 
    payment_method_override                  AS "支払方法", 
    member_rank_at_order                     AS "注文時会員ランク",
    latest_ad_code                           AS "受注プロモ", 
    operator_code                            AS "受付者コード",
    is_ec_order_without_promo_code           AS "[プロモ空欄かつ経路EC]フラグ",

    -- ====== Dates ======
    ordered_at                               AS "受注日時",
    ordered_date                             AS "受注日",
    ordered_month                            AS "受注年月",
    shipment_date                            AS "出荷日",
    shipment_month                           AS "出荷年月",
    delivered_date                           AS "配達完了日",

    -- ====== Quantities & Financials (Overridden) ======
    COALESCE(quantity_override, quantity)                                                                 AS "注文数",
    COALESCE(total_payment_amount_override, total_payment_amount)                                         AS "支払合計金額 (税込)", 
    COALESCE(discounted_amount_excl_point_excl_tax_override, discounted_amount_excl_point_excl_tax)       AS "P使用前_割引後金額 (税抜)", 
    COALESCE(validated_discounted_incl_point_excl_tax_override, validated_discounted_incl_point_excl_tax) AS "P使用後_割引後金額 (税抜)",

    -- ====== Subscription ======
    is_subsc                                 AS "定期フラグ",
    subsc_id_override                        AS "定期購入ID",
    subsc_cycle_at_order                     AS "定期購入回（注文時点）",
    subsc_cycle_at_shipment                  AS "定期購入回（出荷時点）",

    -- ====== Returns & Derived Flags ======
    is_biz_cnsl                              AS "CNSLフラグ",

    -- Status Inheritance (フラグの実態継承)
    CASE
        WHEN order_id = paired_return_id AND COALESCE(is_match,0) = 1 THEN pair_biz_return
        ELSE is_biz_return
    END                                      AS "返品フラグ",
    is_sys_cnsl                              AS "CNSLフラグ_システム基準",
    CASE
        WHEN order_id = paired_return_id AND COALESCE(is_match,0) = 1 THEN pair_sys_return
        ELSE is_sys_return
    END                                      AS "返品フラグ_システム基準",

    -- Fake Return Flag
    CASE
        WHEN order_id = paired_return_id AND COALESCE(is_match,0) = 1 THEN 1
        ELSE 0
    END                                      AS "ダミー返品フラグ",

    -- Pure Return Calculation (保証キャンペーン除く)
    CASE 
        WHEN
            (
              CASE
                WHEN order_id = paired_return_id AND COALESCE(is_match,0) = 1 THEN pair_biz_return
                ELSE is_biz_return END
            ) = 1 
         AND is_refund_eligible <> 1 THEN 1
        ELSE 0
    END                                      AS "返品_返金保証除く_フラグ", 

    is_refund_eligible                       AS "全額返金フラグ", 
    CASE
        WHEN order_id = paired_return_id AND COALESCE(is_match,0) = 1 THEN pair_return_completed_date
        ELSE return_completed_date
    END AS "返品受付日",
    CASE
        WHEN order_id = paired_return_id AND COALESCE(is_match,0) = 1 THEN pair_return_reason_note
        ELSE return_reason_note
    END AS "返品理由"

FROM
    override_base_data

WHERE 
    -- [Fail-safe Exclusion]
    -- 紐付け成功したダミー出荷のみを除外。エラーになったダミーは売上消失防止のため残す。
    NOT (is_no_real_ship = 1 AND order_id <> COALESCE(paired_return_id, '') AND COALESCE(is_match, 0) = 1)
;
