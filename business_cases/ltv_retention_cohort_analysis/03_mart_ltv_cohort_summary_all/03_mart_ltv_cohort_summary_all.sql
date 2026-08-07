/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 F1〜F4の横持ち受注データ（前工程のGUIパラメータ層で特定プロモ・特定期間に限定済みのテーブル）と、
 広告のアクセスデータ（クリック・CV）を結合し、ダッシュボード表示用に「月別」「取引先別」
 「コード別」といった様々な粒度でRollup（小計・合計）を集計したサマリーデータマートを作成します。
 受注側・アクセス側の双方を「オファー／LP種別（FV・BOT・アップセル）／媒体詳細」まで
 同一粒度に揃えることで、これらの軸を横断した精緻な分析を可能にしています（全対象版）。
  Monthly/Vendor/Code Rollup Summary Mart (All-Targets Variant) — Marts Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. 対象母集団（GUIパラメータ層による絞り込み）
     本クエリの入力である `stg_ltv_cohort_target_period_all` は、前工程のGUIパラメータ層にて
     「1回目の受注プロモが対象パターンに一致（ネット媒体） かつ 1回目の受注日が指定期間内」の
     顧客のみに限定済みです。対象条件（期間や媒体条件）を変更したい場合は、SQL側ではなく
     大元のGUIパラメータ条件（詳細はケース全体READMEの「GUIパラメータ層」節を参照）を
     変更してください。母集団が変わると本クエリの全ての集計結果に影響します。
  2. ゼロ埋めカレンダー（再帰CTEの活用）
     受注実績がない月でも、グラフ上で「0」として表示（歯抜け防止）させるため、
     再帰CTE（WITH RECURSIVE）を使って最初の受注月から現在までの「月軸」を動的に生成し、
     FULL OUTER JOINで強制的にマウントしています。
  3. GROUPING SETSによる多重集計
     「月/コード別」「取引先別」「全体合計」など6パターンの集計を、UNION ALLを使わずに
     1回のパスで高速に生成しています。
  4. ディメンションキーを揃えたJOIN（JOIN爆発防止の安全装置）
     受注側・アクセス側それぞれのGROUPING SETSに「オファー／LP種別／媒体詳細」を共通で
     組み込んだ上で、統合ステップの結合条件でも両者を完全に同じキー構成（7項目）で
     突き合わせています。過去にこのキー構成が片側だけ更新され、クロス結合による実績値の
     増殖という重大な障害が発生したことがあります。詳細と再発防止策はケース全体READMEの
     運用・保守セクションを参照してください。
  5. 小計行の複製と2パス最適化ソート制御（ベタ貼り対応）
     GROUPING SETSで1行だけ生成された「月小計」をコード別用・取引先別用に複製しつつ、
     UNION ALLのスキャン回数を抑えた2ブロック結合で高速にレポート表示順を確定させています。
  6. クリック/CVデータの期間絞り込み
     受注側（F1〜F4）の対象母集団が既に特定の受注期間に限定されているため、アクセス側
     （クリック・CV）のデータもその期間（最古〜最新の受注日）だけに絞り込んで取得します。

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
  1. extract_base_metrics_from_f1_to_f4
     対象期間限定済みの横持ちテーブルから受注・LTV指標を取得し、コース別・回数別にフラグを数値化
  2. min_max_order_date
     受注データの最古・最新受注日を取得（アクセスデータ絞り込みの基準値）
  3. extract_click_cv_metrics
     広告アクセスデータ（クリック・CV）を対象期間内に限定して取得し、受注側と同一の
     ディメンション粒度に揃える
  4. agg_orders_by_grouping_sets
     受注データをGROUPING SETSで6パターンの粒度に集計
  5. generate_zero_fill_calendar_month
     過去最古の受注月から現在までの連続した「月軸」を生成
  6. apply_zero_fill_to_orders
     集計結果にカレンダーを結合し、NULL項目をハイフン等で埋める
  7. agg_clicks_cvs_by_grouping_sets
     アクセスデータをGROUPING SETSで、受注側(Step 4)と完全に同一のディメンション構成で集計
  8. integrate_orders_and_clicks_cvs
     受注集計とアクセス集計を、月なし系・月あり系の双方とも全キーを揃えて結合
  9. prepare_vendor_subtotals
     取引先別ブロックの下に配置するための「月小計」行を複製・準備
  10. arrange_report_blocks
      結合結果を2回のパスで効率的にまとめ、表示順序キー(row_type_no)を付与
  11. 最終出力
      分析用指標を日本語カラム名で出力し、レポートフォーマット順にソート

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  row_type_adjusted, ym_label（GROUPING SETSにより複数の粒度（月/コード別、月/取引先別、
  コード別、取引先別、月小計、合計）が1つの結果セットに混在する）

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  なし（複数粒度のロールアップ集計マートのため単一主キーは存在しない。一意性は
  row_type_adjusted × ym_label × コード × 取引先 × オファー × FV/BOT/アップセル × 媒体
  の組み合わせで担保される）

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: WITH RECURSIVE, GROUPING SETS, GROUPING(), FULL OUTER
  JOIN, DATE_TRUNC/DATEADD, CONVERT_TIMEZONE)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 LTV/残存率分析用 月次/取引先/コード別サマリーマート（全対象版）
  mart_ltv_cohort_summary_all
==============================================================================================
*/

WITH RECURSIVE
extract_base_metrics_from_f1_to_f4 AS (
------------------------------------------------------------
-- 1. [ベース抽出] 受注・LTV指標の取得とコース別フラグの展開
--    前工程の横持ちテーブル（特定プロモ×特定期間に限定済みのGUIパラメータ層出力）から
--    データを取得し、コース（初回2点 / 初回1点→2点）ごとにF2〜F4の対象・購入・継続状況を
--    0/1の数値としてフラグ化します。
--    粒度: user_id
------------------------------------------------------------
    SELECT
        user_id,

        -- ▼ 顧客情報（継続・解約別での平均年齢算出用）
        current_age,

        CASE
            WHEN is_subsc_active = 1 THEN current_age
            ELSE NULL
        END AS current_age_active,

        CASE
            WHEN is_subsc_active <> 1 THEN current_age
            ELSE NULL
        END AS current_age_cancel,

        is_email_subsc,

        -- ▼ 購入１回目 (F1)
        is_subsc_1st,
        is_subsc_2_plus_1st,
        is_subsc_active,
        ordered_date_1st,

        DATE_TRUNC('MONTH', ordered_date_1st) AS ordered_month_1st,
        MIN(ordered_date_1st) OVER()          AS min_ordered_date_1st,

        -- ▼ 購入２回目 (F2) 分岐
        -- 初回2点コースの場合のF2実績
        CASE WHEN is_first_2_subsc_1st = 1 AND is_first_1_to_second_2_subsc_1st <> 1 THEN raw_is_target_2nd
             ELSE 0 END AS is_target_2nd_first_2,
        CASE WHEN is_first_2_subsc_1st = 1 AND is_first_1_to_second_2_subsc_1st <> 1 THEN raw_is_purchase_2nd
             ELSE 0 END AS is_purchase_2nd_first_2,
        CASE WHEN is_first_2_subsc_1st = 1 AND is_first_1_to_second_2_subsc_1st <> 1 THEN raw_is_continuation_2nd
             ELSE 0 END AS is_subsc_active_2nd_first_2,

        -- 初回1点→2回目2点コースの場合のF2実績
        CASE WHEN is_first_2_subsc_1st <> 1 AND is_first_1_to_second_2_subsc_1st = 1 THEN raw_is_target_2nd
             ELSE 0 END AS is_target_2nd_first_1_to_2,
        CASE WHEN is_first_2_subsc_1st <> 1 AND is_first_1_to_second_2_subsc_1st = 1 THEN raw_is_purchase_2nd
             ELSE 0 END AS is_purchase_2nd_first_1_to_2,
        CASE WHEN is_first_2_subsc_1st <> 1 AND is_first_1_to_second_2_subsc_1st = 1 THEN raw_is_continuation_2nd
             ELSE 0 END AS is_subsc_active_2nd_first_1_to_2,

        -- ▼ 購入３回目 (F3) 分岐
        CASE WHEN is_first_2_subsc_1st = 1 AND is_first_1_to_second_2_subsc_1st <> 1 THEN raw_is_target_3rd
             ELSE 0 END AS is_target_3rd_first_2,
        CASE WHEN is_first_2_subsc_1st = 1 AND is_first_1_to_second_2_subsc_1st <> 1 THEN raw_is_purchase_3rd
             ELSE 0 END AS is_purchase_3rd_first_2,
        CASE WHEN is_first_2_subsc_1st = 1 AND is_first_1_to_second_2_subsc_1st <> 1 THEN raw_is_continuation_3rd
             ELSE 0 END AS is_subsc_active_3rd_first_2,

        CASE WHEN is_first_2_subsc_1st <> 1 AND is_first_1_to_second_2_subsc_1st = 1 THEN raw_is_target_3rd
             ELSE 0 END AS is_target_3rd_first_1_to_2,
        CASE WHEN is_first_2_subsc_1st <> 1 AND is_first_1_to_second_2_subsc_1st = 1 THEN raw_is_purchase_3rd
             ELSE 0 END AS is_purchase_3rd_first_1_to_2,
        CASE WHEN is_first_2_subsc_1st <> 1 AND is_first_1_to_second_2_subsc_1st = 1 THEN raw_is_continuation_3rd
             ELSE 0 END AS is_subsc_active_3rd_first_1_to_2,

        -- ▼ 購入４回目 (F4) 分岐
        CASE WHEN is_first_2_subsc_1st = 1 AND is_first_1_to_second_2_subsc_1st <> 1 THEN raw_is_target_4th
             ELSE 0 END AS is_target_4th_first_2,
        CASE WHEN is_first_2_subsc_1st = 1 AND is_first_1_to_second_2_subsc_1st <> 1 THEN raw_is_purchase_4th
             ELSE 0 END AS is_purchase_4th_first_2,
        CASE WHEN is_first_2_subsc_1st = 1 AND is_first_1_to_second_2_subsc_1st <> 1 THEN raw_is_continuation_4th
             ELSE 0 END AS is_subsc_active_4th_first_2,

        CASE WHEN is_first_2_subsc_1st <> 1 AND is_first_1_to_second_2_subsc_1st = 1 THEN raw_is_target_4th
             ELSE 0 END AS is_target_4th_first_1_to_2,
        CASE WHEN is_first_2_subsc_1st <> 1 AND is_first_1_to_second_2_subsc_1st = 1 THEN raw_is_purchase_4th
             ELSE 0 END AS is_purchase_4th_first_1_to_2,
        CASE WHEN is_first_2_subsc_1st <> 1 AND is_first_1_to_second_2_subsc_1st = 1 THEN raw_is_continuation_4th
             ELSE 0 END AS is_subsc_active_4th_first_1_to_2,

        -- ▼ 媒体情報関係
        latest_ad_code_1st,
        vendor_name_1st,
        promo_product_name_1st,
        offer_name_1st,
        lp_fv_type_1st,
        lp_bot_type_1st,
        lp_upsell_type_1st,
        media_detail_1st,
        is_first_2_subsc_1st,
        is_first_1_to_second_2_subsc_1st

    FROM
        -- GUIパラメータ層にて「1回目の受注プロモが対象パターンに一致（ネット媒体） かつ
        -- 1回目の受注日が指定期間内（本モデルでは2024/03/01〜2024/03/15）」に限定済み。
        -- 対象条件を変更したい場合は、大元のGUIパラメータ条件を変更してください
        -- （詳細はケース全体READMEの「GUIパラメータ層」節を参照）
        stg_ltv_cohort_target_period_all
),

min_max_order_date AS (
------------------------------------------------------------
-- 2. [採番基準値] 受注日の最大・最小の取得
--    受注データ（Step 1）に含まれる受注日の最古・最新を1行で取得します。
--    後続のクリック/CVデータ（Step 3）を、この期間内だけに絞り込むための基準値として使用します。
--    ★対象母集団が既にGUIパラメータ層（1回目の受注日が特定期間）で絞られているため、
--      この最古〜最新の範囲も自ずと限定的になります。
--    粒度: 1行のみ
------------------------------------------------------------
    SELECT
        MIN(ordered_date_1st) AS min_ordered_date_1st,
        MAX(ordered_date_1st) AS max_ordered_date_1st
    FROM
        extract_base_metrics_from_f1_to_f4 -- 01. の情報
),

extract_click_cv_metrics AS (
------------------------------------------------------------
-- 3. [ベース抽出] 媒体アクセスマスタの取得
--    広告のクリック数とCV（コンバージョン）数を取得し、CPA算出の土台とします。
--    CROSS JOINでmin_max_order_date（Step 2）の期間を全行に持たせ、WHERE句で受注データの
--    受注日範囲内のみに絞り込むことで、無関係な期間のアクセスデータの読み込みを防いでいます。
--    媒体マスタから「オファー／LP種別（FV・BOT・アップセル）／媒体詳細」を取得し、
--    受注側（extract_base_metrics_from_f1_to_f4）と同一のディメンション粒度に揃えます。
--    粒度: ordered_month, latest_ad_code, vendor_name, offer_name, lp_fv_type, lp_bot_type,
--          lp_upsell_type, media_detail
------------------------------------------------------------
    SELECT
        ordered_month,
        latest_ad_code,
        vendor_name,
        offer_name,
        lp_fv_type,
        lp_bot_type,
        lp_upsell_type,
        media_detail,
        SUM(click_count)  AS click_count,
        SUM(cv_count)     AS cv_count

    FROM
        (
            SELECT
                ordered_date,
                ordered_month,
                latest_ad_code,
                vendor_name,
                offer_name,
                TRIM(SPLIT_PART(lp_content, '/', 1))  AS lp_fv_type,
                TRIM(SPLIT_PART(lp_content, '/', 3))  AS lp_bot_type,
                TRIM(SPLIT_PART(lp_content, '/', 2))  AS lp_upsell_type,
                media_detail,
                click_count,
                cv_count
            FROM
                raw_ad_click_cv_log  -- 広告クリック・CV結果ログ
            CROSS JOIN
                min_max_order_date i -- 02. 独立させた期間
            WHERE
               product_brand_code = 'TARGET_PRODUCT_LINE'  -- 対象化粧品ブランドに限定
              AND ordered_date >= i.min_ordered_date_1st
              AND ordered_date <= i.max_ordered_date_1st
        )

    GROUP BY
        ordered_month, latest_ad_code, vendor_name, offer_name,
        lp_fv_type, lp_bot_type, lp_upsell_type, media_detail
),

agg_orders_by_grouping_sets AS (
------------------------------------------------------------
-- 4. [集計] 受注データの多重Rollup（GROUPING SETS）
--    BIツール側で計算不要にするため、「月/コード別」「取引先別」「全体合計」など
--    6パターンの粒度を1回の処理で一括生成します。
--    粒度: row_type, ordered_month_1st (動的粒度)
------------------------------------------------------------
    SELECT
        GROUPING(ordered_month_1st)            AS g_month,
        GROUPING(vendor_name_1st)               AS g_media,
        GROUPING(latest_ad_code_1st)           AS g_code,

        -- どの粒度で集計された行かをラベル付けする
        CASE
            WHEN GROUPING(ordered_month_1st) <> 1
             AND GROUPING(vendor_name_1st) <> 1
             AND GROUPING(latest_ad_code_1st) = 1  THEN '月/取引先別'
            WHEN GROUPING(ordered_month_1st) = 1
             AND GROUPING(vendor_name_1st) <> 1
             AND GROUPING(latest_ad_code_1st) <> 1  THEN 'コード別'
            WHEN GROUPING(ordered_month_1st) = 1
             AND GROUPING(vendor_name_1st) <> 1
             AND GROUPING(latest_ad_code_1st) = 1   THEN '取引先別'
            WHEN GROUPING(ordered_month_1st) <> 1
             AND GROUPING(vendor_name_1st) = 1
             AND GROUPING(latest_ad_code_1st) = 1   THEN '月小計'
            WHEN GROUPING(ordered_month_1st) = 1
             AND GROUPING(vendor_name_1st) = 1
             AND GROUPING(latest_ad_code_1st) = 1   THEN '合計'
            ELSE '月/コード別'
        END AS row_type,

        ordered_month_1st,
        latest_ad_code_1st,
        vendor_name_1st,
        promo_product_name_1st,
        offer_name_1st,
        lp_fv_type_1st,
        lp_bot_type_1st,
        lp_upsell_type_1st,
        media_detail_1st,

        -- メトリクスの集計（合計と平均）
        AVG(current_age)                       AS avg_current_age,
        AVG(current_age_active)                AS avg_current_age_active,
        AVG(current_age_cancel)                AS avg_current_age_cancel,
        COUNT(*)                               AS order_count,
        SUM(is_email_subsc)                    AS sum_is_email_subsc,
        SUM(is_subsc_1st)                      AS sum_is_subsc_1st,
        SUM(is_subsc_2_plus_1st)               AS sum_is_subsc_2_plus_1st,
        SUM(is_subsc_active)                   AS sum_is_subsc_active,
        SUM(is_target_2nd_first_2)             AS sum_is_target_2nd_first_2,
        SUM(is_purchase_2nd_first_2)           AS sum_is_purchase_2nd_first_2,
        SUM(is_subsc_active_2nd_first_2)       AS sum_is_subsc_active_2nd_first_2,
        SUM(is_target_2nd_first_1_to_2)        AS sum_is_target_2nd_first_1_to_2,
        SUM(is_purchase_2nd_first_1_to_2)      AS sum_is_purchase_2nd_first_1_to_2,
        SUM(is_subsc_active_2nd_first_1_to_2)  AS sum_is_subsc_active_2nd_first_1_to_2,
        SUM(is_target_3rd_first_2)             AS sum_is_target_3rd_first_2,
        SUM(is_purchase_3rd_first_2)           AS sum_is_purchase_3rd_first_2,
        SUM(is_subsc_active_3rd_first_2)       AS sum_is_subsc_active_3rd_first_2,
        SUM(is_target_3rd_first_1_to_2)        AS sum_is_target_3rd_first_1_to_2,
        SUM(is_purchase_3rd_first_1_to_2)      AS sum_is_purchase_3rd_first_1_to_2,
        SUM(is_subsc_active_3rd_first_1_to_2)  AS sum_is_subsc_active_3rd_first_1_to_2,
        SUM(is_target_4th_first_2)             AS sum_is_target_4th_first_2,
        SUM(is_purchase_4th_first_2)           AS sum_is_purchase_4th_first_2,
        SUM(is_subsc_active_4th_first_2)       AS sum_is_subsc_active_4th_first_2,
        SUM(is_target_4th_first_1_to_2)        AS sum_is_target_4th_first_1_to_2,
        SUM(is_purchase_4th_first_1_to_2)      AS sum_is_purchase_4th_first_1_to_2,
        SUM(is_subsc_active_4th_first_1_to_2)  AS sum_is_subsc_active_4th_first_1_to_2,
        MIN(min_ordered_date_1st)              AS min_ordered_date_1st

    FROM
        extract_base_metrics_from_f1_to_f4  -- 01. の情報

    GROUP BY
        GROUPING SETS (
            (ordered_month_1st, latest_ad_code_1st, vendor_name_1st, promo_product_name_1st, offer_name_1st, lp_fv_type_1st, lp_bot_type_1st, lp_upsell_type_1st, media_detail_1st),
            (ordered_month_1st, vendor_name_1st, promo_product_name_1st, offer_name_1st, lp_fv_type_1st, lp_bot_type_1st, lp_upsell_type_1st, media_detail_1st),
            (latest_ad_code_1st, vendor_name_1st, promo_product_name_1st, offer_name_1st, lp_fv_type_1st, lp_bot_type_1st, lp_upsell_type_1st, media_detail_1st),
            (vendor_name_1st, promo_product_name_1st, offer_name_1st, lp_fv_type_1st, lp_bot_type_1st, lp_upsell_type_1st, media_detail_1st),
            (ordered_month_1st),
            ()
        )
),

generate_zero_fill_calendar_month AS (
------------------------------------------------------------
-- 5. [カレンダー生成] 再帰CTEによる動的な月軸の構築
--    過去最古の受注月から、現在までの「連続したカレンダー月（min_ym）」を作成します。
--    これにより、受注がゼロの月であってもグラフに「0」として表示可能になります。
--    ※アンカー部分はagg_orders_by_grouping_setsをMIN()で集約し、必ず単一行になるようにしています
--      （GROUPING SETSにより複数行が返る集計結果を直接使うと、再帰の起点が重複行のまま
--      複製されてしまうため）。
--    粒度: min_ym
------------------------------------------------------------
    SELECT
        MIN(DATE_TRUNC('MONTH', min_ordered_date_1st)) AS min_ym
    FROM
        agg_orders_by_grouping_sets -- 04. の情報

    UNION ALL

    SELECT
        DATEADD('MONTH', 1, min_ym)
    FROM
        generate_zero_fill_calendar_month
    WHERE
        min_ym < DATE_TRUNC('MONTH', CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE)
),

apply_zero_fill_to_orders AS (
------------------------------------------------------------
-- 6. [結合・補完] カレンダーの適用とNULL埋め処理
--    生成したカレンダーと集計結果をFULL OUTER JOINし、受注がない月でも行が存在するように
--    マウント（ゼロ埋め）します。
--    ★row_typeの判定は「a.row_type IS NULL」（＝aに元々レコードが存在しない＝真の欠損月）を
--      基準にしており、月が集計軸に含まれないコード別・取引先別・合計行（これらもa.ordered_
--      month_1stはNULLだがa.row_typeには値がある）と、月軸補完で新規追加された行（a.row_type
--      もNULL）を正しく区別している。判定列をordered_month_1stに戻すと、コード別等の実測値が
--      誤って0埋めされる不具合が再発するため注意。
--    粒度: row_type, ordered_month_1st
------------------------------------------------------------
    SELECT
        CASE WHEN a.row_type IS NULL AND b.min_ym IS NOT NULL THEN '月小計'
             ELSE a.row_type END AS row_type,

        CASE WHEN a.row_type IS NULL THEN b.min_ym ELSE a.ordered_month_1st END              AS ordered_month_1st,
        CASE WHEN a.row_type IS NULL THEN '-' ELSE a.latest_ad_code_1st END                  AS latest_ad_code_1st,
        CASE WHEN a.row_type IS NULL THEN '-' ELSE a.vendor_name_1st END                     AS vendor_name_1st,
        CASE WHEN a.row_type IS NULL THEN '-' ELSE a.promo_product_name_1st END              AS promo_product_name_1st,
        CASE WHEN a.row_type IS NULL THEN '-' ELSE a.offer_name_1st END                      AS offer_name_1st,
        CASE WHEN a.row_type IS NULL THEN '-' ELSE a.lp_fv_type_1st END                      AS lp_fv_type_1st,
        CASE WHEN a.row_type IS NULL THEN '-' ELSE a.lp_bot_type_1st END                     AS lp_bot_type_1st,
        CASE WHEN a.row_type IS NULL THEN '-' ELSE a.lp_upsell_type_1st END                  AS lp_upsell_type_1st,
        CASE WHEN a.row_type IS NULL THEN '-' ELSE a.media_detail_1st END                    AS media_detail_1st,

        CASE WHEN a.row_type IS NULL THEN NULL ELSE a.avg_current_age END                    AS avg_current_age,
        CASE WHEN a.row_type IS NULL THEN NULL ELSE a.avg_current_age_active END             AS avg_current_age_active,
        CASE WHEN a.row_type IS NULL THEN NULL ELSE a.avg_current_age_cancel END             AS avg_current_age_cancel,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.order_count END                           AS order_count,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_email_subsc END                    AS sum_is_email_subsc,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_subsc_1st END                      AS sum_is_subsc_1st,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_subsc_2_plus_1st END               AS sum_is_subsc_2_plus_1st,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_subsc_active END                   AS sum_is_subsc_active,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_target_2nd_first_2 END             AS sum_is_target_2nd_first_2,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_purchase_2nd_first_2 END           AS sum_is_purchase_2nd_first_2,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_subsc_active_2nd_first_2 END       AS sum_is_subsc_active_2nd_first_2,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_target_2nd_first_1_to_2 END        AS sum_is_target_2nd_first_1_to_2,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_purchase_2nd_first_1_to_2 END      AS sum_is_purchase_2nd_first_1_to_2,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_subsc_active_2nd_first_1_to_2 END  AS sum_is_subsc_active_2nd_first_1_to_2,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_target_3rd_first_2 END             AS sum_is_target_3rd_first_2,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_purchase_3rd_first_2 END           AS sum_is_purchase_3rd_first_2,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_subsc_active_3rd_first_2 END       AS sum_is_subsc_active_3rd_first_2,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_target_3rd_first_1_to_2 END        AS sum_is_target_3rd_first_1_to_2,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_purchase_3rd_first_1_to_2 END      AS sum_is_purchase_3rd_first_1_to_2,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_subsc_active_3rd_first_1_to_2 END  AS sum_is_subsc_active_3rd_first_1_to_2,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_target_4th_first_2 END             AS sum_is_target_4th_first_2,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_purchase_4th_first_2 END           AS sum_is_purchase_4th_first_2,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_subsc_active_4th_first_2 END       AS sum_is_subsc_active_4th_first_2,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_target_4th_first_1_to_2 END        AS sum_is_target_4th_first_1_to_2,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_purchase_4th_first_1_to_2 END      AS sum_is_purchase_4th_first_1_to_2,
        CASE WHEN a.row_type IS NULL THEN 0 ELSE a.sum_is_subsc_active_4th_first_1_to_2 END  AS sum_is_subsc_active_4th_first_1_to_2,

        COALESCE(
            TO_VARCHAR(YEAR(CASE WHEN a.row_type IS NULL THEN b.min_ym ELSE a.ordered_month_1st END)) || '年'
             || TO_VARCHAR(MONTH(CASE WHEN a.row_type IS NULL THEN b.min_ym ELSE a.ordered_month_1st END)) || '月'
        , '-') AS ym_label

    FROM
        agg_orders_by_grouping_sets a  -- 04. の情報

    FULL OUTER JOIN
        generate_zero_fill_calendar_month b  -- 05. の情報
    ON a.ordered_month_1st = b.min_ym
    AND a.row_type = '月小計'
),

agg_clicks_cvs_by_grouping_sets AS (
------------------------------------------------------------
-- 7. [集計] アクセスデータの多重Rollup（GROUPING SETS）
--    受注データと結合できるように、広告クリック・CV数についても全く同じ6パターンの粒度で
--    集計行を作成します。
--    ★「月のみ (ordered_month)」「全体合計 ()」の2タプルには、あえてオファー等の詳細
--      ディメンションを含めていません。ここに含めてしまうと「月小計」「合計」の粒度が
--      崩れるため、変更しないでください。
--    粒度: row_type, ordered_month（動的粒度）
------------------------------------------------------------
    SELECT
        GROUPING(ordered_month)            AS g_month,
        GROUPING(vendor_name)               AS g_media,
        GROUPING(latest_ad_code)           AS g_code,

        CASE
            WHEN GROUPING(ordered_month) <> 1
             AND GROUPING(vendor_name) <> 1
             AND GROUPING(latest_ad_code) = 1  THEN '月/取引先別'
            WHEN GROUPING(ordered_month) = 1
             AND GROUPING(vendor_name) <> 1
             AND GROUPING(latest_ad_code) <> 1  THEN 'コード別'
            WHEN GROUPING(ordered_month) = 1
             AND GROUPING(vendor_name) <> 1
             AND GROUPING(latest_ad_code) = 1   THEN '取引先別'
            WHEN GROUPING(ordered_month) <> 1
             AND GROUPING(vendor_name) = 1
             AND GROUPING(latest_ad_code) = 1   THEN '月小計'
            WHEN GROUPING(ordered_month) = 1
             AND GROUPING(vendor_name) = 1
             AND GROUPING(latest_ad_code) = 1   THEN '合計'
            ELSE '月/コード別'
        END AS row_type,

        ordered_month,
        latest_ad_code,
        vendor_name,
        offer_name,
        lp_fv_type,
        lp_bot_type,
        lp_upsell_type,
        media_detail,
        SUM(click_count)  AS sum_click_count,
        SUM(cv_count)     AS sum_cv_count

    FROM
        extract_click_cv_metrics  -- 03. の情報

    GROUP BY
        GROUPING SETS (
            (ordered_month, latest_ad_code, vendor_name, offer_name, lp_fv_type, lp_bot_type, lp_upsell_type, media_detail),
            (ordered_month, vendor_name, offer_name, lp_fv_type, lp_bot_type, lp_upsell_type, media_detail),
            (latest_ad_code, vendor_name, offer_name, lp_fv_type, lp_bot_type, lp_upsell_type, media_detail),
            (vendor_name, offer_name, lp_fv_type, lp_bot_type, lp_upsell_type, media_detail),
            (ordered_month),
            ()
        )

    ORDER BY
        ordered_month ASC, row_type ASC
),

integrate_orders_and_clicks_cvs AS (
------------------------------------------------------------
-- 8. [テーブル結合] 受注指標とアクセス指標の統合
--    同じ集計粒度（row_type）を持つ受注データとアクセスデータを結合します。
--    ★重要: row_typeだけでは同一粒度内の複数行（例: 同じ「コード別」でもコードが異なる行）を
--      区別できずクロス結合が発生するため、コード・取引先・オファー・LP種別（FV/BOT/
--      アップセル）・媒体詳細の計7項目を、f（月なし系）・g（月あり系）の両方の結合条件に
--      同一構成で含めています。
--    ★【絶対に触ってはいけない箇所】このJOIN条件（f・gとも）は絶対に削除・簡略化しないこと。
--      片方だけ変更すると過去に発生した重大バグ（クロス結合による実績値の増殖）が再発します。
--      詳細はケース全体READMEの運用・保守セクションを参照してください。
--    粒度: row_type, ym_label
------------------------------------------------------------
    SELECT
        e.*,

        CASE
            WHEN f.sum_click_count IS NULL THEN COALESCE(g.sum_click_count, 0)
            ELSE COALESCE(f.sum_click_count, 0)
        END AS sum_click_count,

        CASE
            WHEN f.sum_cv_count IS NULL THEN COALESCE(g.sum_cv_count, 0)
            ELSE COALESCE(f.sum_cv_count, 0)
        END AS sum_cv_count

    FROM
        apply_zero_fill_to_orders e     -- 06. の情報

    -- 月が関係ない集計行（コード別、取引先別、合計）の結合
    LEFT JOIN
        agg_clicks_cvs_by_grouping_sets f
    ON e.row_type = f.row_type
    AND f.row_type IN ('コード別', '取引先別', '合計')
    AND COALESCE(e.latest_ad_code_1st, '-') = COALESCE(f.latest_ad_code, '-') -- ★JOIN爆発防止の安全装置
    AND COALESCE(e.vendor_name_1st, '-') = COALESCE(f.vendor_name, '-') -- ★JOIN爆発防止の安全装置
    AND COALESCE(e.offer_name_1st, '-') = COALESCE(f.offer_name, '-') -- ★JOIN爆発防止の安全装置
    AND COALESCE(e.lp_fv_type_1st, '-') = COALESCE(f.lp_fv_type, '-') -- ★JOIN爆発防止の安全装置
    AND COALESCE(e.lp_bot_type_1st, '-') = COALESCE(f.lp_bot_type, '-') -- ★JOIN爆発防止の安全装置
    AND COALESCE(e.lp_upsell_type_1st, '-') = COALESCE(f.lp_upsell_type, '-') -- ★JOIN爆発防止の安全装置
    AND COALESCE(e.media_detail_1st, '-') = COALESCE(f.media_detail, '-') -- ★JOIN爆発防止の安全装置

    -- 月が関係する集計行（月/コード別、月/取引先別、月小計）の結合
    LEFT JOIN
        agg_clicks_cvs_by_grouping_sets g
    ON e.row_type = g.row_type
    AND g.row_type IN ('月/コード別', '月/取引先別', '月小計')
    AND e.ym_label = g.ordered_month
    AND COALESCE(e.latest_ad_code_1st, '-') = COALESCE(g.latest_ad_code, '-') -- ★JOIN爆発防止の安全装置
    AND COALESCE(e.vendor_name_1st, '-')     = COALESCE(g.vendor_name, '-')     -- ★JOIN爆発防止の安全装置
    AND COALESCE(e.offer_name_1st, '-') = COALESCE(g.offer_name, '-') -- ★JOIN爆発防止の安全装置
    AND COALESCE(e.lp_fv_type_1st, '-') = COALESCE(g.lp_fv_type, '-') -- ★JOIN爆発防止の安全装置
    AND COALESCE(e.lp_bot_type_1st, '-') = COALESCE(g.lp_bot_type, '-') -- ★JOIN爆発防止の安全装置
    AND COALESCE(e.lp_upsell_type_1st, '-') = COALESCE(g.lp_upsell_type, '-') -- ★JOIN爆発防止の安全装置
    AND COALESCE(e.media_detail_1st, '-') = COALESCE(g.media_detail, '-') -- ★JOIN爆発防止の安全装置
),

prepare_vendor_subtotals AS (
------------------------------------------------------------
-- 9. [表示用フォーマット調整] 月小計行の複製と名前変更
--    GROUPING SETSで1行だけ作られた「月小計」を、取引先別の表の下に表示させるための
--    専用の小計行として複製（準備）します。
--    粒度: row_type, ym_label
------------------------------------------------------------
    SELECT
        *,

        CASE
            WHEN row_type = '月小計' THEN '月小計_取引先別用'
            ELSE row_type
        END AS row_type_adjusted

    FROM
        integrate_orders_and_clicks_cvs  -- 08. の情報

    WHERE
        row_type IN ('月/取引先別', '月小計')
),

arrange_report_blocks AS (
------------------------------------------------------------
-- 10. [テーブル統合] レポートブロック順の絶対指定（ソートキー付与）
--     スプレッドシートへのベタ張りに対応するため、データを①コード別一覧、②取引先別一覧、
--     ③全体合計 の3ブロックに分割し指定した順番通りに並ぶようrow_type_no（1, 2, 3）を
--     付与して結合します。
--     ★1本目のSELECTで①（月/コード別・月小計）と③（コード別・取引先別・合計）を
--       row_type_noの値分けにより同時に処理し、2本目のSELECT（UNION ALL）でStep 9の
--       ②（月/取引先別・月小計）を追加することで、2回のスキャンのみで3ブロックを構成
--       しています。
--     粒度: row_type_adjusted, ym_label
------------------------------------------------------------
    SELECT
        *,
        CASE
            WHEN row_type = '月小計' THEN '月小計_コード別用'
            ELSE row_type
        END AS row_type_adjusted,

        CASE
            WHEN row_type IN ('月/コード別', '月小計')         THEN 1
            WHEN row_type IN ('コード別', '取引先別', '合計') THEN 3
            ELSE NULL
        END AS row_type_no

    FROM
        integrate_orders_and_clicks_cvs  -- 08. の情報
    WHERE NOT
        row_type = '月/取引先別'

    UNION ALL

    SELECT
        *,
        2 AS row_type_no
    FROM
        prepare_vendor_subtotals  -- 09. の情報
)

----------------------------------------------------------------------
-- 11. [最終出力] 分析・ダッシュボード表示用データの出力
--     付与したブロック番号(row_type_no)を第一キーとしてソートし出力します。
--     粒度: row_type_adjusted, ym_label
----------------------------------------------------------------------
SELECT
    '全対象'                  AS "対象区分",
    row_type_adjusted        AS "分類",

    ym_label                 AS "初回受注月",
    latest_ad_code_1st       AS "コード",
    vendor_name_1st          AS "取引先",
    promo_product_name_1st   AS "商品",
    offer_name_1st           AS "オファー",
    lp_fv_type_1st           AS "FV",
    lp_bot_type_1st          AS "BOT",
    lp_upsell_type_1st       AS "アップセル",
    media_detail_1st         AS "媒体",
    sum_click_count          AS "クリック数",
    sum_cv_count             AS "CV数",
    order_count              AS "獲得件数",

    sum_is_subsc_1st         AS "定期件数",
    sum_is_subsc_2_plus_1st  AS "2点定期件数",
    sum_is_email_subsc       AS "メルマガOK",
    sum_is_subsc_active      AS "定期継続件数",
    avg_current_age          AS "平均年齢",

    -- 初回1点→2点コースのF2〜F4実績
    sum_is_target_2nd_first_1_to_2        AS "2回目_対象者_初回1点→2点",
    sum_is_purchase_2nd_first_1_to_2      AS "2回目_購入者_初回1点→2点",
    sum_is_subsc_active_2nd_first_1_to_2  AS "2回目_継続数_初回1点→2点",
    sum_is_target_3rd_first_1_to_2        AS "3回目_対象者_初回1点→2点",
    sum_is_purchase_3rd_first_1_to_2      AS "3回目_購入者_初回1点→2点",
    sum_is_subsc_active_3rd_first_1_to_2  AS "3回目_継続数_初回1点→2点",
    sum_is_target_4th_first_1_to_2        AS "4回目_対象者_初回1点→2点",
    sum_is_purchase_4th_first_1_to_2      AS "4回目_購入者_初回1点→2点",
    sum_is_subsc_active_4th_first_1_to_2  AS "4回目_継続数_初回1点→2点",

    -- 初回2点コースのF2〜F4実績
    sum_is_target_2nd_first_2             AS "2回目_対象者_初回2点",
    sum_is_purchase_2nd_first_2           AS "2回目_購入者_初回2点",
    sum_is_subsc_active_2nd_first_2       AS "2回目_継続数_初回2点",
    sum_is_target_3rd_first_2             AS "3回目_対象者_初回2点",
    sum_is_purchase_3rd_first_2           AS "3回目_購入者_初回2点",
    sum_is_subsc_active_3rd_first_2       AS "3回目_継続数_初回2点",
    sum_is_target_4th_first_2             AS "4回目_対象者_初回2点",
    sum_is_purchase_4th_first_2           AS "4回目_購入者_初回2点",
    sum_is_subsc_active_4th_first_2       AS "4回目_継続数_初回2点",

    avg_current_age_active  AS "平均年齢_継続層",
    avg_current_age_cancel  AS "平均年齢_解約層"

FROM
    arrange_report_blocks  -- 10. の情報

ORDER BY
    row_type_no ASC, ordered_month_1st ASC, row_type ASC, latest_ad_code_1st ASC,
    vendor_name_1st ASC, offer_name_1st ASC, media_detail_1st ASC

;
