/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 不正リスク4大防衛検知マスタ
  Four-Line Fraud & Risk Detection — Intermediate Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  特典施策において、費用対効果（ROI）を悪化させる最大の要因は以下の4つである。
    1. 事後返品（特典をもらった後に商品を返品する悪質行為）
    2. 特典逃げ（特典をもらう直前・直後に定期を即解約する行為）
    3. 短期過剰出荷（システムエラーや不正操作による、異常に短いスパンでの連続購入）
    4. 返品予定のすり抜け（返品連絡を受けて対応中なのに、システム処理前に特典を送ってしまう）
  本クエリでは、前工程のデータに「現在の定期ステータス」「出荷リードタイム」および
  「CS応対メモの対応状況」を時系列で掛け合わせることで、上記4つのリスクを事前検知し、
  運用担当者にアラートとして提示する。

  Four factors most severely degrade campaign ROI: post-gift returns (abuse), cancel-right-
  after-gift ("gift and run"), abnormally short shipment intervals (system errors/fraud), and
  in-progress return requests slipping through before system processing catches up. This
  query cross-references timing across subscription status, shipment intervals, and CS
  incident notes to detect all four risks proactively.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
  1. import_base_journey_and_risk_factors
     ジャーニーの読み込みと事後返品（悪質）フラグの事前計算
  2. extract_subsc_status_base
     現在の定期ステータスと解約日時の取得
  3. extract_expected_returns_from_incident
     CS応対メモから返品予定の可能性がある顧客の抽出
  4. propagate_high_risk_flag
     悪質フラグの次回出荷への自己結合伝播
  5. validate_subscription_status
     即解約リスクの判定
  6. flag_expected_returns
     返品予定リスクの判定
  7. Final Output
     アラートメッセージの付与と出力

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  user_id, order_no

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  user_id, order_no

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: self-join, DATEDIFF)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 不正リスク検知中間テーブル
  int_fraud_risk_detection
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [Base + Risk Factors] 購入ジャーニーとリスク要素の読み込み
--    Data Grain: user_id, order_no
----------------------------------------------------------------------
import_base_journey_and_risk_factors AS (
    SELECT
        j.user_id, j.order_id, j.order_no, j.product_id, j.product_name,
        j.order_status, j.order_status_numbr, j.is_payment_received,
        j.ship_date, j.delivered_date, j.digital_gift_present_date,
        j.is_sys_return, j.return_completed_date,

        j.is_product_a_first_order, j.is_product_b_first_order,
        j.is_course_3bottle_first, j.is_course_upgraded_1_to_2, j.is_course_upgraded_1_to_3,
        j.is_eligible_for_bonus_gift,

        j.product_category, j.subsc_category, j.ship_category,
        j.is_cus_black, j.is_cus_deleted_merged, j.is_cus_merged,
        j.ship_interval_days,

        -- 【悪質判定】返品完了日が特典発送日より「後」であり、かつ確実に配信済みであれば悪質とみなす
        CASE
            WHEN DATEDIFF(day, j.digital_gift_present_date, j.return_completed_date) > 0
             AND COALESCE(ch.has_confirmed_delivery, 0) = 1                              THEN 1
            ELSE 0
        END AS is_high_risk,

        -- 悪質だった場合、そのペナルティを「次回の注文（=order_no + 1）」に与えるためのターゲットキー
        CASE
            WHEN DATEDIFF(day, j.digital_gift_present_date, j.return_completed_date) > 0
             AND COALESCE(ch.has_confirmed_delivery, 0) = 1                              THEN j.order_no + 1
            ELSE NULL
        END AS order_no_target

    FROM
        int_gift_timing_manual_override j -- 【前工程】08_int_gift_timing_manual_override

    LEFT JOIN
        (
            SELECT
                user_id,
                product_subsc_ship_category,
                1 AS has_confirmed_delivery
            FROM
                map_gift_target_ledger -- □ 特典_対象者リスト.csv
            WHERE
                -- すでに配信済みのもの（タイムラインが過去）に絞る
                DATEDIFF(day, gift_present_date, CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE) > 0
        ) ch
    ON j.user_id = ch.user_id
    AND (j.product_category || j.subsc_category || j.ship_category) = ch.product_subsc_ship_category
),

----------------------------------------------------------------------
-- 2. [Subsc Status] 顧客の現在の定期ステータスの取得
--    Data Grain: user_id
----------------------------------------------------------------------
extract_subsc_status_base AS (
    SELECT
        user_id,
        MAX(is_subsc_active) AS is_subsc_active,

        CASE
            WHEN MAX(is_subsc_active) <> 1 THEN MAX(subsc_canceled_date)
            ELSE NULL
        END AS subsc_canceled_date,

        CASE
            WHEN SUM(is_subsc_active) >= 2 THEN 1
            ELSE 0
        END AS is_multiple_subsc

    FROM
        dim_subscription_status -- 【マスタ】現行の定期契約ステータス
    GROUP BY
        user_id
),

----------------------------------------------------------------------
-- 3. [Return-Intent Detection] 応対メモより返品予定の可能性がある顧客の抽出
--    Data Grain: user_id
----------------------------------------------------------------------
extract_expected_returns_from_incident AS (
    SELECT
        user_id,
        MAX(incident_created_date) AS incident_created_date,
        1                            AS is_return_expected

    FROM
        raw_cs_incident_notes -- 【応対TB】応対詳細

    WHERE
        (
            (
                (
                    incident_category_code IN (
                        '033', -- 処理依頼／返品・返金
                        '071', -- 処理依頼／請求額・決済種別変更
                        '072', -- 処理依頼／運送会社指示
                        '074', -- 処理依頼／退会・登録抹消
                        '076', -- 処理依頼／決済関連
                        '080', -- 処理依頼／未来の住所変更
                        '081', -- 処理依頼／その他
                        '091'  -- 処理依頼／顧客返品以外
                    )
                    OR incident_memo LIKE '%返品%'
                    OR incident_memo LIKE '%返送%'
                )
                AND incident_memo NOT LIKE '%チェックシートの返送あり%'
                AND incident_memo NOT LIKE '%チェックシート返送あり%'
            )
            OR
            (
                incident_memo LIKE '%チャットより%'
                AND incident_memo LIKE '%返品解約%'
            )
        )
        -- 余裕をもって、本日からの経過日数が20日間までのものに絞る
        AND DATEDIFF(day, incident_created_date, CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE) < 20

    GROUP BY
        user_id
),

----------------------------------------------------------------------
-- 4. [Penalty Propagation] 悪質顧客フラグの自己結合伝播
--    Data Grain: user_id, order_no
----------------------------------------------------------------------
propagate_high_risk_flag AS (
    SELECT
        a.*,
        COALESCE(b.is_high_risk, 0) AS is_high_risk_customer

    FROM
        import_base_journey_and_risk_factors a -- 01. の情報

    LEFT JOIN
        (
            SELECT *
            FROM import_base_journey_and_risk_factors
            WHERE is_high_risk = 1
        ) b
    ON a.user_id = b.user_id
    AND a.order_no = b.order_no_target
),

----------------------------------------------------------------------
-- 5. [Subscription Check] 特典逃げ（即解約）リスクの判定
--    Data Grain: user_id, order_no
----------------------------------------------------------------------
validate_subscription_status AS (
    SELECT
        c.*,
        COALESCE(d.is_subsc_active, 0)   AS is_subsc_active,
        COALESCE(d.is_multiple_subsc, 0) AS is_multiple_subsc,

        CASE
            WHEN COALESCE(d.is_subsc_active, 0) <> 1
             AND c.digital_gift_present_date >= CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE
             AND d.subsc_canceled_date >= c.ship_date
             AND d.subsc_canceled_date <= c.digital_gift_present_date THEN 1
            ELSE 0
        END AS is_high_risk_subsc

    FROM
        propagate_high_risk_flag c -- 04. の情報

    LEFT JOIN
        extract_subsc_status_base d -- 02. の情報
    ON c.user_id = d.user_id
),

----------------------------------------------------------------------
-- 6. [Return-Intent Check] 今後の返品予定を判定
--    Data Grain: user_id, order_no
----------------------------------------------------------------------
flag_expected_returns AS (
    SELECT
        e.*,

        CASE
            WHEN COALESCE(f.is_return_expected, 0) = 1
             AND e.order_status <> 'Subsc_order'
             AND e.digital_gift_present_date >= f.incident_created_date
             AND e.ship_date <= f.incident_created_date
             AND e.digital_gift_present_date >= CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE THEN 1
            ELSE 0
        END AS is_high_risk_return_expected

    FROM
        validate_subscription_status e -- 05. の情報

    LEFT JOIN
        extract_expected_returns_from_incident f -- 03. の情報
    ON e.user_id = f.user_id
)

----------------------------------------------------------------------
-- 7. [Final Output] 異常検知アラートの付与とデータ整形
--    Data Grain: user_id, order_no
----------------------------------------------------------------------
SELECT
    user_id                        AS "ユーザーID",
    order_id                       AS "注文ID",
    order_no                       AS "注文番号",
    product_id                     AS "商品ID",
    product_name                   AS "商品名",
    order_status                   AS "注文ステータス",
    order_status_numbr             AS "受注明細状態",
    is_payment_received            AS "入金済フラグ",
    ship_date                      AS "出荷日",
    delivered_date                 AS "配達完了日",
    digital_gift_present_date      AS "プレゼント日_デジタルギフト",
    is_sys_return                  AS "返品フラグ_システム基準",
    return_completed_date          AS "返品受付日",
    is_product_a_first_order       AS "商品ラインA_新規フラグ",
    is_product_b_first_order       AS "商品ラインB_新規フラグ",

    is_course_3bottle_first        AS "初回3本_定期フラグ",
    is_course_upgraded_1_to_2      AS "初回1本→2本_定期フラグ",
    is_course_upgraded_1_to_3      AS "初回1本→3本_定期フラグ",
    is_eligible_for_bonus_gift     AS "追加特典ダミー_同梱フラグ",

    product_category || subsc_category || ship_category AS "商品/定期/出荷_分類",

    is_cus_black                   AS "ブラックフラグ",
    is_cus_deleted_merged          AS "削除/統合フラグ",
    is_cus_merged                  AS "顧客統合フラグ",

    is_subsc_active                AS "定期継続フラグ",
    is_multiple_subsc              AS "複数定期継続フラグ",
    is_high_risk                   AS "悪質フラグ",

    -- [アラート①] 返品チェック（プレゼント後に返品した悪質顧客・返品の可能性）
    CASE
        WHEN is_sys_return = 1
                THEN '返品_' || ship_category
        WHEN is_high_risk_customer = 1
                THEN '除外対象_' || ship_category || '_悪質顧客のため'
        WHEN is_high_risk_return_expected = 1
                THEN '返品の可能性_' || ship_category
        ELSE NULL
    END AS "返品チェック",

    -- [アラート②] 定期即解約チェック
    CASE
        WHEN is_high_risk_subsc = 1
                THEN '定期解約中_' || ship_category
        ELSE NULL
    END AS "定期解約チェック",

    -- [アラート③] 異常出荷スパンチェック（1〜3日の極端に短いリードタイム）
    CASE
        WHEN ship_interval_days > 1
         AND ship_interval_days <= 3 THEN '出荷_短期間発送'
        ELSE NULL
    END AS "出荷チェック"

FROM
    flag_expected_returns -- 06. の情報

ORDER BY
    user_id ASC, ship_date ASC
;
