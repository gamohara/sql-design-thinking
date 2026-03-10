/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
定期購入の次回出荷時の金額を算出するクエリです。
割引適用後の金額計算およびポイント配分計算を行います。

This query calculates the next shipment price for subscription orders,
including discount application and point allocation.

【ビジネスロジック / Business Logic】
----------------------------------------------------------------------------------------------
1. 定期配送周期の正規化
2. 商品ごとの小計金額の計算
3. 顧客割引の適用
4. 税抜金額の算出
5. 累積和（Running Sum）を用いたポイント配分

1. Normalize subscription delivery cycles
2. Calculate product subtotal
3. Apply customer discount
4. Calculate tax excluded price
5. Allocate points using running sum allocation logic

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
   累計配分ポイントの算出
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
-- 1. [定期情報取得] subsc_order_table の整理
--    user_id ごとの定期購入設定を取得し、「定期お届け周期」を日数に換算します。
--    粒度: user_id、subsc_id
----------------------------------------------------------------------
	SELECT
		-- ▼ ID
		user_id, 
		subsc_id, 

		-- ▼ 定期情報
		subsc_status, 
		order_type, 
		payment_type, 

		-- subsc_type により、subsc_delivery_cycleの値が変わり、以下の4タイプに分類できる
		-- [タイプ１] subsc_typeが 'month_day' の場合、subsc_order_typeは 〇,△ となる    （〇ヵ月ごと△日着）    例. 1,23 → 1ヵ月ごとの23日着
		-- [タイプ２] subsc_typeが 'month_week' の場合、subsc_order_typeは 〇,△,□ となる （〇ヵ月ごと第△□曜日） 例. 2,2,1 → 2ヵ月ごとの第2月曜日
		-- [タイプ３] subsc_typeが 'day' の場合、subsc_order_typeは 〇 となる             （〇日ごと）           例. 30 → 30日ごと
		-- [タイプ４] subsc_typeが 'week' の場合、subsc_order_typeは 〇,□ となる          （〇週間ごと□曜日）     例. 11,6 → 11週間ごとの土曜日
		CASE
			-- 月単位の設定 (タイプ1, 2) → 月数 × 30日 で換算
			WHEN subsc_type IN ('month_day','month_week') AND subsc_setting LIKE '%,%' 
				THEN CAST(TRIM(LEFT(subsc_setting,CHARINDEX(',',subsc_setting) -1)) AS INTEGER) * 30    
			-- 週単位の設定 (タイプ4) → 週数 × 7日 で換算
			WHEN subsc_type = 'week' AND subsc_setting LIKE '%,%' 
				THEN CAST(TRIM(LEFT(subsc_setting,CHARINDEX(',',subsc_setting) -1)) AS INTEGER) * 7     
			-- 日単位の設定 (タイプ3) → そのまま数値化
			ELSE CAST(TRIM(subsc_setting) AS INTEGER) 
		END                           AS subsc_delivery_cycle, 

		-- ▼ 日付情報
		subsc_started_at,
		cancel_at,
		resumption_at,
		next_shipment_at,
		next_delivery_at,

		-- ▼ 定期解約情報
		cancel_reason_id,
		cancel_note,

		-- ▼ 金額関連
		COALESCE(next_ship_use_points,0) AS next_ship_use_points, -- ポイント計算で使用

	FROM
		subsc_order_table
), 

base_subsc_item_order AS (
----------------------------------------------------------------------
-- 2. [商品情報取得] subsc_item_order_table の整理
--    subsc_id に紐づく商品と注文数を取得します。
--    粒度: subsc_id, subsc_order_item_seq
----------------------------------------------------------------------
	SELECT
		-- ▼ ID
		subsc_id, 
		subsc_order_item_seq, 
		product_id, 

		-- ▼ 注文数（空文字対策を入れて数値化）
		CAST(COALESCE(NULLIF(TRIM(quantity),''),0) AS INTEGER) AS order_quantity 

	FROM
		subsc_item_order_table   -- W2_定期購入商品マスタ
), 

subsc_item_order_joined AS (
----------------------------------------------------------------------
-- 3. [情報付与] item_table の結合
--    item_table を結合し、商品カテゴリ情報や各商品の単価情報を取得します。
--    粒度: subsc_id, subsc_order_item_seq
----------------------------------------------------------------------
	SELECT
		-- ▼ 定期購入商品情報
		a.*, 

		b.product_category_level, -- 定期購入/単品購入の判定に使用
		COALESCE(b.subsc_amount, 0)   AS subsc_amount, 
		COALESCE(b.tax_rate, 100) AS tax_rate 

	FROM
		base_subsc_item_order a   -- 2.の商品情報

	LEFT JOIN
		item_table b         -- 商品情報テーブル
	ON a.product_id = b.product_id 
), 

subsc_item_order_price_calc_filter AS (
----------------------------------------------------------------------
-- 4. [絞り込み・概算] 定期対象商品の特定と概算金額算出
--    「定期」扱いとなる商品のみを抽出し、税込金額（単価×数量）を計算します。
--    粒度: subsc_id, subsc_order_item_seq
----------------------------------------------------------------------
	SELECT
		*, 

		-- 概算金額の算出（この時点ではクーポン・ポイント割引は未適用）
		subsc_amount * order_quantity AS subtotal_subsc_amount 

	FROM
		subsc_item_order_joined   -- 3.の情報

	WHERE
		product_category_level IN ('subsc_item')  -- subscription items only
), 

subsc_full_joined AS (
----------------------------------------------------------------------
-- 5. [データ結合] subsc_order_table＋subsc_item_order_tableの統合
--    計算に必要な全ての情報を1つのテーブルにまとめます。
--    粒度: user_id, subsc_id, subsc_order_item_seq
----------------------------------------------------------------------
	SELECT
		-- ▼ ID
		d.user_id, 
		d.subsc_id, 
		c.subsc_order_item_seq, 
		c.product_id, 

		-- ▼ 定期情報
		d.subsc_status, 
		d.order_type, 
		d.payment_type, 
		d.subsc_delivery_cycle,  

		-- ▼ 日付情報
		d.subsc_started_at, 
		d.cancel_at, 
		d.resumption_at, 
		d.next_shipment_at, 
		d.next_delivery_at,

		-- ▼ 定期解約情報
		d.cancel_reason_id, 
		d.cancel_note, 

		-- ▼ 金額・商品情報
		c.order_quantity, 
		c.subtotal_subsc_amount, 
		c.tax_rate, 
		d.next_ship_use_points,

	FROM
		subsc_item_order_price_calc_filter c   -- 4.の商品情報

	LEFT JOIN
		base_subsc_order d         -- 1.の定期台帳
	ON c.subsc_id = d.subsc_id
), 

subsc_cast_joined_calc_discount AS (
----------------------------------------------------------------------
-- 6. [金額計算] discount_amountの適用
--    user_masterからdiscount_amountを取得し、税込金額に対して適用します。
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
		subsc_full_joined e   -- 5.の結合データ

	LEFT JOIN
		user_master f 
	ON e.user_id = f.user_id 
), 

subsc_calc_tax AS (
----------------------------------------------------------------------
-- 7. [金額計算] 消費税の計算（税抜化）
--    税込金額から税率を使って税抜金額を算出します。
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
		subsc_cast_joined_calc_discount   -- 6.のデータ
), 

subsc_price_ratio AS (
----------------------------------------------------------------------
-- 8. [ポイント配分準備] 累積和（Running Sum）の計算
--    ポイントを端数なく配分するために、各商品までの「累積金額」と「全体合計」を計算します。
--    ※ ORDER BY で「金額が高い順」かつ「枝番順」に並べることで、計算順序を一意に固定しています。
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
		subsc_calc_tax   -- 7.のデータ
),

calc_point_diff AS (
----------------------------------------------------------------------
-- 9. [ポイント配分準備] 累計配分ポイントの計算
--    その商品「まで」に割り当てるべき累計ポイントを算出します。
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

		-- 異常検知
		-- 0除算チェック: 合計金額が0円の場合、ポイント配分ができないためエラーフラグを立てる
		-- user_id NULLチェック: user_id がNULL値の場合、エラーフラグを立てる
		-- user_id 桁数チェック: user_id(8桁)の桁数が8桁より多い場合、エラーフラグを立てる
		-- subsc_id NULLチェック: subsc_id がNULL値の場合、エラーフラグを立てる
		CASE
			WHEN subsc_id_total_amount = 0   THEN 'ERR_ZERO_TOTAL'
			WHEN NULLIF(user_id,'') IS NULL  THEN 'ERR_NULL_userID'
			WHEN LENGTH(user_id) > 8         THEN 'ERR_LONG_userID'
			WHEN NULLIF(subsc_id,'') IS NULL THEN 'ERR_NULL_subscID'
			ELSE ''
		END AS is_err

	FROM
		subsc_price_ratio   -- 8.のデータ
),

fix_subsc_price AS (
----------------------------------------------------------------------
-- 10. [ポイント配分] 引き算によるポイント確定
--    「今回の商品までの累計配分ポイント」から「前の商品までの累計配分ポイント」を引くことで
--     その商品単体のポイント配分額を算出します。
--     これにより、最終的な合計ポイントが必ず一致します（Penny Perfect配分）。
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
		calc_point_diff   -- 9.のデータ
)

----------------------------------------------------------------------
-- 11. [最終出力] SELECT
--     各マスタと結合してコード値を名称に変換し、必要なカラムを整理して出力します。
--     粒度: user_id, subsc_id, subsc_order_item_seq
----------------------------------------------------------------------
SELECT
	-- ====== ID系 ======
	g.user_id,
	g.subsc_id,
	g.subsc_order_item_seq, 

	-- ====== 商品情報 ======
	g.product_id, 
	h.product_name,

	-- ====== 定期情報 ======
	g.subsc_delivery_cycle,

	-- ステータスコードを日本語名称に変換
	-- ※20(休止)と30(解約)は、この分析上では同じ「休止扱い」としてまとめます
	CASE
		WHEN g.subsc_status = 'active'          THEN 'Active_Subsc'
		WHEN g.subsc_status = 'paused'          THEN 'Paused_Subsc'
		WHEN g.subsc_status = 'payment_failed'  THEN 'Payment_Error'
		ELSE '' 
	END AS subsc_status_name, 

	-- 継続中フラグ（稼働中の定期のみ1）
	CASE
		WHEN g.subsc_status = 'active' THEN 1
		ELSE 0 
	END AS is_active_subsc, 

	-- ====== 注文情報 ======
	CASE
		WHEN g.order_type LIKE '%TEL%'
		  OR g.order_type LIKE '%Phone%'  THEN 'TEL' 
		WHEN g.order_type LIKE '%Letter%' 
		  OR g.order_type LIKE '%FAX%'    THEN 'Letter/FAX' 
		WHEN g.order_type LIKE '%PC%' 
		  OR g.order_type LIKE '%SP%'     THEN 'EC' 
		ELSE 'Other' 
	END AS order_channel, 

	-- 支払区分コードを支払名称に変換
	i.payment_type_name,

	-- ====== 日付 ======
	g.subsc_started_at,
	g.cancel_at,
	g.resumption_at,
	g.next_shipment_at,
	g.next_delivery_at,

	-- ====== 注文数・金額関連 ======
	g.order_quantity,

	-- 最終金額 = 税抜金額 - 次回利用ポイント
	CAST(
		TRUNCATE(
			g.subtotal_subsc_discount_amount_excl_tax - g.next_use_points 
		) AS INTEGER
	) AS subsc_discount_incl_point_excl_tax, 

	-- ====== 定期解約情報 ======
	cancel_reason_id,
	cancel_note,

	-- ====== 異常検知関連 ======
    g.is_err, 
    CAST(g.subsc_id_total_amount AS INTEGER) AS subsc_id_total_amount 

FROM
    fix_subsc_price g -- 10.の計算済みデータ

LEFT JOIN
	product_table h 
ON g.product_id = h.product_id 

LEFT JOIN
	payment_type_table i 
ON g.payment_type = i.payment_type 

;