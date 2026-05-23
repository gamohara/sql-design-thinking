/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 商品・媒体・顧客ディメンション統合マスタ
  Product, Media & Customer Dimension Enrichment (Staging Layer)

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. 広告LPのSCD (Slowly Changing Dimension) 対応
     プロモコードの更新履歴（FV更新等）と注文日時を比較し、顧客が購入時に
     「改修前・改修後」どちらの広告を見たのかを正確に判定・紐付けします。
  2. 顧客ライフサイクルの計算と防御的フラグ付与
     DENSE_RANK関数を用いて顧客ごとの正確な「累計購入回数（F1, F2...）」を算出。
     さらに、顧客マスタに存在しない（結合エラーとなる）幽霊顧客には、
     誤配信防止のため強制的に「削除フラグ」を付与（フェイルセーフ）します。
  3. 各種キャンペーンフラグの拡張
     外部CSV（新規コード管理表）から、全額返金保証や特定ブランドの
     キャンペーンフラグを結合し、施策ごとのLTV・引き上げ率分析を可能にします。

  1. SCD Type 2 Handling for Ad LPs
     By comparing order timestamps with promo code update logs, the query accurately 
     determines whether a customer purchased through the "Pre-update" or "Post-update" LP.
  2. Customer Lifecycle Calculation & Defensive Flagging
     Calculates exact cumulative purchase counts (F1, F2) using the DENSE_RANK function.
     Additionally, applies a fail-safe "deleted flag" to ghost users missing from the 
     customer master to prevent erroneous CRM mailings.
  3. Campaign Flag Enrichment
     Integrates external CSVs to attach various campaign flags (e.g., Money-back Guarantees), 
     enabling granular LTV and conversion rate analytics per marketing initiative.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
このクエリは以下の処理ステップで構成されています。
This query consists of the following processing layers.

  1. base_order_table
     前工程の受注ファクトデータの取得
     Retrieval of the base order fact table from the previous step.

  2-6. master_tables (Products, Media, Promo History, Customers, Campaigns)
     各種ディメンション（次元）マスタおよび補正用CSVデータの取得と整理
     Retrieval and preparation of various dimension masters and external CSV files.

  7. promo_version_evaluation
     注文タイミングに基づくプロモ新旧バージョンの判定（SCD処理）
     Evaluation of promo code versions based on order timing (SCD processing).

  8. dimension_integration
     全マスタの横断結合（エンリッチメント）および幽霊顧客のフェイルセーフ処理
     Integration of all dimensions (Enrichment) and fail-safe handling for missing customers.

  9. Final Output
     BIツール向けディメンション整形と、分析用指標（F1/F2回数）の算出出力
     Formatting dimensions for BI tools and calculating analytics metrics (e.g., F1/F2 counts).

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
 商品・媒体情報エンリッチメント済 ステージングテーブル
  stg_product_media_enrichment_master
==============================================================================================
*/

WITH 
----------------------------------------------------------------------
-- 1. [Base Fact] 基本受注データの取得
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
base_order_table AS (
    SELECT
        user_id, order_id, line_no, 
        product_id, product_name, product_external_id4, product_analysis_category_level_5, product_analysis_category_level_6,
        order_type, order_status, order_status_numbr, payment_method, member_rank_at_order, latest_ad_code, operator_code, is_ec_order_without_promo_code,
        ordered_at, ordered_date, ordered_month, shipment_date, shipment_month, delivered_date,
        quantity, total_payment_amount, discounted_amount_excl_point_excl_tax, validated_discounted_incl_point_excl_tax,
        subsc_flag, subsc_id, subsc_cycle_at_order, subsc_cycle_at_shipment,
        is_biz_cnsl, is_biz_return, is_sys_cnsl, is_sys_return, is_fake_return, is_return_no_refund, is_refund_eligibility, return_completed_date, return_reason_note
    FROM 
        int_order_dummy_override_master -- 【前工程】02_int_no_real_ship_override.sql 相当
),

----------------------------------------------------------------------
-- 2~6. [Dimension Masters] 各種属性マスタの取得
----------------------------------------------------------------------
master_product_table AS (
    -- [2] 商品マスタ (Product Dimensions)
    SELECT
        product_id, product_analysis_category_level_4, product_category, product_subcategory, product_detail
    FROM dim_products
),

media_info_table AS (
    -- [3] 媒体マスタ (Media Dimensions)
    -- ※ is_operational: 0=旧LP, 1=新LP
    SELECT
        promo_code, promo_code_prefix, ad_media_type, media_name, media_cost, 
        promotion_product_type, promotion_product_type_name, campaign_code, campaign_name, 
        lp_name, online_media_category, online_media_subcategory, online_media_detail, offer_name, lp_type,
        media_publish_date_from, media_publish_date_to, created_date,
        has_upsell, has_bot, is_operational, is_agency_a_campaign, is_affiliate_campaign, is_no_path, is_no_email
    FROM dim_media_info
),

promo_code_updated_csv AS (
    -- [4] プロモ更新履歴 (Promo Update History for SCD)
    SELECT promo_code, updated_at
    FROM src_promo_update_history
    WHERE update_type = 'FV更新' -- ファーストビュー更新のみ対象
),

user_table AS (
    -- [5] 顧客マスタ (Customer Dimensions)
    SELECT
        user_id, gender, current_age, customer_acquisition_date,
        is_cus_black, is_cus_deleted_merged, is_cus_merged
    FROM dim_customers
),

csv_product_new_table AS (
    -- [6] 商品キャンペーンフラグ (Campaign Flags from CSV)
    SELECT
        product_id, product_name,
        is_brand_a_first_order, is_brand_b_first_order, is_brand_c_first_order, is_brand_d_first_order,
        is_first_subsc_3, is_subsc_upgraded_from_1_to_2, is_subsc_upgraded_from_1_to_3, is_digital_gift_campaign,
        is_money_back_guarantee, is_subsc_cancel_rule, is_no_email_lp_order, is_first_novelty_a_pre, is_first_novelty_b_pre
    FROM src_product_campaign_flags
),

----------------------------------------------------------------------
-- 7. [SCD Processing] 注文タイミングによるLP新旧の判定
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
promo_version_evaluation AS (
    SELECT
        a.*,
        -- Evaluate whether the order was placed before or after the promo update
        CASE 
           WHEN b.updated_at IS NULL THEN 0             -- 更新履歴なしは「0（旧/通常）」
           WHEN a.ordered_at >= b.updated_at THEN 1     -- 更新以降の注文は「1（新LP）」
           ELSE 0                                       -- 更新より前は「0（旧LP）」
        END AS is_promo_status
    FROM 
        base_order_table a
    LEFT JOIN 
        promo_code_updated_csv b ON a.latest_ad_code = b.promo_code 
),

----------------------------------------------------------------------
-- 8. [Enrichment] 商品・媒体・顧客情報の統合とフェイルセーフ
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
dimension_integration AS (
    SELECT
        c.*,
        
        -- Products
        d.product_analysis_category_level_4, d.product_category, d.product_subcategory, d.product_detail,
        
        -- Campaign Flags
        COALESCE(g.is_brand_a_first_order, 0) AS is_brand_a_first_order, COALESCE(g.is_brand_b_first_order, 0) AS is_brand_b_first_order,
        COALESCE(g.is_brand_c_first_order, 0) AS is_brand_c_first_order, COALESCE(g.is_brand_d_first_order, 0) AS is_brand_d_first_order,
        COALESCE(g.is_first_subsc_3, 0) AS is_first_subsc_3, COALESCE(g.is_subsc_upgraded_from_1_to_2, 0) AS is_subsc_upgraded_from_1_to_2,
        COALESCE(g.is_subsc_upgraded_from_1_to_3, 0) AS is_subsc_upgraded_from_1_to_3, COALESCE(g.is_digital_gift_campaign, 0) AS is_digital_gift_campaign,
        COALESCE(g.is_money_back_guarantee, 0) AS is_money_back_guarantee, COALESCE(g.is_subsc_cancel_rule, 0) AS is_subsc_cancel_rule,
        COALESCE(g.is_no_email_lp_order, 0) AS is_no_email_lp_order, COALESCE(g.is_first_novelty_a_pre, 0) AS is_first_novelty_a_pre,
        COALESCE(g.is_first_novelty_b_pre, 0) AS is_first_novelty_b_pre,
        
        -- Media
        e.promo_code_prefix, e.ad_media_type, e.media_name, e.media_cost, e.promotion_product_type, e.promotion_product_type_name, 
        e.online_media_category, e.online_media_subcategory, e.online_media_detail, e.offer_name, e.lp_type,
        e.media_publish_date_from,
        COALESCE(e.has_upsell, 0) AS has_upsell, COALESCE(e.has_bot, 0) AS has_bot, COALESCE(e.is_agency_a_campaign, 0) AS is_agency_a_campaign,
        COALESCE(e.is_affiliate_campaign, 0) AS is_affiliate_campaign, COALESCE(e.is_no_path, 0) AS is_no_path, COALESCE(e.is_no_email, 0) AS is_no_email, 

        -- Customers & Fail-safe Logic
        f.customer_acquisition_date,
        COALESCE(f.is_cus_black, 0) AS is_cus_black,
        COALESCE(f.is_cus_merged, 0) AS is_cus_merged,
        
        -- Fail-safe: 顧客マスタに存在しない（NULL）場合は強制的に削除フラグを立てる
        CASE WHEN NULLIF(f.user_id, '') IS NULL OR COALESCE(f.is_cus_deleted_merged, 0) = 1 THEN 1 ELSE 0 END AS is_cus_deleted_merged

    FROM 
        promo_version_evaluation c
    LEFT JOIN master_product_table d ON c.product_id = d.product_id 
    LEFT JOIN media_info_table e ON c.latest_ad_code = e.promo_code AND c.is_promo_status = e.is_operational -- ★プロモ＋新旧フラグの完全一致
    LEFT JOIN user_table f ON c.user_id = f.user_id 
    LEFT JOIN csv_product_new_table g ON c.product_id = g.product_id 
)

----------------------------------------------------------------------
-- 9. [Final Output] 最終出力および分析指標（F1/F2）の算出
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
SELECT
    -- ====== IDs ======
    user_id                                   AS "ユーザーID",
    order_id                                  AS "注文ID",
    
    -- Analytics Metric: Cumulative Purchase Count (F1, F2...)
    DENSE_RANK() OVER(PARTITION BY user_id ORDER BY ordered_at ASC, order_id ASC) AS "注文番号", 
    
    line_no                                   AS "注文商品枝番",
      
    -- ====== Products ======
    product_id                                AS "商品ID",
    product_name                              AS "商品名",
    product_external_id4                      AS "商品連携ID4",
    product_analysis_category_level_4         AS "分析用分類【第4階層】",
    product_analysis_category_level_5         AS "分析用分類【第5階層】",
    product_analysis_category_level_6         AS "分析用分類【第6階層】",
    product_category                          AS "商品大分類",
    product_subcategory                       AS "商品中分類",
    product_detail                            AS "商品小分類",
      
    -- ====== Campaigns (External CSV) ======
    is_brand_a_first_order                    AS "ブランドA_新規フラグ",
    is_brand_b_first_order                    AS "ブランドB_新規フラグ",
    is_brand_c_first_order                    AS "ブランドC_新規フラグ",
    is_brand_d_first_order                    AS "ブランドD_新規フラグ",
    is_first_subsc_3                          AS "初回3本_定期フラグ",
    is_subsc_upgraded_from_1_to_2             AS "初回1本→2本_定期フラグ",
    is_subsc_upgraded_from_1_to_3             AS "初回1本→3本_定期フラグ",
    is_digital_gift_campaign                  AS "デジタルギフトCPフラグ",
    is_money_back_guarantee                   AS "返金保証フラグ",
    is_subsc_cancel_rule                      AS "定期解約フラグ",
    is_no_email_lp_order                      AS "メアドなしフラグ_商品由来",
    is_first_novelty_a_pre                    AS "初回_ノベルティAフラグ",
    is_first_novelty_b_pre                    AS "初回_ノベルティBフラグ",
      
    -- ====== Orders ======
    order_type                                AS "受注経路",
    order_status                              AS "注文ステータス",
    order_status_numbr                        AS "受注明細状態",
    payment_method                            AS "支払方法",
    member_rank_at_order                      AS "注文時会員ランク",
    latest_ad_code                            AS "受注プロモ", 
    promo_code_prefix                         AS "プロモ頭文字",
    operator_code                             AS "受付者コード",
    is_ec_order_without_promo_code            AS "[プロモ空欄かつ経路EC]フラグ",
      
    -- ====== Dates ======
    ordered_at                                AS "受注日時",
    ordered_date                              AS "受注日",
    ordered_month                             AS "受注年月",
    shipment_date                             AS "出荷日",
    shipment_month                            AS "出荷年月",
    delivered_date                            AS "配達完了日",
    media_publish_date_from                   AS "媒体掲載日",
    customer_acquisition_date                 AS "顧客獲得日",
      
    -- ====== Quantities & Financials ======
    quantity                                  AS "注文数",
    total_payment_amount                      AS "支払合計金額 (税込)", 
    discounted_amount_excl_point_excl_tax     AS "P使用前_割引後金額 (税抜)", 
    validated_discounted_incl_point_excl_tax  AS "P使用後_割引後金額 (税抜)",
      
    -- ====== Subscriptions ======
    subsc_flag                                AS "定期フラグ",
    subsc_id                                  AS "定期購入ID",
    subsc_cycle_at_order                      AS "定期購入回（注文時点）",
    subsc_cycle_at_shipment                   AS "定期購入回（出荷時点）",
      
    -- ====== Media ======
    ad_media_type                             AS "広告媒体区分",
    media_name                                AS "媒体名", 
    media_cost                                AS "媒体費", 
    promotion_product_type                    AS "販促商品区分", 
    promotion_product_type_name               AS "販促商品区分名", 
    online_media_category                     AS "オンライン_大分類", 
    online_media_subcategory                  AS "オンライン_中分類", 
    online_media_detail                       AS "オンライン_小分類", 
    offer_name                                AS "オファー内容",
    lp_type                                   AS "LP_設定内容",
    has_upsell                                AS "アップセル有無フラグ",
    has_bot                                   AS "ボット有無フラグ",
    is_agency_a_campaign                      AS "代理店A_CPフラグ",
    is_affiliate_campaign                     AS "アフィリエイト_CPフラグ",
    is_no_path                                AS "パスなしフラグ",
    is_no_email                               AS "メアドなしフラグ",
      
    -- ====== Returns ======
    is_biz_cnsl                               AS "CNSLフラグ",
    is_biz_return                             AS "返品フラグ",
    is_sys_cnsl                               AS "CNSLフラグ_システム基準",
    is_sys_return                             AS "返品フラグ_システム基準",
    is_fake_return                            AS "ダミー返品フラグ",
    is_return_no_refund                       AS "返品_返金保証除く_フラグ", 
    is_refund_eligibility                     AS "全額返金フラグ", 
    return_completed_date                     AS "返品受付日",
    return_reason_note                        AS "返品理由",
      
    -- ====== Customers ======
    is_cus_black                              AS "ブラックフラグ", 
    is_cus_deleted_merged                     AS "削除/統合フラグ", 
    is_cus_merged                             AS "顧客統合フラグ" 

FROM
    dimension_integration
;
