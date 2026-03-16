/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
定期購入の次回出荷時の金額を算出するクエリです。
割引適用後の金額計算およびポイント配分計算を行います。

This query calculates the next shipment price for subscription orders,
including discount application and point allocation.

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
1. 定期配送周期の正規化
2. 商品ごとの小計金額の計算
3. 顧客割引の適用
4. 税抜金額の算出
5. 累積和（Running Sum）を用いたポイント配分
   ※ 財務的な正確性を担保するため、1円の誤差も許容しない「累積差分方式」を採用しています。

1. Normalize subscription delivery cycles
2. Calculate product subtotal
3. Apply customer discount
4. Calculate tax excluded price
5. Allocate points using running sum allocation logic
   (Ensures "Penny Perfect" accuracy for financial reporting.)

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
このクエリは以下の処理ステップで構成されています。
This query consists of the following processing layers.

1. base_subsc_order
   定期購入台帳の取得と配送周期の正規化
   Retrieve subscription base data and normalize delivery cycles

2. base_subsc_item_order
   定期購入商品の取得
   Retrieve subscription item order data

3. subsc_item_order_joined
   商品マスタを結合し商品情報を付与
   Join product master data

4. subsc_item_order_price_calc_filter
   定期対象商品の抽出と商品小計金額の計算
   Filter subscription items and calculate subtotal price

5. subsc_full_joined
   定期台帳と商品情報を統合
   Combine subscription order and item datasets

6. subsc_cast_joined_calc_discount
   顧客割引の適用
   Apply customer discount

7. subsc_calc_tax
   税抜金額の算出
   Calculate tax excluded price

8. subsc_price_ratio
   ポイント配分のための累積金額計算
   Calculate cumulative price for point allocation

9. calc_point_diff
   累計配分ポイントの算出 ＆ データ品質異常の検知
   Calculate cumulative allocated points

10. fix_subsc_price
    差分計算により商品単位のポイント配分を確定
    Finalize item-level point allocation using difference calculation

11. Final SELECT
    マスタ結合および最終データセット出力
    Join master tables and output final dataset

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
1行は以下の粒度を表します
user_id × subsc_id × subsc_order_item_seq

Each row represents:
user_id × subsc_id × subsc_order_item_seq

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
(user_id, subsc_id, subsc_order_item_seq)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
定期購入の次回出荷金額を算出した分析用データセット
Dataset for analyzing next shipment prices for subscription orders
==============================================================================================
*/

WITH 
base_subsc_order AS (
----------------------------------------------------------------------
-- 1. [定期情報取得] 定期購入台帳の整理
--    user_id ごとの定期購入設定を取得し、「定期お届け周期」を日数に換算します。
--    粒度: user_id、subsc_id
----------------------------------------------------------------------
	SELECT
        user_id, 
        subsc_id, 
        subsc_status, 
        order_type, 
        payment_type, 

        -- subsc_type により、subsc_setting のフォーマットを解析し日数に正規化
        CASE
            WHEN subsc_type IN ('month_day','month_week') AND subsc_setting LIKE '%,%' 
                THEN CAST(TRIM(LEFT(subsc_setting,CHARINDEX(',',subsc_setting) -1)) AS INTEGER) * 30    
            WHEN subsc_type = 'week' AND subsc_setting LIKE '%,%' 
                THEN CAST(TRIM(LEFT(subsc_setting,CHARINDEX(',',subsc_setting) -1)) AS INTEGER) * 7     
            ELSE CAST(TRIM(subsc_setting) AS INTEGER) 
        END AS subsc_delivery_cycle, 

        subsc_started_at,
        cancel_at,
        resumption_at,
        next_shipment_at,
        next_delivery_at,
        cancel_reason_id,
        cancel_note,
        COALESCE(next_ship_use_points,0) AS next_ship_use_points

	FROM
		subsc_order_table
), 

base_subsc_item_order AS (
----------------------------------------------------------------------
-- 2. [商品情報取得] 定期購入商品データの整理
--    subsc_id に紐づく商品情報を取得（空文字・NULL対策を実施）
--    粒度: subsc_id, subsc_order_item_seq
----------------------------------------------------------------------
	SELECT
        subsc_id, 
        subsc_order_item_seq, 
        product_id, 
        CAST(COALESCE(NULLIF(TRIM(quantity),''),0) AS INTEGER) AS order_quantity 

	FROM
        subsc_item_order_table
), 

subsc_item_order_joined AS (
----------------------------------------------------------------------
-- 3. [情報付与] 商品マスタ(item_table) の結合
--    粒度: subsc_id, subsc_order_item_seq
----------------------------------------------------------------------
	SELECT
        a.*, 
        b.product_category_level,
        COALESCE(b.subsc_amount, 0) AS subsc_amount, 
        COALESCE(b.tax_rate, 100) AS tax_rate 

	FROM
        base_subsc_item_order a 

	LEFT JOIN
        item_table b ON a.product_id = b.product_id 
), 

subsc_item_order_price_calc_filter AS (
----------------------------------------------------------------------
-- 4. [絞り込み・概算] 定期対象商品の特定と商品別小計の算出
--    粒度: subsc_id, subsc_order_item_seq
----------------------------------------------------------------------
	SELECT
		*, 
        subsc_amount * order_quantity AS subtotal_subsc_amount 

	FROM
        subsc_item_order_joined 

	WHERE
        product_category_level IN ('subsc_item')
), 

subsc_full_joined AS (
----------------------------------------------------------------------
-- 5. [データ結合] 台帳と商品明細の統合
--    粒度: user_id, subsc_id, subsc_order_item_seq
----------------------------------------------------------------------
	SELECT
        d.user_id, 
        d.subsc_id, 
        c.subsc_order_item_seq, 
        c.product_id, 
        d.subsc_status, 
        d.order_type, 
        d.payment_type, 
        d.subsc_delivery_cycle,  
        d.subsc_started_at, 
        d.cancel_at, 
        d.resumption_at, 
        d.next_shipment_at, 
        d.next_delivery_at,
        d.cancel_reason_id, 
        d.cancel_note, 
        c.order_quantity, 
        c.subtotal_subsc_amount, 
        c.tax_rate, 
        d.next_ship_use_points

	FROM
        subsc_item_order_price_calc_filter c 

	LEFT JOIN
        base_subsc_order d ON c.subsc_id = d.subsc_id
), 

subsc_cast_joined_calc_discount AS (
----------------------------------------------------------------------
-- 6. [金額計算] 顧客別割引率の適用
--    粒度: user_id, subsc_id, subsc_order_item_seq
----------------------------------------------------------------------
	SELECT
        e.*, 
		-- 割引後金額 = 元値 × 100 ÷ 割引率（例: 10%引きなら割引率110 とする）
		CAST(
			TRUNCATE(
				(e.subtotal_subsc_amount * 100 * 1.0) 
				/ COALESCE(f.discount_amount, 100) -- 割引率がNULLなら100(割引なし)
			) AS DECIMAL(18, 4)
		) AS subtotal_subsc_discount_amount 
    FROM
        subsc_full_joined e 
    LEFT JOIN
        user_master f ON e.user_id = f.user_id 
), 

subsc_calc_tax AS (
----------------------------------------------------------------------
-- 7. [金額計算] 消費税の計算（税抜価格の算出）
--    粒度: user_id, subsc_id, subsc_order_item_seq
----------------------------------------------------------------------
	SELECT
        *, 
		-- 税抜金額 = 税込金額 × 100 ÷ 税率（例: 108, 110）
		CAST(
			TRUNCATE(
				(subtotal_subsc_discount_amount * 100 * 1.0) / tax_rate
			) AS DECIMAL(18, 4)
		) AS subtotal_subsc_discount_amount_excl_tax 
    FROM
        subsc_cast_joined_calc_discount
), 

subsc_price_ratio AS (
----------------------------------------------------------------------
-- 8. [ポイント配分準備] 累積和（Running Sum）の計算
--    各商品までの累積金額を算出し、配分比率のベースを作成します。
--    粒度: user_id, subsc_id, subsc_order_item_seq
----------------------------------------------------------------------
	SELECT
        *, 
		-- subsc_idごとの合計金額（分母用）
		SUM(subtotal_subsc_discount_amount_excl_tax) OVER(PARTITION BY user_id, subsc_id) AS subsc_id_total_amount,
		-- subsc_idごとの累積金額（分子用）
		SUM(subtotal_subsc_discount_amount_excl_tax) OVER(
			PARTITION BY user_id, subsc_id 
			ORDER BY subtotal_subsc_discount_amount_excl_tax DESC, subsc_order_item_seq ASC
			ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
		) AS subsc_id_cumulative_amount 
    FROM
        subsc_calc_tax
),

calc_point_diff AS (
----------------------------------------------------------------------
-- 9. [ポイント配分準備] 累計配分ポイントの算出 ＆ 異常検知
--    データ欠損や整合性チェックを同時に行い、データ品質を担保します。
--    粒度: user_id, subsc_id, subsc_order_item_seq
----------------------------------------------------------------------
	SELECT
        *, 
		-- 累計配分ポイント = 総ポイント * (累積金額 / 合計)
		-- FLOORで端数切捨てを行うことで、整数値のポイントとして扱います
		CAST(
			FLOOR(next_ship_use_points * (subsc_id_cumulative_amount * 1.0 / NULLIF(subsc_id_total_amount, 0))) 
			AS INTEGER
			)AS cumulative_allocated_points,

        -- データ品質チェックロジック (Data Quality Validation)
		CASE
			WHEN subsc_id_total_amount = 0   THEN 'ERR_ZERO_TOTAL'
			WHEN NULLIF(user_id,'') IS NULL  THEN 'ERR_NULL_userID'
			WHEN LENGTH(user_id) > 8         THEN 'ERR_LONG_userID'
			WHEN NULLIF(subsc_id,'') IS NULL THEN 'ERR_NULL_subscID'
			ELSE ''
		END AS is_err
    FROM
        subsc_price_ratio
),

fix_subsc_price AS (
----------------------------------------------------------------------
-- 10. [ポイント配分] 累積差分による最終ポイント確定
--     (現在の累計ポイント) - (一つ前の累計ポイント) を算出することで
--     合計値が元の利用ポイントと必ず一致するように調整します（Penny Perfect配分）。
--     粒度: user_id, subsc_id, subsc_order_item_seq
----------------------------------------------------------------------
	SELECT
        *, 
		-- ▼ ポイント配分計算
		CAST(
			-- [A] 今回の累計配分ポイント (9.で計算済み)
		    cumulative_allocated_points
		    -
		    -- [B] 前回の累計配分ポイント = LAG関数で1つ前の[A]を取得（なければ0）
		    COALESCE(
			    LAG(cumulative_allocated_points) OVER(
					    PARTITION BY user_id, subsc_id 
					    ORDER BY subtotal_subsc_discount_amount_excl_tax DESC, subsc_order_item_seq ASC
				        ),
		        0 -- 1行目の場合は引くものがないので0
		    ) AS INTEGER
	    ) AS next_use_points
    FROM
        calc_point_diff
)

----------------------------------------------------------------------
-- 11. [最終出力] 
--     マスタ結合によるコード値の名称変換と最終金額の算出
--     粒度: user_id, subsc_id, subsc_order_item_seq
----------------------------------------------------------------------
SELECT
    g.user_id,
    g.subsc_id,
    g.subsc_order_item_seq, 
    g.product_id, 
    h.product_name,
    g.subsc_delivery_cycle,
    CASE
        WHEN g.subsc_status = 'active'           THEN 'Active_Subsc'
        WHEN g.subsc_status = 'paused'           THEN 'Paused_Subsc'
        WHEN g.subsc_status = 'payment_failed'   THEN 'Payment_Error'
        ELSE '' 
    END AS subsc_status_name, 
    CASE
        WHEN g.subsc_status = 'active' THEN 1
        ELSE 0 
    END AS is_active_subsc, 
    CASE
        WHEN g.order_type LIKE '%TEL%'
          OR g.order_type LIKE '%Phone%'   THEN 'TEL' 
        WHEN g.order_type LIKE '%Letter%' 
          OR g.order_type LIKE '%FAX%'     THEN 'Letter/FAX' 
        WHEN g.order_type LIKE '%PC%' 
          OR g.order_type LIKE '%SP%'      THEN 'EC' 
        ELSE 'Other' 
    END AS order_channel, 
    i.payment_type_name,
    g.subsc_started_at,
    g.cancel_at,
    g.resumption_at,
    g.next_shipment_at,
    g.next_delivery_at,
    g.order_quantity,
    CAST(
        TRUNCATE(
            g.subtotal_subsc_discount_amount_excl_tax - g.next_use_points 
        ) AS INTEGER
    ) AS subsc_discount_incl_point_excl_tax, 
    cancel_reason_id,
    cancel_note,
    g.is_err, 
    CAST(g.subsc_id_total_amount AS INTEGER) AS subsc_id_total_amount 

FROM
    fix_subsc_price g 
LEFT JOIN
    product_table h ON g.product_id = h.product_id 
LEFT JOIN
    payment_type_table i ON g.payment_type = i.payment_type 

;
