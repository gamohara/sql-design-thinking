/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 キャンセル・返品ステータス判定および集約マスタ
  Cancellation & Return Classification (Intermediate Layer)

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. 複合条件ステータス判定
     ステータス番号、注文数量、処理理由メモ（キーワード）などの複数の状況証拠を組み合わせ、
     「出荷前キャンセル」「出荷後未受取」「出荷後返品」を厳密に判定。
  2. 注文レベルへの状態集約
     明細（Line Item）レベルで発生したステータスを、親子の絆キー（order_link_key）を用いて
     注文（Order）レベルへと集約（MAX関数でRollup）。
  3. ステータス競合の解決
     キャンセルと返品が混在した場合のビジネス上の優先順位（返品 ＞ キャンセル）を定義し、
     最終的な確定フラグを付与。
  4. 全額返金保証の適用判定
     保証対象商品（GUARANTEE_PACK_01 等）の有無と、顧客マスタ（ブラックリスト、退会済）を
     クロスチェックし、返金適用可否を判定。

  1. Multi-Condition Status Evaluation
     Strict evaluation of "Pre-shipment Cancellation", "Unreceived Shipment", and "Post-shipment Return"
     by combining status numbers, quantities, and keywords in reason notes.
  2. Order-Level Rollup
     Aggregating line-item level statuses to the order level using the Order Link Key via MAX function.
  3. Conflict Resolution
     Defining business priority rules (Return > Cancellation) to assign a definitive final flag
     when mixed statuses occur within the same order.
  4. Refund Eligibility Check
     Cross-checking the presence of eligible products against the customer master 
     (blacklist, deleted status) to determine refund applicability.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
このクエリは以下の処理ステップで構成されています。
This query consists of the following processing layers.

  1. status_evaluation_base
     明細レベルでの一次ステータス判定（数量、コード、キーワード検索）
     Initial status evaluation at the line-item level (quantity, code, keyword search).

  2. status_classification
     複合条件による「出荷前キャンセル」「出荷後返品」の二次判定
     Secondary classification for pre-shipment cancellations and post-shipment returns.

  3. order_level_rollup
     注文単位（order_id）への状態集約（親子はまだ別）
     Status rollup to the order_id level (parent and child orders kept separate).

  4. status_resolution
     ステータス競合時の優先順位に基づく最終フラグ確定
     Final flag determination based on priority rules during status conflicts.

  5. customer_validation
     顧客マスタとのクロスチェックによる属性判定
     Cross-validation of customer attributes using the customer master.

  6. refund_eligibility_finalization
     全額返金保証の適用可否判定
     Final determination of full refund eligibility.

  7. parent_child_integration
     親子の絆キーによる共通集約（返品データから出荷元データへのステータス転写）
     Status transfer to the parent order using the Order Link Key.

  8. filter_cancellation_return
     キャンセルまたは返品データに絞り込み
     Filtering isolated cancellation and return records.

  9. Final Output
     最終結果出力
     Final dataset generation.

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  Order Level (親注文レベルに集約済)
  Aggregated to the Parent Order Level

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  user_id, order_link_key

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: window functions)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 キャンセル・返品集約中間テーブル
  int_cancellation_return_master 
==============================================================================================
*/

WITH 
----------------------------------------------------------------------
-- 1. [Base Evaluation] 明細レベルでの一次判定
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
status_evaluation_base AS (
    SELECT
        -- IDs
        user_id,
        order_id,
        order_link_key,
        line_no,
        product_id,

        -- [Condition A] Status-based Cancellation (ステータス番号 > 6)
        CASE WHEN order_status_number > 6 THEN 1 ELSE 0 END AS is_status_cancelled,

        -- [Condition B] Quantity-based Return (数量 <= 0)
        CASE WHEN quantity <= 0 THEN 1 ELSE 0 END AS is_quantity_returned,

        -- [Condition C] System Code-based Return (ステータスコード <> '00')
        CASE WHEN return_exchange_status <> '00' THEN 1 ELSE 0 END AS is_code_returned,

        -- [Condition D] Unreceived After Shipment (理由メモのキーワード判定)
        CASE 
            WHEN return_reason_note LIKE '%長期%' 
              OR return_reason_note LIKE '%配送戻り%' 
              OR return_reason_note LIKE '%拒否%' THEN 1
            ELSE 0
        END AS is_shipped_unreceived,

        -- [Condition E] Refund Eligibility Product Check (保証対象商品の同梱確認)
        -- 注文内に1つでも全額返金対象商品（GUARANTEE_PACK_01等）があればフラグを立てる
        MAX(CASE WHEN product_id = 'GUARANTEE_PACK_01' THEN 1 ELSE 0 END) 
            OVER (PARTITION BY order_id) AS has_refund_eligible_product

    FROM
        stg_order_info -- 【前工程】stg_order_info
),

----------------------------------------------------------------------
-- 2. [Status Classification] 複合条件による二次判定
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
status_classification AS (
    SELECT
        *,
        -- Pre-shipment Cancellation Logic (出荷前キャンセル または 未受取)
        CASE 
            WHEN is_shipped_unreceived = 1 THEN 1 
            WHEN is_status_cancelled = 1 AND is_quantity_returned = 0 AND is_code_returned = 0 THEN 1
            ELSE 0
        END AS is_pre_shipment_cancel,

        -- Post-shipment Return Logic (出荷後返品)
        CASE 
            WHEN (is_quantity_returned = 1 OR is_code_returned = 1) AND is_shipped_unreceived = 0 THEN 1 
            ELSE 0
        END AS is_post_shipment_return
    FROM
        status_evaluation_base
),

----------------------------------------------------------------------
-- 3.[Order-Level Rollup] 注文単位（order_id）への集約
--    ここではまだ枝番ごとの order_id で集約するため、親子は別々の行として存在します。
--    Data Grain: order_id
----------------------------------------------------------------------
order_level_rollup AS (
    SELECT
        user_id, 
        order_id,
        order_link_key,
        MAX(is_pre_shipment_cancel) AS max_pre_shipment_cancel,
        MAX(is_post_shipment_return) AS max_post_shipment_return,
        MAX(has_refund_eligible_product) AS has_refund_eligible_product
    FROM
        status_classification
    GROUP BY 
        user_id, order_id, order_link_key 
),

----------------------------------------------------------------------
-- 4. [Conflict Resolution] ステータス競合の解決と確定
--    Data Grain: order_id
----------------------------------------------------------------------
status_resolution AS (
    SELECT
        *,
        -- Prioritize Returns over Cancellations (返品 ＞ キャンセル)
        CASE WHEN max_pre_shipment_cancel = 1 AND max_post_shipment_return = 0 THEN 1 ELSE 0 END AS cnsl_flag_order_level,
        CASE WHEN max_post_shipment_return = 1 THEN 1 ELSE 0 END AS return_flag_order_level
    FROM
        order_level_rollup
),

----------------------------------------------------------------------
-- 5. [Customer Validation] 顧客属性（ブラック・退会等）のクロスチェック
--    Data Grain: order_id
----------------------------------------------------------------------
customer_validation AS (
    SELECT
        r.*,
        COALESCE(c.is_blacklisted, 0) AS cus_black_flag,
        COALESCE(c.is_deleted_or_merged, 0) AS cus_deleted_merged_flag
    FROM
        status_resolution r
    LEFT JOIN
        dim_customers c ON r.user_id = c.user_id 
),

----------------------------------------------------------------------
-- 6.[Refund Eligibility Finalization] 全額返金フラグの確定
--    Data Grain: order_id
----------------------------------------------------------------------
refund_eligibility_finalization AS (
    SELECT
        *,
        -- Refund Logic: 対象商品あり かつ 問題のない顧客であること
        CASE 
            WHEN has_refund_eligible_product = 1 AND cus_black_flag = 0 AND cus_deleted_merged_flag = 0 THEN 1
            ELSE 0
        END AS refund_eligibility_flag_order_level
    FROM
        customer_validation
),

----------------------------------------------------------------------
-- 7.[Parent-Child Integration] 親子の絆キーによる共通集約（親へのステータス転写）
--    order_1/2/3 すべてのパターンを一括でグルーピングし、グループ内での最大フラグを採用（OR条件）します。
--    これにより、返品情報（子）が出荷情報（親）に紐付き、親注文のステータスが更新されます。
--    Data Grain: order_link_key
----------------------------------------------------------------------
parent_child_integration AS (
    SELECT
        user_id,
        order_link_key,
        MAX(cnsl_flag_order_level)               AS final_cnsl_flag,
        MAX(return_flag_order_level)             AS final_return_flag,
        MAX(refund_eligibility_flag_order_level) AS final_refund_eligibility_flag,
        MAX(cus_black_flag)                      AS final_cus_black_flag,
        MAX(cus_deleted_merged_flag)             AS final_cus_deleted_merged_flag
    FROM
        refund_eligibility_finalization
    GROUP BY 
        user_id,
        order_link_key
),

----------------------------------------------------------------------
-- 8. [Filter Targeted Records] キャンセルまたは返品データに絞り込み
--    Data Grain: order_link_key
----------------------------------------------------------------------
filter_cancellation_return AS (
    SELECT
        *
    FROM
        parent_child_integration
    WHERE
        final_cnsl_flag = 1 OR final_return_flag = 1
)

----------------------------------------------------------------------
-- 9. [Final Output] 最終結果出力
--    Data Grain: order_link_key
----------------------------------------------------------------------
SELECT
    -- ====== IDs ======
    user_id,
    order_link_key,

    -- ====== Return/Cancellation Flags ======
    COALESCE(final_cnsl_flag, 0) AS cnsl_flag,
    COALESCE(final_return_flag, 0) AS return_flag,
    COALESCE(final_refund_eligibility_flag, 0) AS refund_eligibility_flag,

    -- ====== Customer Flags ======
    COALESCE(final_cus_black_flag, 0) AS cus_black_flag,
    COALESCE(final_cus_deleted_merged_flag, 0) AS cus_deleted_merged_flag
FROM
    filter_cancellation_return
;
