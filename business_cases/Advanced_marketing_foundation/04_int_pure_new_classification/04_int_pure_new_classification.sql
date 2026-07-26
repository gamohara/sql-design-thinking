/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 純新規・リピート回数 厳密判定マスタ
  Pure-New Customer & Repeat Count Classification (Intermediate Layer)

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. コア商品区分への絞り込み
     顧客のLTVや継続率を評価する上でノイズとなる付帯商品を除外し、
     主要商品（RG: 定期 / TR: トライアル）のみを分析対象としてフィルタリング。
  2. 顧客統合（名寄せ）による過去改変の防御
     旧システムから移行した際や、運用で複数の顧客IDが統合（Merge）された場合、
     過去の購入履歴も合算されるため、獲得当時の「純新規」ステータスが失われます。
     これを防ぐため、統合履歴のある顧客については「顧客獲得日の3日前」を起点とし、
     それ以降のトランザクションのみで「購入回数」を再計算します。
  3. 純新規フラグの動的確定
     非統合顧客は「全履歴ベースの1回目」、統合顧客は「獲得日ベースの1回目」を
     動的に使い分けることで、KPI（CPA/CPO等）の集計が過去に遡って変動しない
     イミュータブル（不変）な純新規フラグを生成します。

  1. Core Product Filtering
     Filters out peripheral products to focus solely on core business drivers 
     (e.g., Subscription & Trial products) for accurate LTV and retention analysis.
  2. Protection Against Historical Alteration via Customer Merges
     When duplicate customer IDs are merged, legacy purchase histories are aggregated, 
     often overwriting their historical "Pure-New" status. To prevent this, the query establishes 
     an anchor point ("Customer Acquisition Date - 3 days") for merged users, recalculating 
     their purchase sequence only from that anchor forward.
  3. Dynamic "Pure-New" Flag Determination
     Dynamically applies either the "Full-History" or "Acquisition-Anchored" logic 
     based on the customer's merge status. This guarantees an immutable "Pure-New" flag 
     that prevents historical marketing KPIs (e.g., CPA, CPO) from fluctuating retroactively.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
このクエリは以下の処理ステップで構成されています。
This query consists of the following processing layers.

  1. base_order_table
     主要商品（RG/TR）への絞り込みと、2つの基準（全履歴 / 獲得日考慮）による
     累積購入回数の並行算出。
     Filtering to core products and parallel calculation of cumulative purchase counts 
     using two distinct criteria (Full-History vs. Acquisition-Anchored).

  2. Final Output
     購入回数に基づく純新規フラグの動的評価と、分析用ディメンションとしての最終出力。
     Dynamic evaluation of the Pure-New flag based on purchase counts and 
     final output formatting for BI analytics.

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  Order Line Item (受注明細単位)

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  user_id, order_id, line_no

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: DENSE_RANK, DATEADD, window functions)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 純新規・購入回数判定済 中間テーブル
  int_pure_new_classification_master
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [Base Evaluation] 対象商品の絞り込みと分析指標の準備
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
base_order_table AS (
    SELECT
        -- IDs
        user_id, 
        order_id, 
        
        -- [Criteria A] 全履歴ベースの累計購入回数 (Full-History Rank)
        -- 1注文内に複数商品があっても同じ注文番号になるよう DENSE_RANK を使用
        DENSE_RANK() OVER(
            PARTITION BY user_id
            ORDER BY ordered_at ASC, order_id ASC
        ) AS total_order_no, 

        -- [Criteria B] 獲得日考慮ベースの累計購入回数 (Acquisition-Anchored Rank)
        -- システム連携ラグを考慮し「獲得日-3日」以降の注文の中だけでDENSE_RANKをかける
        CASE 
            WHEN ordered_date >= DATEADD(day, -3, customer_acquisition_date) 
            THEN 
                DENSE_RANK() OVER(
                    PARTITION BY 
                        user_id, 
                        -- Partitioning trick: Separate valid and invalid records
                        CASE WHEN ordered_date >= DATEADD(day, -3, customer_acquisition_date) THEN 1 ELSE 0 END
                    ORDER BY ordered_at ASC, order_id ASC
                )
            ELSE NULL 
        END AS valid_order_no, 
        
        line_no, 
        
        -- Products
        product_id, product_name, product_external_id4, 
        product_analysis_category_level_4, product_analysis_category_level_5, product_analysis_category_level_6,
        product_category, product_subcategory, product_detail,
        
        -- Campaign Flags
        is_brand_a_first_order, is_brand_b_first_order, is_brand_c_first_order,
        is_first_subsc_3, is_subsc_upgraded_from_1_to_2, is_subsc_upgraded_from_1_to_3,
        is_digital_gift_campaign, is_money_back_guarantee, is_subsc_cancel_rule,
        
        -- Orders
        order_type, order_status, order_status_numbr, payment_method, member_rank_at_order,
        latest_ad_code, promo_code_prefix, operator_code, is_ec_order_without_promo_code,
        
        -- Product Mix Evaluation (注文内にRG/TRが含まれるか判定)
        MAX(CASE WHEN product_external_id4 = 'RG' THEN 1 ELSE 0 END) OVER(PARTITION BY order_id) AS is_rg_product, 
        MAX(CASE WHEN product_external_id4 = 'TR' THEN 1 ELSE 0 END) OVER(PARTITION BY order_id) AS is_tr_product, 
        
        -- Dates
        ordered_at, ordered_date, ordered_month, shipment_date, shipment_month, delivered_date,
        media_publish_date_from, customer_acquisition_date,
        
        -- Quantities & Financials
        quantity, total_payment_amount, discounted_amount_excl_point_excl_tax, validated_discounted_incl_point_excl_tax,
        
        -- Subscriptions
        subsc_flag, subsc_id,
        
        -- Media
        ad_media_type, media_name, media_cost, promotion_product_type, promotion_product_type_name, 
        online_media_category, online_media_subcategory, online_media_detail, offer_name, lp_type,
        has_upsell, has_bot, is_agency_a_campaign, is_affiliate_campaign, is_no_path, 
        
        -- Returns
        is_biz_cnsl, is_biz_return, is_sys_cnsl, is_sys_return, is_fake_return, is_return_no_refund, is_refund_eligibility, return_reason_note,
        
        -- Customers
        is_cus_black, is_cus_deleted_merged, is_cus_merged 

    FROM 
        stg_product_media_enrichment_master -- 【前工程】03_stg_product_media_enrichment.sql 相当

    WHERE
        -- 主要商品（RG:定期 / TR:トライアル）のみを分析対象とする
        product_external_id4 IN ('RG','TR')
)

----------------------------------------------------------------------
-- 2. [Final Output] 分析用フラグの確定・出力
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
SELECT
    -- ====== IDs ======
    user_id                                   AS "ユーザーID",
    order_id                                  AS "注文ID",
    line_no                                   AS "注文商品枝番",
    
    total_order_no                            AS "注文番号(全履歴)",
    valid_order_no                            AS "注文番号(分析対象基準)",
    
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
    
    -- ====== Campaigns ======
    is_brand_a_first_order                    AS "ブランドA_新規フラグ",
    is_brand_b_first_order                    AS "ブランドB_新規フラグ",
    is_brand_c_first_order                    AS "ブランドC_新規フラグ",
    is_first_subsc_3                          AS "初回3本_定期フラグ",
    is_subsc_upgraded_from_1_to_2             AS "初回1本→2本_定期フラグ",
    is_subsc_upgraded_from_1_to_3             AS "初回1本→3本_定期フラグ",
    is_digital_gift_campaign                  AS "デジタルギフトCPフラグ",
    is_money_back_guarantee                   AS "返金保証フラグ",
    is_subsc_cancel_rule                      AS "定期解約フラグ",
    
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
    
    -- ====== Behavior Analysis Flags (純新規判定) ======
    CASE WHEN total_order_no = 1 THEN 1 ELSE 0 END AS "純新規フラグ(全履歴)",
    CASE WHEN valid_order_no = 1 THEN 1 ELSE 0 END AS "純新規フラグ(分析対象)",
    
    -- 【最重要指標】純新規フラグ(統合考慮) (Immutable Pure-New Flag)
    CASE
        WHEN is_cus_merged = 1 THEN (CASE WHEN valid_order_no = 1 THEN 1 ELSE 0 END) 
        WHEN is_cus_merged <> 1 THEN (CASE WHEN total_order_no = 1 THEN 1 ELSE 0 END)
        ELSE (CASE WHEN total_order_no = 1 THEN 1 ELSE 0 END) 
    END AS "純新規フラグ(統合考慮)",
    
    -- Product Mix Logic (RG優先の購入フラグ)
    CASE WHEN is_rg_product = 1 THEN 1 ELSE 0 END AS "RG購入フラグ",
    CASE WHEN is_rg_product <> 1 AND is_tr_product = 1 THEN 1 ELSE 0 END AS "TR購入フラグ",
    
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
    
    -- ====== Returns ======
    is_biz_cnsl                               AS "CNSLフラグ",
    is_biz_return                             AS "返品フラグ",
    is_sys_cnsl                               AS "CNSLフラグ_システム基準",
    is_sys_return                             AS "返品フラグ_システム基準",
    is_fake_return                            AS "ダミー返品フラグ",
    is_return_no_refund                       AS "返品_返金保証除く_フラグ", 
    is_refund_eligibility                     AS "全額返金フラグ",  
    return_reason_note                        AS "返品理由",
    
    -- ====== Customers ======
    is_cus_black                              AS "ブラックフラグ", 
    is_cus_deleted_merged                     AS "削除/統合フラグ", 
    is_cus_merged                             AS "顧客統合フラグ" 

FROM
    base_order_table
;
