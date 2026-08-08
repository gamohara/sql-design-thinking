/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 対象品（定期購入美容液）の顧客ごとの「初回(F1)」「2回目(F2)」「3回目(F3)」「4回目(F4)」の
 購入履歴を1行（横持ち）に集約し、LTV分析や定期継続率の分析を行うためのデータマートを作成します。
 返品も含めて「実際に何が起きたか」をそのまま記録する、実績監査モデル（全対象版）です。
 F2〜F4の返品を除外して純粋なリピート率を見たい場合は、本READMEの
 「返品考慮版にする場合」を参照し、Step 8以降を差し替えてください。
  Horizontal LTV/Retention Base Mart — Intermediate Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. F1（初回購入）の起点特定
     「特定の対象コード（代理店由来や他アフィリエイト由来のネット媒体）で初めて購入した
     注文」をF1の起点とし、以降の注文をF2, F3...とカウントします。起点は前工程のGUIパラメータ
     設定で作られる「分析起点対象フラグ」（is_cohort_anchor_target）で制御されます。
  2. 同日複数注文の整理
     同じ日に複数回注文が発生した場合、「1回の購入アクション」として合算して評価します。
     全て返品なら最古の1件だけを残し、一部返品なら返品分を除外して正常な注文のみ合算します。
     属性情報（媒体・プロモコード等）は、残った中で最も古い注文を「代表注文」として採用します。
  3. F1・F2〜F4の返品・キャンセルの取り扱い（全対象版）
     F1（初回購入）時点で返品（返金保証を使ったものを除く）が発生した注文は、LTVの起点から
     完全に除外します。一方、F2〜F4（リピート段階）については、返品された注文も除外せず
     そのまま横持ちで結合し、「返品フラグ」を別途出力することで、実際の物流実績を監査できる
     ようにします。返品・キャンセルの扱いの詳細な設計思想と30日ルールは、ケース全体README内
     [「返品・キャンセルの取り扱いと30日ルール」](../README.md#返品キャンセルの取り扱いと30日ルール--return-cancellation-handling--the-30-day-rule)
     を参照してください。
  4. 評価対象期間（30日ルール）
     「まだ次回分を買う時期に来ていない顧客」を離脱者としてカウントしてしまうノイズを防ぐため、
     前回出荷から一定日数（本モデルでは30日）経過していない場合は評価対象外とします。

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
  1. prep_target_start_date
     顧客ごとに「分析起点対象フラグでの初回受注日時」を特定
  2. filter_target_orders
     起点日時以降への絞り込みと、同日内の返品状況確認
  3. remove_invalid_duplicate_orders
     返品条件に基づく不要行の除外（重複整理）
  4. assign_order_sequence
     購入回数の採番と代表属性の特定
  5. prepare_f1_aggregation
     同日注文に対する代表フラグの伝播と、複数点定期フラグの生成
  6. subsc_delivery_schedule_source
     定期契約の「次回出荷予定日」や「周期」を取得
  7. purchase_1st
     返品を除外した、クリーンな初回購入(F1)情報の集約
  8. agg_base_table_filtered_purchase_1st
     2回目以降の購入情報を注文単位で集計（返品は除外せずそのまま集約）
     ※返品考慮版にする場合はこのCTEを差し替えます。詳細はREADME参照。
  9. user_table_with_purchase_from_1st_to_4th
     顧客マスタを主軸にF1〜F4のデータを横結合（横持ち変換）
  10. processed_01_user_from_f1_to_f4
      未出荷の予定日補完、および評価対象フラグの作成
  11. processed_02_user_from_f1_to_f4
      購入間隔（日数）の計算と評価対象(30日)フラグの付与
  12. 最終出力
      分析用フラグの確定と日本語カラム名での出力

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  user_id

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  user_id

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: window functions, LISTAGG, DATEDIFF/DATEADD)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 LTV/残存率分析用 F1〜F4横持ちマート（全対象版）
  int_ltv_cohort_base
==============================================================================================
*/

WITH
prep_target_start_date AS (
------------------------------------------------------------
-- 1. [起点特定] 顧客ごとの「対象媒体での初回購入日」を特定
--    前工程の受注データと商品情報を取得し、F1のカウント開始基準となる
--    「指定コード（代理店・アフィリエイト等の対象媒体）での一番古い受注日時」を算出します。
--    粒度: order_id, line_no
------------------------------------------------------------
    SELECT
        user_id, order_id, line_no,
        product_id, product_name, product_external_id4,
        product_analysis_category_level_4, product_analysis_category_level_5,
        product_analysis_category_level_6, product_category, product_subcategory, product_detail,

        order_type, order_status, order_status_numbr, payment_method,
        member_rank_at_order, latest_ad_code, promo_code_prefix, operator_code,
        is_ec_order_without_promo_code,

        ordered_at, ordered_date, ordered_month, shipment_date, shipment_month,
        delivered_date, media_publish_date_from,

        -- ★ここが重要：対象（分析起点対象フラグ由来）の「初回受注日時」を顧客ごとに特定
        -- 分析起点対象フラグ（is_cohort_anchor_target）は、前工程のGUIパラメータ層にて
        -- 「プロモ頭文字が対象パターンに一致（ネット媒体） かつ 販促商品区分が対象コードに一致」
        -- のAND条件で1が立つよう設計されています。対象を変更したい場合、SQL側ではなく
        -- 大元のGUIパラメータ条件（詳細はケース全体READMEの「GUIパラメータ層」節を参照）を
        -- 変更してください。
        MIN(
            CASE
                WHEN is_cohort_anchor_target = 1 THEN ordered_at
            END
            )
        OVER(PARTITION BY user_id) AS target_ordered_at_from,

        quantity, discounted_amount_excl_point_excl_tax, validated_discounted_incl_point_excl_tax,

        is_subsc, subsc_id,

        media_name, media_type, media_category, media_subcategory, media_detail,
        vendor_name, online_media_name, promo_product_type_code, promo_product_type_name,
        media_cost, offer_name, lp_content, has_upsell, has_bot,
        is_agency_referral, is_affiliate, is_no_path, is_no_email,

        -- ▼ 定期引き上げ関連フラグ（対象品特有のコース）
        is_first_multi_subsc,             -- 初回複数定期フラグ（初回複数定期コース）
        is_first_single_to_multi_subsc,   -- 初回単品→複数定期フラグ（初回単品定期コース）

        -- ▼ 返品情報関係
        is_cnsl, is_return, is_fake_return, is_return_no_refund, is_refund_eligibility,
        return_reason_note,

        gender, current_age, prefecture_name, prefecture_no,
        is_null_dm_opt, is_email_subsc, is_cus_black, is_cus_deleted_merged

    FROM
        -- GUIパラメータ層で以下の絞り込みが事前に行われている（母集団への影響を把握しておくこと）：
        --   キャンセルフラグ≠1、商品分析分類（第4階層）が対象カテゴリに一致 かつ 商品連携ID4=RG、
        --   受注日が対象期間の開始日（本モデルでは2024/01/01）より後
        -- 対象商品および受注期間を変更したい場合、大元のGUIパラメータ条件を変更してください
        raw_order_line_ltv_base
),

filter_target_orders AS (
------------------------------------------------------------
-- 2. [重複整理_01] 基準日以降への絞り込みと、同日内の返品状況確認
--    同日の注文が「すべて返品」か「一部正常」かを判定するフラグを準備します。
--    粒度: order_id, line_no
------------------------------------------------------------
    SELECT
        *,

        -- その日の注文が「すべて返品」かどうかを判定 (1つでも返品以外=0 があれば 0になる)
        MIN(is_return_no_refund) OVER(
            PARTITION BY user_id, ordered_date
        ) AS day_all_returned_flag

    FROM
        prep_target_start_date  -- 01. 基準日付算出済みのデータ

    WHERE
        -- ★対象コードの初回受注日時「以降」の注文だけを残す
        ordered_at >= target_ordered_at_from
),

remove_invalid_duplicate_orders AS (
------------------------------------------------------------
-- 3. [重複整理_02] 返品条件に基づく不要行の除外
--    同日内の注文において、不要な返品レコードを除外します。
--    粒度: order_id, line_no
------------------------------------------------------------
    SELECT
        *

    FROM (
        SELECT
            *,
            -- 同日の注文の中で、古い順に連番を振る
            ROW_NUMBER() OVER(
                PARTITION BY user_id, ordered_date
                ORDER BY ordered_at ASC, order_id ASC
            ) AS daily_seq
        FROM
            filter_target_orders
        )

    WHERE
        -- 条件A: 同日の注文が「すべて返品」の場合 -> 分析上1回はカウントするため、最古の注文だけ残す
        (day_all_returned_flag = 1 AND daily_seq = 1)
        OR
        -- 条件B: 正常な注文がある場合 -> 返品された注文は除外し、正常な注文のみ残す（合算される）
        (day_all_returned_flag <> 1 AND is_return_no_refund <> 1)
),

assign_order_sequence AS (
------------------------------------------------------------
-- 4. [採番・属性特定] 購入回数の採番と、代表属性の特定
--    残った有効な注文の中で「購入回数(order_no)」を採番し、
--    同日内に複数注文が合算される場合、最古の注文の属性（媒体等）をその日の代表とします。
--    粒度: order_id, line_no
------------------------------------------------------------
    SELECT
        *,

        -- [分析用] 顧客ごとの累計購入回数（F1, F2...）の算出
        -- DENSE_RANK を使用し、「同じユーザー」の中で「注文日」が古い順に番号を振ります。
        -- これにより、1注文内に複数商品があっても同じ「注文番号（例: 1回目ならすべて1）」が割り当てられます。
        DENSE_RANK() OVER(
            PARTITION BY user_id
            ORDER BY ordered_date ASC
        ) AS order_no,

        -- 注文ごとの合計数量（後続の複数点定期フラグで使用）
        SUM(quantity) OVER(
            PARTITION BY user_id, order_id
        ) AS order_id_sum_quantity,

        -- ★残った有効な注文の中で、同日最古の注文を「代表」として特定する
        ROW_NUMBER() OVER(
            PARTITION BY user_id, ordered_date
            ORDER BY ordered_at ASC, order_id ASC
        ) AS valid_daily_seq

    FROM
        remove_invalid_duplicate_orders  -- 03. の情報
),

prepare_f1_aggregation AS (
------------------------------------------------------------
-- 5. [属性伝播] 同日注文に対する代表フラグの伝播
--    Step 4で特定した「代表注文（valid_daily_seq = 1）」の属性情報を、
--    同日の全レコードに伝播（上書き）させます。
--    これにより、同日の重複注文が合算された場合でも、プロモや経路が混ざるのを防ぎます。
------------------------------------------------------------
    SELECT
        *,

        -- ★対象品用：複数点以上定期フラグ（注文単位の合算数量で判定）
        CASE
            WHEN is_subsc = 1 AND order_id_sum_quantity >= 2 THEN 1
            ELSE 0
        END AS is_subsc_multi,

        -- ▼ 代表注文の属性を、同日の全レコードに伝播（コピー）させる
        MAX(CASE WHEN valid_daily_seq = 1 THEN order_id ELSE NULL END)
            OVER(PARTITION BY user_id, ordered_date) AS daily_rep_order_id,

        MAX(CASE WHEN valid_daily_seq = 1 THEN order_type ELSE NULL END)
            OVER(PARTITION BY user_id, ordered_date) AS daily_rep_order_type,

        MAX(CASE WHEN valid_daily_seq = 1 THEN payment_method ELSE NULL END)
            OVER(PARTITION BY user_id, ordered_date) AS daily_rep_payment_method,

        MAX(CASE WHEN valid_daily_seq = 1 THEN latest_ad_code ELSE NULL END)
            OVER(PARTITION BY user_id, ordered_date) AS daily_rep_latest_ad_code,

        MAX(CASE WHEN valid_daily_seq = 1 THEN vendor_name ELSE NULL END)
            OVER(PARTITION BY user_id, ordered_date) AS daily_rep_vendor_name,

        MAX(CASE WHEN valid_daily_seq = 1 THEN promo_product_type_name ELSE NULL END)
            OVER(PARTITION BY user_id, ordered_date) AS daily_rep_promo_product_name,

        MAX(CASE WHEN valid_daily_seq = 1 THEN offer_name ELSE NULL END)
            OVER(PARTITION BY user_id, ordered_date) AS daily_rep_offer_name,

        MAX(CASE WHEN valid_daily_seq = 1 THEN lp_content ELSE NULL END)
            OVER(PARTITION BY user_id, ordered_date) AS daily_rep_lp_type,

        MAX(CASE WHEN valid_daily_seq = 1 THEN media_detail ELSE NULL END)
            OVER(PARTITION BY user_id, ordered_date) AS daily_rep_media_detail

    FROM
        assign_order_sequence  -- 04. の情報
),

subsc_delivery_schedule_source AS (
------------------------------------------------------------
-- 6. [抽出テーブル] 対象品の定期情報テーブル
--    各顧客の現在の定期契約状況や「次回出荷予定日」を取得します。
--    粒度: user_id
------------------------------------------------------------
    SELECT
        user_id,
        is_subsc_active, subsc_delivery_cycle,
        subsc_start_date, subsc_cancel_date,
        next_shipment_date,         -- 次回出荷予定日（F2以降の予測に使用）
        next_delivery_date,
        second_next_shipment_date,  -- 次々回出荷予定日
        second_next_delivery_date,
        subsc_order_quantity, subsc_price_excl_tax, next_use_points,
        subsc_cancel_reason_id

    FROM
        -- 対象品の定期情報マスタ
        -- 対象商品を変更したい場合、大元のGUIパラメータ条件を変更してください
        dim_subscription_delivery_schedule
),

purchase_1st AS (
------------------------------------------------------------
-- 7. [対象者抽出] 初回購入(F1)情報の集約
--    分析の起点となる「1回目の注文」情報をユーザー単位に集約します。
--    ★重要: 注文が同日複数あった場合でも、Step 5で伝播させた「代表属性」を使用するため
--      混ざることなく、最初の1件のプロモコード等が採用されます。
--
--    ★保守注意(重要):
--      WHERE句で「order_no = 1」に絞り込んだ後に「最大購入回数」を取得しようとすると
--      結果が全て「1」になってしまうため、先にサブクエリ内で
--      「そのユーザーの最大購入回数(latest_order_no)」を計算してから絞り込んでいます。
--
--    ★重要: ここでF1の時点で返品された注文（is_return_no_refund = 1）を
--            厳密に除外（＝正常に購入した顧客のみをLTVの起点とする）します。
--            返金保証を使った返品は対象外のため除外しません（詳細は
--            ケース全体README「返品・キャンセルの取り扱いと30日ルール」を参照）。
--    粒度: user_id
------------------------------------------------------------
    SELECT
        a.user_id,
        MAX(a.latest_order_no)                        AS order_count, -- その顧客の最大購入回数

        -- 商品は1注文内に複数あるため、代表注文(daily_rep_order_id)に含まれるものだけを連結する
        LISTAGG(DISTINCT CASE
                WHEN a.order_id = a.daily_rep_order_id THEN a.product_id
                END, ' / ')                           AS agg_product_id,
        LISTAGG(DISTINCT CASE
                WHEN a.order_id = a.daily_rep_order_id THEN a.product_name
                END, ' / ')                           AS agg_product_name,

        MAX(a.daily_rep_order_type)                   AS agg_order_type,
        MAX(a.daily_rep_payment_method)               AS agg_payment_method,
        MAX(a.daily_rep_latest_ad_code)               AS agg_latest_ad_code,

        MAX(a.ordered_date)                           AS max_ordered_date,
        MAX(a.shipment_date)                          AS max_shipment_date,

        SUM(a.quantity)                               AS total_quantity,
        SUM(a.discounted_amount_excl_point_excl_tax)  AS total_discounted_amount_excl_point_excl_tax,

        MAX(a.is_subsc)                               AS max_is_subsc,

        -- 1回目で「定期商品を2つ以上」買ったかどうかの優良顧客フラグ
        MAX(a.is_subsc_multi)                         AS max_is_subsc_multi,

        MAX(COALESCE(b.is_subsc_active, 0))           AS max_is_subsc_active,
        MAX(COALESCE(b.subsc_delivery_cycle, 0))      AS max_subsc_delivery_cycle,
        MAX(b.next_shipment_date)                     AS max_next_shipment_date,
        MAX(b.second_next_shipment_date)              AS max_second_next_shipment_date,

        MAX(a.daily_rep_vendor_name)                  AS agg_vendor_name,
        MAX(a.daily_rep_promo_product_name)           AS agg_promo_product_name,
        MAX(a.daily_rep_offer_name)                   AS agg_offer_name,
        MAX(a.daily_rep_lp_type)                      AS agg_lp_type,
        MAX(a.daily_rep_media_detail)                 AS agg_media_detail,
        MAX(a.is_first_multi_subsc)                   AS max_is_first_multi_subsc,
        MAX(a.is_first_single_to_multi_subsc)         AS max_is_first_single_to_multi_subsc,

        MAX(a.is_return_no_refund)                    AS max_is_return_no_refund,

        MAX(gender)                                   AS gender,
        MAX(current_age)                              AS current_age,
        MAX(prefecture_name)                          AS prefecture_name,
        MAX(prefecture_no)                            AS prefecture_no,
        MAX(is_null_dm_opt)                           AS is_null_dm_opt,
        MAX(is_email_subsc)                           AS is_email_subsc,
        MAX(is_cus_black)                             AS is_cus_black,
        MAX(is_cus_deleted_merged)                    AS is_cus_deleted_merged

    FROM
        (
            -- [サブクエリ] 絞り込み前にユーザーごとの全購入回数を算出しておく
            SELECT
                *,
                MAX(order_no) OVER(
                    PARTITION BY user_id
                ) AS latest_order_no
            FROM  prepare_f1_aggregation       -- 05. 代表フラグ伝播済みのデータ
        ) a

    LEFT JOIN
        subsc_delivery_schedule_source b  -- 06. の定期情報
    ON a.user_id = b.user_id

    WHERE
        a.order_no = 1                     -- 1回目（基準日時点）の注文のみ
      AND a.is_return_no_refund <> 1       -- ★重要: F1時点で返品されたデータはLTV起点から除外する
      AND a.is_cus_deleted_merged <> 1     -- 削除・統合顧客を除く

    GROUP BY
        a.user_id
),

agg_base_table_filtered_purchase_1st AS (
------------------------------------------------------------
-- 8. [テーブル集約] 2回目以降の購入情報の集約
--    F2, F3, F4 を横持ちにするための事前準備として、注文単位で集計します。
--    ※F1対象者（purchase_1stに存在するユーザー）の注文のみに絞り込んでいます。
--    ★全対象版の核心: ここでは返品を除外しません。返品されたF2〜F4もそのまま集約し、
--      次のStepで「返品フラグ」として出力できるようにします。
--    ★返品考慮版にする場合はこのCTEを丸ごと差し替えます。具体的な条件・コード例・
--      挙動の違いはこのクエリのREADME「返品考慮版にする場合」を参照してください。
--    粒度: user_id ✕ order_no
------------------------------------------------------------
    SELECT
        c.user_id,
        c.order_no,

        MAX(c.daily_rep_order_type)                   AS agg_order_type,
        MAX(c.daily_rep_payment_method)               AS agg_payment_method,

        MAX(c.ordered_date)                           AS max_ordered_date,
        MAX(c.shipment_date)                          AS max_shipment_date,

        SUM(c.quantity)                               AS total_quantity,
        SUM(c.discounted_amount_excl_point_excl_tax)  AS total_discounted_amount_excl_point_excl_tax,

        MAX(c.is_subsc)                               AS max_is_subsc,

        -- ▼ 返品情報関係（全対象版のみ出力する監査用フラグ）
        MAX(c.is_return_no_refund)                    AS max_is_return_no_refund

    FROM
        prepare_f1_aggregation c  -- 05. 代表フラグ伝播済みのデータ

    INNER JOIN
        purchase_1st d      -- 07. F1対象者リスト
    ON c.user_id = d.user_id

    GROUP BY
        c.user_id, c.order_no
),

user_table_with_purchase_from_1st_to_4th AS (
------------------------------------------------------------
-- 9. [テーブル横持ち変換] F1〜F4の情報をユーザー単位で1行に結合
--    顧客情報をベースに、F1、F2、F3、F4の各注文情報をLEFT JOINで繋ぎ合わせます。
--    粒度: user_id
------------------------------------------------------------
    SELECT
        f.user_id,
        f.gender,
        f.current_age,
        f.prefecture_name,
        f.prefecture_no,
        f.is_null_dm_opt,
        f.is_email_subsc,
        f.is_cus_black,
        f.is_cus_deleted_merged,

        -- ▼ purchase_1st の情報 (F1)
        f.order_count                                               AS order_count,
        f.agg_order_type                                            AS order_type_1st,
        f.agg_payment_method                                        AS payment_method_1st,
        f.agg_latest_ad_code                                        AS latest_ad_code_1st,
        f.agg_vendor_name                                           AS vendor_name_1st,
        f.agg_promo_product_name                                    AS promo_product_name_1st,
        f.agg_offer_name                                            AS offer_name_1st,
        f.agg_lp_type                                               AS lp_type_1st,
        f.agg_media_detail                                          AS media_detail_1st,
        f.agg_product_id                                            AS product_id_1st,
        f.agg_product_name                                          AS product_name_1st,
        f.max_is_subsc                                              AS is_subsc_1st,
        f.max_is_subsc_multi                                        AS is_subsc_multi_1st,
        f.max_ordered_date                                          AS ordered_date_1st,
        f.max_shipment_date                                         AS shipment_date_1st,
        f.total_quantity                                            AS total_quantity_1st,
        f.total_discounted_amount_excl_point_excl_tax               AS total_discounted_amount_excl_point_excl_tax_1st,
        f.max_is_first_multi_subsc                                  AS is_first_multi_subsc_1st,
        f.max_is_first_single_to_multi_subsc                        AS is_first_single_to_multi_subsc_1st,
        f.max_is_return_no_refund                                   AS is_return_no_refund_1st,

        -- ▼ purchase_2nd の情報 (F2)
        NULLIF(g.agg_payment_method, '')                            AS payment_method_2nd,
        COALESCE(g.max_is_subsc, 0)                                 AS is_subsc_2nd,
        g.max_ordered_date                                          AS ordered_date_2nd,
        g.max_shipment_date                                         AS shipment_date_2nd,
        COALESCE(g.total_quantity, 0)                               AS total_quantity_2nd,
        COALESCE(g.total_discounted_amount_excl_point_excl_tax, 0)  AS total_discounted_amount_excl_point_excl_tax_2nd,
        COALESCE(g.max_is_return_no_refund, 0)                      AS is_return_no_refund_2nd,

        -- ▼ purchase_3rd の情報 (F3)
        NULLIF(h.agg_payment_method, '')                            AS payment_method_3rd,
        COALESCE(h.max_is_subsc, 0)                                 AS is_subsc_3rd,
        h.max_ordered_date                                          AS ordered_date_3rd,
        h.max_shipment_date                                         AS shipment_date_3rd,
        COALESCE(h.total_quantity, 0)                               AS total_quantity_3rd,
        COALESCE(h.total_discounted_amount_excl_point_excl_tax, 0)  AS total_discounted_amount_excl_point_excl_tax_3rd,
        COALESCE(h.max_is_return_no_refund, 0)                      AS is_return_no_refund_3rd,

        -- ▼ purchase_4th の情報 (F4)
        NULLIF(i.agg_payment_method, '')                            AS payment_method_4th,
        COALESCE(i.max_is_subsc, 0)                                 AS is_subsc_4th,
        i.max_ordered_date                                          AS ordered_date_4th,
        i.max_shipment_date                                         AS shipment_date_4th,
        COALESCE(i.total_quantity, 0)                               AS total_quantity_4th,
        COALESCE(i.total_discounted_amount_excl_point_excl_tax, 0)  AS total_discounted_amount_excl_point_excl_tax_4th,
        COALESCE(i.max_is_return_no_refund, 0)                      AS is_return_no_refund_4th,

        -- ▼ 定期購入関係（予測用）
        f.max_is_subsc_active                                       AS is_subsc_active,
        f.max_subsc_delivery_cycle                                  AS subsc_delivery_cycle,
        f.max_next_shipment_date                                    AS next_shipment_date,
        f.max_second_next_shipment_date                             AS second_next_shipment_date

    FROM
        purchase_1st f     -- 07. F1情報

    -- F2情報の結合 (order_no = 2)
    LEFT JOIN
        agg_base_table_filtered_purchase_1st g  -- 08. の情報
    ON f.user_id = g.user_id
    AND g.order_no = 2

    -- F3情報の結合 (order_no = 3)
    LEFT JOIN
        agg_base_table_filtered_purchase_1st h  -- 08. の情報
    ON f.user_id = h.user_id
    AND h.order_no = 3

    -- F4情報の結合 (order_no = 4)
    LEFT JOIN
        agg_base_table_filtered_purchase_1st i  -- 08. の情報
    ON f.user_id = i.user_id
    AND i.order_no = 4
),

processed_01_user_from_f1_to_f4 AS (
------------------------------------------------------------
-- 10. [テーブル加工] 未出荷の場合の「出荷予定日」補完、および評価対象フラグの作成
--     離脱予測などのために、まだF2やF3が発生していない顧客に対しては、
--     定期台帳の「次回出荷予定日」などを用いて仮の出荷日をセットします。
--     ★重要: 解約済・休止中（is_subsc_active=0 または NULL）の場合は、
--      架空の売上予測が立ってしまうのを防ぐため、予定日はNULLのままにします。
--     ★重要2: 分析精度の向上のため、前回出荷日から「30日（おすすめ周期）」経過
--       していない場合は、まだ次の購入タイミングに達していないとみなし、
--       評価対象から除外（フラグ=0）する条件を付与しています。
--     粒度: user_id
------------------------------------------------------------
    SELECT
        *,

        -- 現在F1のみ完了の場合、F2出荷日に「次回出荷予定日」をセット（定期継続中のみ）
        CASE
            WHEN order_count = 1
             AND shipment_date_2nd IS NULL
             AND is_subsc_active = 1       THEN next_shipment_date
            ELSE shipment_date_2nd
        END AS shipment_date_2nd_calc,

        -- 現在F1のみ完了の場合、F3出荷日に「次々回予定日」をセット
        -- 現在F2まで完了の場合、F3出荷日に「次回予定日」をセット
        CASE
            WHEN order_count = 1
             AND shipment_date_3rd IS NULL
             AND is_subsc_active = 1       THEN second_next_shipment_date
            WHEN order_count = 2
             AND shipment_date_3rd IS NULL
             AND is_subsc_active = 1       THEN next_shipment_date
            ELSE shipment_date_3rd
        END AS shipment_date_3rd_calc,

        -- 同様のロジックでF4出荷予定日を計算（F1のみ完了の場合は周期日数を足す）
        CASE
            WHEN order_count = 1
             AND shipment_date_4th IS NULL
             AND is_subsc_active = 1       THEN DATEADD(day, subsc_delivery_cycle, second_next_shipment_date)
            WHEN order_count = 2
             AND shipment_date_4th IS NULL
             AND is_subsc_active = 1       THEN second_next_shipment_date
            WHEN order_count = 3
             AND shipment_date_4th IS NULL
             AND is_subsc_active = 1       THEN next_shipment_date
            ELSE shipment_date_4th
        END AS shipment_date_4th_calc,

        -- ▼ 実績フラグの作成
        -- 実際にシステム上で出荷された（＝予測ではなく実績がある）かどうかのフラグ
        CASE
            WHEN shipment_date_2nd IS NOT NULL THEN 1
            ELSE 0
        END AS is_shipment_2nd,

        CASE
            WHEN shipment_date_3rd IS NOT NULL THEN 1
            ELSE 0
        END AS is_shipment_3rd,

        CASE
            WHEN shipment_date_4th IS NOT NULL THEN 1
            ELSE 0
        END AS is_shipment_4th,

        -- ▼ 評価対象判定用の基準日（日本時間の現在から30日前）
        DATEADD(day, -30, CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE) AS target_date_30_days_ago

    FROM
        user_table_with_purchase_from_1st_to_4th -- 09. の情報
),

processed_02_user_from_f1_to_f4 AS (
------------------------------------------------------------
-- 11. [テーブル加工] リードタイム（購入間隔日数）の算出と対象フラグの付与
--     F1→F2、F2→F3 などの間に何日かかったかを計算します。
--     ※定期解約者など、補完日（calc）がNULLの場合は、日数もNULLになります。
--     また、前回出荷から30日経過しているかどうかの「評価対象フラグ」を作成します。
--     粒度: user_id
------------------------------------------------------------
    SELECT
        *,

        DATEDIFF(day, shipment_date_1st, shipment_date_2nd_calc)      AS elapsed_days_f1_f2,
        DATEDIFF(day, shipment_date_2nd_calc, shipment_date_3rd_calc) AS elapsed_days_f2_f3,
        DATEDIFF(day, shipment_date_3rd_calc, shipment_date_4th_calc) AS elapsed_days_f3_f4,

        -- ▼ 各回目の評価対象フラグ（30日ルール）
        -- F2の評価対象: F1の出荷日から30日を経過していること
        CASE
            WHEN shipment_date_1st < target_date_30_days_ago THEN 1
            ELSE 0
        END AS is_target_2nd,

        -- F3の評価対象: F2の出荷日（または補完予定日）から30日を経過していること
        CASE
            WHEN shipment_date_2nd_calc < target_date_30_days_ago THEN 1
            ELSE 0
        END AS is_target_3rd,

        -- F4の評価対象: F3の出荷日（または補完予定日）から30日を経過していること
        CASE
            WHEN shipment_date_3rd_calc < target_date_30_days_ago THEN 1
            ELSE 0
        END AS is_target_4th

    FROM
        processed_01_user_from_f1_to_f4 -- 10. の情報
)

----------------------------------------------------------------------
-- 12. [最終出力] 分析用データマートの整形
--     粒度: user_id
----------------------------------------------------------------------
SELECT
    -- ====== ID系 ======
    user_id                     AS "ユーザーID",

    -- ====== 顧客情報 ======
    gender                      AS "性別",
    current_age                 AS "年齢",
    prefecture_no               AS "都道府県コード",
    prefecture_name             AS "都道府県名",
    is_null_dm_opt              AS "DM可フラグ",
    is_email_subsc              AS "メルマガ可フラグ",

    -- ====== 購入１回目 (F1) ======
    order_type_1st                                   AS "1回目_受注経路",
    latest_ad_code_1st                                AS "1回目_受注プロモ",
    product_id_1st                                    AS "1回目_商品ID",
    product_name_1st                                  AS "1回目_商品名",
    is_subsc_1st                                       AS "1回目_定期フラグ",
    is_subsc_multi_1st                                 AS "1回目_複数点定期フラグ",
    is_subsc_active                                    AS "定期継続フラグ_対象品",
    ordered_date_1st                                   AS "1回目_受注日",
    shipment_date_1st                                  AS "1回目_出荷日",
    total_quantity_1st                                 AS "1回目_注文数",
    total_discounted_amount_excl_point_excl_tax_1st   AS "1回目_P使用後_割引後金額 (税抜)",

    -- ====== 実データ ======
    -- ====== 購入２回目 (F2) ======
    is_subsc_2nd                                       AS "2回目_定期フラグ",
    is_shipment_2nd                                    AS "2回目_出荷フラグ",
    ordered_date_2nd                                   AS "2回目_受注日",
    shipment_date_2nd_calc                             AS "2回目_出荷日",
    elapsed_days_f1_f2                                 AS "1回目→2回目_出荷日数",
    total_quantity_2nd                                 AS "2回目_注文数",
    total_discounted_amount_excl_point_excl_tax_2nd   AS "2回目_P使用後_割引後金額 (税抜)",

    -- ====== 購入３回目 (F3) ======
    is_subsc_3rd                                       AS "3回目_定期フラグ",
    is_shipment_3rd                                    AS "3回目_出荷フラグ",
    ordered_date_3rd                                   AS "3回目_受注日",
    shipment_date_3rd_calc                             AS "3回目_出荷日",
    elapsed_days_f2_f3                                 AS "2回目→3回目_出荷日数",
    total_quantity_3rd                                 AS "3回目_注文数",
    total_discounted_amount_excl_point_excl_tax_3rd   AS "3回目_P使用後_割引後金額 (税抜)",

    -- ====== 購入４回目 (F4) ======
    is_subsc_4th                                       AS "4回目_定期フラグ",
    is_shipment_4th                                    AS "4回目_出荷フラグ",
    ordered_date_4th                                   AS "4回目_受注日",
    shipment_date_4th_calc                             AS "4回目_出荷日",
    elapsed_days_f3_f4                                 AS "3回目→4回目_出荷日数",
    total_quantity_4th                                 AS "4回目_注文数",
    total_discounted_amount_excl_point_excl_tax_4th   AS "4回目_P使用後_割引後金額 (税抜)",

    -- ====== データ集計用 ======
    -- ====== 購入２回目 (F2) ======
    is_target_2nd                                      AS "2回目_対象フラグ",

    CASE
        WHEN is_target_2nd = 1 THEN is_shipment_2nd
        ELSE 0
    END                                                AS "2回目_購入フラグ",

    -- すでに出荷済み、もしくは、未出荷だが定期継続中の場合は生存(1)とする
    CASE
        WHEN is_target_2nd = 1
         AND is_shipment_2nd = 1  THEN 1
        WHEN is_target_2nd = 1
         AND is_shipment_2nd <> 1
         AND is_subsc_active = 1  THEN 1
        ELSE 0
    END                                                AS "2回目_継続フラグ",

    -- ====== 購入３回目 (F3) ======
    is_target_3rd                                      AS "3回目_対象フラグ",

    CASE
        WHEN is_target_3rd = 1 THEN is_shipment_3rd
        ELSE 0
    END                                                AS "3回目_購入フラグ",

    CASE
        WHEN is_target_3rd = 1
         AND is_shipment_3rd = 1  THEN 1
        WHEN is_target_3rd = 1
         AND is_shipment_3rd <> 1
         AND is_subsc_active = 1  THEN 1
        ELSE 0
    END                                                AS "3回目_継続フラグ",

    -- ====== 購入４回目 (F4) ======
    is_target_4th                                      AS "4回目_対象フラグ",

    CASE
        WHEN is_target_4th = 1 THEN is_shipment_4th
        ELSE 0
    END                                                AS "4回目_購入フラグ",

    CASE
        WHEN is_target_4th = 1
         AND is_shipment_4th = 1  THEN 1
        WHEN is_target_4th = 1
         AND is_shipment_4th <> 1
         AND is_subsc_active = 1  THEN 1
        ELSE 0
    END                                                AS "4回目_継続フラグ",

    -- ====== 支払情報関係 ======
    payment_method_1st                                 AS "1回目_支払方法",
    payment_method_2nd                                 AS "2回目_支払方法",
    payment_method_3rd                                 AS "3回目_支払方法",
    payment_method_4th                                 AS "4回目_支払方法",

    -- ====== 返品情報関係（全対象版のみ出力） ======
    is_return_no_refund_1st                            AS "1回目_返品(保証除く)フラグ",
    is_return_no_refund_2nd                            AS "2回目_返品(保証除く)フラグ",
    is_return_no_refund_3rd                            AS "3回目_返品(保証除く)フラグ",
    is_return_no_refund_4th                            AS "4回目_返品(保証除く)フラグ",

    -- ====== 媒体情報関係 ======
    vendor_name_1st                                    AS "1回目_取引先名",
    promo_product_name_1st                             AS "1回目_販促商品名",
    offer_name_1st                                      AS "1回目_オファー名",
    TRIM(SPLIT_PART(lp_type_1st, '/', 1))              AS "FV",
    TRIM(SPLIT_PART(lp_type_1st, '/', 3))              AS "BOT",
    TRIM(SPLIT_PART(lp_type_1st, '/', 2))              AS "アップセル",
    media_detail_1st                                    AS "1回目_媒体名",
    is_first_multi_subsc_1st                           AS "1回目_初回複数定期フラグ",
    is_first_single_to_multi_subsc_1st                 AS "1回目_初回単品→複数定期フラグ"

FROM
    processed_02_user_from_f1_to_f4   -- 11. の情報

;
