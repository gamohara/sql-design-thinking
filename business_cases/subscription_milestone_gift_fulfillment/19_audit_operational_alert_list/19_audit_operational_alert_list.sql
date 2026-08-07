/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 運用アラート統合リスト
  Consolidated Operational Alert List — Audit Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  これまでの各データマートから、「人間による目視確認やイレギュラー対応が必要な注文
  （アラート）」のみを抽出し、1つのテーブルに統合して出力する品質モニタリングクエリ。

  以下のような「システムで自動判断してはいけないケース」や「運用漏れ・不正のリスクが
  あるケース」を一元的に抽出し、運用担当者の日々のTo-Doリストとして機能させる。
    ① 返品チェック（事後返品の悪質性判断・進行中の返品可能性を含む）
    ② 重複注文チェック（どちらの注文に特典を付与するかの判断）
    ③ DM履歴なしチェック（システムトラブルやリスト漏れの可能性）
    ④ 追加特典対象漏れチェック（運用担当者の手動登録漏れの可能性）
    ⑤ 定期即解約チェック（特典をもらう直前・直後に解約する特典逃げの可能性）
    ⑥ 短期間発送チェック（システムエラーや不正操作による過剰出荷の可能性）
    ⑦ 停止リストからの回復検知（一度ストップされたが、後日ステータスが正常に戻った顧客）

  ★アーキテクチャの変更（責務の分割）
  本クエリの役割は「システム上で発生した生のアラート事実（Fact）」をすべて集約すること
  に特化している。運用担当者が確認済みのデータをミュート（非表示化）する処理は、追跡漏れ
  を防ぐため後工程（20）へ委譲している。これにより、本クエリの出力は「アラート発生件数
  の純粋な推移（KPI）」としても活用可能になる。

  Consolidates every alert requiring human judgment from across the pipeline into one
  monitoring list. The "mute already-reviewed alerts" responsibility is deliberately deferred
  to the next query (20), keeping this query's output a pure, trackable KPI of alert volume.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
  1-7. alert_XXX
     各データマートからの個別アラート抽出（拡張可能な設計）
  8. combine_all_alerts
     全アラートの縦結合
  9. mute_whitelisted_alerts
     確認済みデータ（ホワイトリスト）のフラグ付与
  10. Final Output
      優先度・緊急度順のソートと出力

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  order_id

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  order_id, check_category

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: UNION ALL, custom sort)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 運用アラート統合テーブル
  audit_operational_alert_list
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [Alert①] F2~F4_返品チェック
--    Data Grain: order_id
----------------------------------------------------------------------
alert_f2_to_f4_returns AS (
    SELECT
        user_id, product_subsc_ship_category, order_id, ship_date, digital_gift_present_date,
        order_status,

        CASE WHEN is_payment_received = 1 THEN '入金済' ELSE '未入金' END AS payment_status,

        return_completed_date,
        -- check_category の例:「①返品_2回目出荷」「①除外対象_2回目出荷_悪質顧客のため」
        -- 「①返品の可能性_2回目出荷」
        '①' || return_check AS check_category,

        -- check_detail の例:「悪質」「返品依頼あり（プレ予定日：08/04）？」
        CASE
            WHEN is_high_risk = 1
             AND DATEDIFF(day, digital_gift_present_date, return_completed_date) > 0 THEN '悪質'
            WHEN return_check LIKE '%返品の可能性%'
             THEN '返品依頼あり（プレ予定日：' || TO_CHAR(digital_gift_present_date, 'MM/DD') || '）？'
            ELSE NULL
        END AS check_detail,

        is_cus_merged,
        is_multiple_subsc

    FROM
        int_fraud_risk_detection -- 【前工程】09_int_fraud_risk_detection

    WHERE
        return_check IS NOT NULL
),

----------------------------------------------------------------------
-- 2. [Alert②] 重複注文チェック
--    Data Grain: order_id
----------------------------------------------------------------------
alert_duplicate_orders AS (
    SELECT
        user_id,
        product_category || subsc_category || ship_category AS product_subsc_ship_category,
        order_id, ship_date,
        CAST(NULL AS DATE) AS digital_gift_present_date,
        order_status,

        CASE WHEN is_payment_received = 1 THEN '入金済' ELSE '未入金' END AS payment_status,

        return_completed_date,
        -- check_category の例:「②重複注文_PRODUCT_A」
        '②' || duplicate_check_major || duplicate_check_minor AS check_category,
        duplicate_check_detail                                AS check_detail,
        is_cus_merged,
        NULL AS is_multiple_subsc

    FROM
        stg_gift_eligible_order_confirmed -- 【前工程】02_stg_gift_eligible_order_confirmed

    WHERE
        duplicate_check_major IS NOT NULL
       OR duplicate_check_minor IS NOT NULL
),

----------------------------------------------------------------------
-- 3. [Alert③] DM履歴なしチェック
--    ※未来の予定や連携タイムラグの誤検知を防ぐため、5日間のバッファを設ける。
--    Data Grain: order_id
----------------------------------------------------------------------
alert_no_dm_history AS (
    SELECT
        user_id,
        product_category || subsc_category || ship_category AS product_subsc_ship_category,
        order_id, ship_date,
        CAST(NULL AS DATE) AS digital_gift_present_date,
        order_status,

        CASE WHEN is_payment_received = 1 THEN '入金済' ELSE '未入金' END AS payment_status,

        return_completed_date,
        -- check_category の例:「③DM履歴_ギフト対象者なし」
        '③' || dm_history_check AS check_category,
        NULL                     AS check_detail,
        is_cus_merged,
        NULL AS is_multiple_subsc

    FROM
        stg_gift_eligible_order_confirmed -- 【前工程】02_stg_gift_eligible_order_confirmed

    WHERE
        dm_history_check IS NOT NULL
      AND ship_date < CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE - 5
),

----------------------------------------------------------------------
-- 4. [Alert④] 追加特典_対象者漏れチェック
--    Data Grain: order_id
----------------------------------------------------------------------
alert_missing_bonus_gift AS (
    SELECT
        user_id,
        product_category || subsc_category || ship_category AS product_subsc_ship_category,
        order_id, ship_date, digital_gift_present_date, order_status,

        CASE WHEN is_payment_received = 1 THEN '入金済' ELSE '未入金' END AS payment_status,

        return_completed_date,
        -- check_category の例:「④追加特典_対象漏れ」
        '④' || check_for_bonus_gift AS check_category,
        NULL                        AS check_detail,
        is_cus_merged,
        NULL AS is_multiple_subsc

    FROM
        int_bonus_gift_upsell_detection -- 【前工程】06_int_bonus_gift_upsell_detection

    WHERE
        check_for_bonus_gift IS NOT NULL
),

----------------------------------------------------------------------
-- 5. [Alert⑤] 定期即解約チェック
--    Data Grain: order_id
----------------------------------------------------------------------
alert_immediate_subsc_cancel AS (
    SELECT
        user_id, product_subsc_ship_category, order_id, ship_date, digital_gift_present_date,
        order_status,

        CASE WHEN is_payment_received = 1 THEN '入金済' ELSE '未入金' END AS payment_status,

        return_completed_date,
        -- check_category の例:「⑤定期解約中_2回目出荷」
        '⑤' || subsc_cancel_check AS check_category,
        NULL                       AS check_detail,
        is_cus_merged,
        is_multiple_subsc

    FROM
        int_fraud_risk_detection -- 【前工程】09_int_fraud_risk_detection

    WHERE
        subsc_cancel_check IS NOT NULL
),

----------------------------------------------------------------------
-- 6. [Alert⑥] 短期間発送チェック
--    Data Grain: order_id
----------------------------------------------------------------------
alert_short_leadtime_shipments AS (
    SELECT
        user_id, product_subsc_ship_category, order_id, ship_date, digital_gift_present_date,
        order_status,

        CASE WHEN is_payment_received = 1 THEN '入金済' ELSE '未入金' END AS payment_status,

        return_completed_date,
        -- check_category の例:「⑥出荷_短期間発送」
        '⑥' || ship_interval_check AS check_category,
        NULL                        AS check_detail,
        is_cus_merged,
        is_multiple_subsc

    FROM
        int_fraud_risk_detection -- 【前工程】09_int_fraud_risk_detection

    WHERE
        ship_interval_check IS NOT NULL
),

----------------------------------------------------------------------
-- 7. [Alert⑦] 対象漏れ/配信停止からの回復検知
--    Data Grain: order_id
----------------------------------------------------------------------
alert_recovered_from_stop_list AS (
    SELECT
        user_id, product_subsc_ship_category, order_id, ship_date, digital_gift_present_date,
        order_status, payment_status,
        CAST(NULL AS DATE) AS return_completed_date,
        -- check_category の例:「⑦本日分_対象漏れ」「⑦過去分_配信失敗」
        '⑦' || alert_status_main     AS check_category,
        -- check_detail には12番で生成された復帰理由がそのまま入る（例:「出荷ステータス更新（以前は SHP_COMP）」）
        alert_status_detail_adjusted AS check_detail, -- ★前工程(12)で生成した全リカバリー理由を引き継ぐ
        is_cus_merged,
        NULL AS is_multiple_subsc

    FROM
        audit_missing_target_detection -- 【前工程】12_audit_missing_target_detection
),

-----------------------------------------------------------
-- 今後もチェックルールを追加する場合は、ここにCTEを新設してください
-----------------------------------------------------------

----------------------------------------------------------------------
-- 8. [Combine] チェックテーブルの統合
--    Data Grain: order_id
----------------------------------------------------------------------
combine_all_alerts AS (
    SELECT user_id, product_subsc_ship_category, order_id, ship_date, digital_gift_present_date,
           order_status, payment_status, return_completed_date, check_category, check_detail,
           is_cus_merged, is_multiple_subsc
    FROM alert_f2_to_f4_returns

    UNION ALL

    SELECT user_id, product_subsc_ship_category, order_id, ship_date, digital_gift_present_date,
           order_status, payment_status, return_completed_date, check_category, check_detail,
           is_cus_merged, is_multiple_subsc
    FROM alert_duplicate_orders

    UNION ALL

    SELECT user_id, product_subsc_ship_category, order_id, ship_date, digital_gift_present_date,
           order_status, payment_status, return_completed_date, check_category, check_detail,
           is_cus_merged, is_multiple_subsc
    FROM alert_no_dm_history

    UNION ALL

    SELECT user_id, product_subsc_ship_category, order_id, ship_date, digital_gift_present_date,
           order_status, payment_status, return_completed_date, check_category, check_detail,
           is_cus_merged, is_multiple_subsc
    FROM alert_missing_bonus_gift

    UNION ALL

    SELECT user_id, product_subsc_ship_category, order_id, ship_date, digital_gift_present_date,
           order_status, payment_status, return_completed_date, check_category, check_detail,
           is_cus_merged, is_multiple_subsc
    FROM alert_immediate_subsc_cancel

    UNION ALL

    SELECT user_id, product_subsc_ship_category, order_id, ship_date, digital_gift_present_date,
           order_status, payment_status, return_completed_date, check_category, check_detail,
           is_cus_merged, is_multiple_subsc
    FROM alert_short_leadtime_shipments

    UNION ALL

    SELECT user_id, product_subsc_ship_category, order_id, ship_date, digital_gift_present_date,
           order_status, payment_status, return_completed_date, check_category, check_detail,
           is_cus_merged, is_multiple_subsc
    FROM alert_recovered_from_stop_list

    -----------------------------------------------------------
    -- 今後もチェックルールを追加した場合は、ここに union all で新設してください
    -----------------------------------------------------------
),

----------------------------------------------------------------------
-- 9. [Mute Flag] 確認済みデータ（ホワイトリスト）除外用のフラグ設定
--    Data Grain: order_id
----------------------------------------------------------------------
mute_whitelisted_alerts AS (
    SELECT
        z.*,
        COALESCE(y.is_persisted_orderid, 0) AS is_persisted_orderid -- 特定の注文IDを残すため削除対象から除外するフラグ

    FROM
        combine_all_alerts z -- 08. の情報

    LEFT JOIN
        map_gift_manual_exceptions y -- 手動対応リスト
    ON z.order_id = y.order_id
    AND y.exception_type = 'PERSIST_BY_ORDER'
)

----------------------------------------------------------------------
-- 10. [Final Output]
--     Data Grain: order_id
----------------------------------------------------------------------
SELECT
    user_id                      AS "ユーザーID",
    order_id                     AS "注文ID",
    product_subsc_ship_category  AS "商品/定期/出荷_分類",

    check_category               AS "チェック内容",
    check_detail                 AS "チェック詳細",

    ship_date                    AS "出荷日",
    digital_gift_present_date    AS "プレゼント日_デジタルギフト",
    order_status                 AS "注文ステータス",
    payment_status                AS "入金ステータス",
    return_completed_date        AS "返品受付日",

    is_persisted_orderid         AS "残留フラグ",

    NULLIF(
        TRIM(
            CASE WHEN is_cus_merged = 1 THEN '統合あり' ELSE '' END
            || CASE WHEN is_cus_merged = 1 AND is_multiple_subsc = 1 THEN ' / ' ELSE '' END
            || CASE WHEN is_multiple_subsc = 1 THEN '複数定期継続中' ELSE '' END
        ), ''
    ) AS "その他チェック"

FROM
    mute_whitelisted_alerts -- 09. のミュートフラグ情報

ORDER BY
    check_category ASC,
    CASE WHEN check_detail = '悪質' THEN 0 ELSE 1 END ASC,
    digital_gift_present_date ASC,
    check_detail ASC,
    ship_date ASC,
    user_id ASC
;
