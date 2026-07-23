/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 実発送なしデータのオーバーライドおよびフラグ修復マスタ
  Dummy Shipment Override & Flag Restoration (Intermediate Layer)

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. データ欠損の多段フォールバック修復 (Multi-Tier Data Restoration)
     前工程（stg_no_real_ship_matching）で特定したペア情報を用い、旧システム（Legacy）起因で
     「返品時に欠損した（0円になった）金額や数量」に対して、対となるダミー出荷が持つ
     正しい実績値（数量・金額・支払方法・入金済フラグ等）をウィンドウ関数（Window Functions）で
     安全に伝播・上書き（Override）します。
     ★【重要】元注文とダミー注文間で「商品の分裂・合算・ID変更」が発生した場合に備え、以下の3段構えのルートで修復します。
       ① 通常ルート: 商品ID＋枝番 が完全一致する場合 (1-to-1 Exact Match)
       ② 分裂ルート: ダミー側で明細が分裂した場合、カテゴリ単位で合算した値を適用 (Category-Level Rollup)
       ③ ID違いルート: 明細数は同じだが商品IDが変わった場合、カテゴリ内の連番でお見合い適用 (Category-Sequential Match)
  2. ステータスの継承 (Status Inheritance)
     形式的返品レコードに対し、対になるダミー出荷の最終ステータス（入金済か、本当に返品されたか等）
     を継承させ、ビジネス実態に基づいた正しい「入金済フラグ」「返品フラグ」を再構築します。
     ★【追加】ダミー側が単品で登録された場合でも、元注文の「定期属性（is_subsc）」を復元・継承します。
  3. フェイルセーフ除外 (Fail-safe Exclusion)
     役割を終えたダミー出荷レコードを売上二重計上防止のために除外します。ただし、
     紐付けエラーとなったダミー出荷は売上消失防止のため、あえて残す安全制御を行います。
  4. みなし配達完了の補正 (Deemed Delivery Completion)
     代引き・後払い等「入金実績が商品到着の証左となる」決済方法において、入金済かつ
     出荷完了（物理配送の追跡がダミー出荷対応により途切れている）状態のまま止まっている
     レコードを、ビジネス実態に基づき「配達完了」へ強制補正します。

  1. Multi-Tier Data Restoration
     Safely restores missing financial/quantity data in legacy returns by propagating actual values
     from paired dummy shipments. Implements a 3-tier fallback architecture (Exact Match,
     Category Rollup, and Category-Sequential Match) to handle extreme edge cases where items
     are split, merged, or substituted across original and dummy orders.
  2. Status Inheritance
     Formal returns inherit the final business status (e.g., payment received, actual return)
     from their paired dummy shipments. Added logic also rescues missing subscription attributes.
  3. Fail-safe Exclusion
     Matched dummy shipments are excluded to prevent double-counting, while unmatched ones
     are intentionally retained as a fail-safe against revenue loss.
  4. Deemed Delivery Completion
     For payment methods where a confirmed payment is itself evidence of goods received
     (e.g., COD, postpay), records stuck at "shipped" status due to the dummy-shipment
     workaround (which breaks physical delivery tracking) are force-corrected to "delivered"
     based on business reality.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
このクエリは以下の処理ステップで構成されています。
This query consists of the following processing layers.

  1. base_order_table
     元データの取得と、修復用の各種キー（お見合い用連番、明細数など）を準備
     Retrieval of base order data prior to dummy shipment processing.

  2. dummy_pairs_info
     ペア情報の取得と信頼度フィルタリング
     Retrieval of matched pairs filtered by reliability threshold.

  3. dummy_pairs_expanded
     ペア情報の縦展開（JOIN用共通キーの生成）
     Vertical expansion of pair information to create a common join key.

  4. window_values
     ダミー側の値をグループ内に伝播。通常/分裂/ID違いの各ルート用集計値を生成
     Propagation of dummy shipment actuals within the matched group via Window Functions.

  5. override_base_data
     状態（一致・分裂）に応じた最適なルートの値をフォールバックで選択し上書き
     Restoration of missing legacy data through value overriding.

  6. apply_deemed_delivery
     決済方法と入金実績をエビデンスとした「みなし配達完了」ステータスの補正
     Correction of order status to "delivered" based on payment method and payment confirmation.

  7. Final Output
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
        
        -- ① 通常ルート用キー: 商品IDと枝番の順序
        ROW_NUMBER() OVER(PARTITION BY order_id ORDER BY product_id ASC, line_no ASC) AS line_no_pairs,
        
        -- ② ID違いルート用キー: カテゴリ単位の連番（お見合い用）
        ROW_NUMBER() OVER(PARTITION BY order_id, product_analysis_category_level_5 ORDER BY line_no ASC) AS cate_line_no_pairs,
        
        -- ③ 分裂ルート用キー: 注文内のコア商品（RG/TR）明細数
        SUM(CASE WHEN product_external_id4 IN ('RG', 'TR') THEN 1 ELSE 0 END) OVER(PARTITION BY order_id) AS order_count,
        
        product_id, 
        product_name, 
        product_external_id4, 
        product_analysis_category_level_5,
        product_analysis_category_level_6,
        
        order_type, 
        order_status,
        order_status_numbr, 
        payment_method,
        is_payment_received,
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
-- 4. [Value Propagation] ウィンドウ関数を用いた多段修復値の生成・伝播
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
window_values AS (
    SELECT
        *,
        MAX(CASE WHEN is_no_real_ship = 1 THEN payment_method END) OVER(PARTITION BY group_order_id) AS max_payment_method,
        MAX(CASE WHEN is_no_real_ship = 1 THEN is_payment_received END) OVER(PARTITION BY group_order_id) AS max_is_payment_received,
        
        -- ★定期フラグの救済（完全一致ベース）
        CASE
            WHEN COALESCE(MAX(CASE WHEN is_no_real_ship = 1 THEN is_subsc END) OVER(PARTITION BY group_order_id, line_no_pairs, product_id), 0) <> 1
             AND MAX(CASE WHEN is_no_real_ship <> 1 THEN is_subsc END) OVER(PARTITION BY group_order_id, line_no_pairs, product_id) = 1 THEN 1
            ELSE COALESCE(MAX(CASE WHEN is_no_real_ship = 1 THEN is_subsc END) OVER(PARTITION BY group_order_id, line_no_pairs, product_id), 0)
        END AS max_is_subsc,
        
        -- ★定期フラグの救済（カテゴリ一致ベース：ID違い用）
        CASE
            WHEN COALESCE(MAX(CASE WHEN is_no_real_ship = 1 THEN is_subsc END) OVER(PARTITION BY group_order_id, product_analysis_category_level_5), 0) <> 1
             AND MAX(CASE WHEN is_no_real_ship <> 1 THEN is_subsc END) OVER(PARTITION BY group_order_id, product_analysis_category_level_5) = 1 THEN 1
            ELSE COALESCE(MAX(CASE WHEN is_no_real_ship = 1 THEN is_subsc END) OVER(PARTITION BY group_order_id, product_analysis_category_level_5), 0)
        END AS max_is_subsc_cate,
        
        -- ★定期IDの救済：ダミー側(=1)がNULLなら、元出荷(<>1)側の値を伝播
        COALESCE(
            NULLIF(MAX(CASE WHEN is_no_real_ship = 1 THEN subsc_id END) OVER(PARTITION BY group_order_id), ''), 
            MAX(CASE WHEN is_no_real_ship <> 1 THEN subsc_id END) OVER(PARTITION BY group_order_id)
        ) AS max_subsc_id,
        
        -- Route ①: 通常ルート用の伝播値 (Exact Match)
        MAX(CASE WHEN is_no_real_ship = 1 THEN quantity END) OVER(PARTITION BY group_order_id, line_no_pairs, product_id) AS max_quantity,
        MAX(CASE WHEN is_no_real_ship = 1 THEN total_payment_amount END) OVER(PARTITION BY group_order_id) AS max_total_payment_amount,
        MAX(CASE WHEN is_no_real_ship = 1 THEN discounted_amount_excl_point_excl_tax END) OVER(PARTITION BY group_order_id, line_no_pairs, product_id) AS max_discounted_amount_excl_point_excl_tax,
        MAX(CASE WHEN is_no_real_ship = 1 THEN validated_discounted_incl_point_excl_tax END) OVER(PARTITION BY group_order_id, line_no_pairs, product_id) AS max_validated_discounted_incl_point_excl_tax,
        
        -- Route ②: 分裂ルート用の伝播値 (Category Rollup)
        SUM(CASE WHEN is_no_real_ship = 1 THEN quantity END) OVER(PARTITION BY group_order_id, product_analysis_category_level_5) AS sum_quantity_cate,
        SUM(CASE WHEN is_no_real_ship = 1 THEN discounted_amount_excl_point_excl_tax END) OVER(PARTITION BY group_order_id, product_analysis_category_level_5) AS sum_discounted_amount_excl_point_excl_tax_cate,
        SUM(CASE WHEN is_no_real_ship = 1 THEN validated_discounted_incl_point_excl_tax END) OVER(PARTITION BY group_order_id, product_analysis_category_level_5) AS sum_validated_discounted_incl_point_excl_tax_cate,
        
        -- Route ③: ID違いルート用の伝播値 (Category-Sequential Match)
        MAX(CASE WHEN is_no_real_ship = 1 THEN quantity END) OVER(PARTITION BY group_order_id, cate_line_no_pairs, product_analysis_category_level_5) AS match_quantity_cate,
        MAX(CASE WHEN is_no_real_ship = 1 THEN discounted_amount_excl_point_excl_tax END) OVER(PARTITION BY group_order_id, cate_line_no_pairs, product_analysis_category_level_5) AS match_discounted_amount_excl_point_excl_tax_cate,
        MAX(CASE WHEN is_no_real_ship = 1 THEN validated_discounted_incl_point_excl_tax END) OVER(PARTITION BY group_order_id, cate_line_no_pairs, product_analysis_category_level_5) AS match_validated_discounted_incl_point_excl_tax_cate,
        
        -- 分裂判定フラグ
        CASE WHEN MAX(order_count_base) OVER(PARTITION BY group_order_id) = MAX(order_count_pair) OVER(PARTITION BY group_order_id) THEN 1 ELSE 0 END AS is_order_count_same,
        CASE WHEN MAX(order_count_base) OVER(PARTITION BY group_order_id) < MAX(order_count_pair) OVER(PARTITION BY group_order_id) THEN 1 ELSE 0 END AS is_order_count_mismatch

    FROM (
        SELECT
            base.*,
            pair.fake_return_order_id AS paired_return_id,
            COALESCE(pair.fake_return_order_id, base.order_id) AS group_order_id, 
            pair.match_strength,
            COALESCE(pair.is_match, 0) AS is_match,
            CASE WHEN base.order_id = pair.fake_return_order_id THEN order_count ELSE 0 END AS order_count_base,
            CASE WHEN base.order_id <> pair.fake_return_order_id THEN order_count ELSE 0 END AS order_count_pair,
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
-- 5. [Data Override] レガシー形式データの修復（フォールバック選択）
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
        CASE WHEN is_match = 1 THEN max_is_payment_received ELSE is_payment_received END AS is_payment_received_override,
        
        -- 定期フラグ補正 (ID違いも考慮した二段構え)
        CASE 
            WHEN is_match = 1 AND max_is_subsc <> 1 AND max_is_subsc_cate = 1 AND product_external_id4 = 'RG' THEN max_is_subsc_cate
            WHEN is_match = 1 THEN max_is_subsc
            ELSE is_subsc 
        END AS is_subsc_override,
        CASE WHEN is_match = 1 THEN max_subsc_id ELSE subsc_id END AS subsc_id_override,

        -- Quantity & Financial Overrides 
        -- 一般化対応: プレフィックス 'L' (Legacy) に変更
        CASE 
            WHEN is_match = 1 AND order_id_prefix = 'LEGACY_SYSTEM_PREFIX' AND match_strength IN ('INCLUSIVE','GENERIC') AND max_quantity IS NOT NULL THEN max_quantity
            WHEN is_match = 1 AND max_quantity IS NULL AND is_order_count_mismatch = 1 THEN sum_quantity_cate
            WHEN is_match = 1 AND max_quantity IS NULL AND is_order_count_same = 1 THEN match_quantity_cate
            ELSE quantity 
        END AS quantity_override,
        
        CASE WHEN is_match = 1 AND order_id_prefix = 'LEGACY_SYSTEM_PREFIX' AND match_strength IN ('INCLUSIVE','GENERIC') THEN max_total_payment_amount ELSE total_payment_amount END AS total_payment_amount_override,
        
        CASE 
            WHEN is_match = 1 AND order_id_prefix = 'LEGACY_SYSTEM_PREFIX' AND match_strength IN ('INCLUSIVE','GENERIC') AND max_discounted_amount_excl_point_excl_tax IS NOT NULL THEN max_discounted_amount_excl_point_excl_tax
            WHEN is_match = 1 AND max_discounted_amount_excl_point_excl_tax IS NULL AND is_order_count_mismatch = 1 THEN sum_discounted_amount_excl_point_excl_tax_cate
            WHEN is_match = 1 AND max_discounted_amount_excl_point_excl_tax IS NULL AND is_order_count_same = 1 THEN match_discounted_amount_excl_point_excl_tax_cate
            ELSE discounted_amount_excl_point_excl_tax 
        END AS discounted_amount_excl_point_excl_tax_override,
        
        CASE 
            WHEN is_match = 1 AND order_id_prefix = 'LEGACY_SYSTEM_PREFIX' AND match_strength IN ('INCLUSIVE','GENERIC') AND max_validated_discounted_incl_point_excl_tax IS NOT NULL THEN max_validated_discounted_incl_point_excl_tax
            WHEN is_match = 1 AND max_validated_discounted_incl_point_excl_tax IS NULL AND is_order_count_mismatch = 1 THEN sum_validated_discounted_incl_point_excl_tax_cate
            WHEN is_match = 1 AND max_validated_discounted_incl_point_excl_tax IS NULL AND is_order_count_same = 1 THEN match_validated_discounted_incl_point_excl_tax_cate
            ELSE validated_discounted_incl_point_excl_tax 
        END AS validated_discounted_incl_point_excl_tax_override

    FROM
        window_values
),

----------------------------------------------------------------------
-- 6. [Deemed Delivery] みなし配達完了の補正
--    ダミー出荷対応により物理配送の追跡が途切れ、「出荷完了」で止まっているレコードのうち、
--    入金実績（COD/後払い等）がビジネス上の受取確認として十分な場合、配達完了へ補正する。
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
apply_deemed_delivery AS (
    SELECT
        *,
        CASE
            -- 入金＝受取確認となる決済方法において、入金済かつ「出荷完了」で止まっている場合
            WHEN payment_method_override IN ('CARRIER_BILLING', 'POSTPAY', 'COD', 'DIGITAL_WALLET')
             AND is_payment_received_override = 1
             AND order_status_numbr = 5  -- 出荷完了 (SHP_COMP) のみ対象
             AND (
                    -- Pattern (1): 実発送なし かつ 紐付け失敗（相方のいないダミー）
                    (is_no_real_ship = 1 AND is_match <> 1)
                 OR
                    -- Pattern (2): 実発送なしではない かつ 紐付け成功（ダミー返品された元受注）
                    (is_no_real_ship <> 1 AND is_match = 1)
                 )
                THEN 6 -- 6 = 配達完了 (DLV_COMP)
            ELSE order_status_numbr
        END AS order_status_numbr_deemed,

        CASE
            WHEN payment_method_override IN ('CARRIER_BILLING', 'POSTPAY', 'COD', 'DIGITAL_WALLET')
             AND is_payment_received_override = 1
             AND order_status_numbr = 5
             AND (
                    (is_no_real_ship = 1 AND is_match <> 1)
                 OR
                    (is_no_real_ship <> 1 AND is_match = 1)
                 )
                THEN 'DLV_COMP'
            ELSE order_status
        END AS order_status_deemed

    FROM
        override_base_data
)

----------------------------------------------------------------------
-- 7. [Final Output] フラグ継承とフェイルセーフ適用
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
    order_status_deemed                      AS "注文ステータス",   -- 上書き済（みなし配達完了 補正後）
    order_status_numbr_deemed                AS "受注明細状態",     -- 上書き済（みなし配達完了 補正後）
    payment_method_override                  AS "支払方法",
    is_payment_received_override             AS "入金済フラグ",
    member_rank_at_order                     AS "注文時会員ランク",
    latest_ad_code                           AS "受注プロモ",
    operator_code                            AS "受付者コード",
    is_ec_order_without_promo_code           AS "[プロモ空欄かつ経路EC]フラグ",
    is_no_real_ship                          AS "実発送なしフラグ",
    is_match                                 AS "紐づけ成功フラグ",

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
    is_subsc_override                        AS "定期フラグ",
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
    apply_deemed_delivery

WHERE
    -- [Fail-safe Exclusion]
    -- 紐付け成功したダミー出荷のみを除外。エラーになったダミーは売上消失防止のため残す。
    NOT (is_no_real_ship = 1 AND order_id <> COALESCE(paired_return_id, '') AND COALESCE(is_match, 0) = 1)
;
