/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 配信前10日プレチェック・アラートマスタ
  Pre-Delivery 10-Day Precheck Alert — Intermediate Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  特典を付与するタイミングにおいて、商品が確実に顧客の手元に届いていること、および
  メールが正常に送れる状態であることが条件となる。

  ★【休日跨ぎのズレを防ぐ「10日ルール」】
  特典予定日（15日後など）の当日になって未入金や出荷遅延を検知しようとすると、手動CSVの
  更新が止まる「土日（休日）」に予定日を迎えた顧客が採番ズレを起こすバグがある。これを防ぐため、
  「出荷日から10日以上経過しているか（is_predelivery_precheck）」という物理的な配送実績に
  基づく事前検知ラインを新設し、付与日の数日前（平日）の時点で未入金や出荷遅延を
  あらかじめ検知してシステムから除外する。

  以下の異常データを抽出し、運用担当者が目視で確認・対応するモニタリングリストを作成する。
    1. 出荷止まり: 出荷から10日以上経過しているにもかかわらず、配達完了になっていない。
    2. 未入金止まり: 出荷から10日以上経過しているにもかかわらず、入金が確認できていない。
    3. 当日解約中: まさに今日付与する予定なのに、すでに定期が解約されている。
    4. メール不備: 付与予定日が「現在・未来」である顧客の中に、メアド未登録・不達・購読解除者がいる。

  Gift delivery requires confirmed physical receipt and a valid email channel. To prevent a
  weekend-driven numbering-drift bug (manual CSV updates pause on weekends), this query
  introduces a shipment-date-based 10-day precheck rather than checking on the gift date
  itself, catching unpaid/delayed orders several weekdays in advance.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
  1. auto_extracted_target_list
     10日プレチェック判定とタイムライン（過去/現在/未来）判定
  2-4. customer_pii_master / bounced_email_list / optout_email_list
     メール関連マスタの取得
  5. user_email_alert_status
     メールエラー状態の統合とハッシュキー生成
  6. detect_irregular_targets
     タイムラインとステータスを掛け合わせた異常検知
  7. Final Output

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  user_id, order_id

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  user_id, order_id

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: SHA2 hashing, DATEDIFF)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 配信前アラート中間テーブル
  int_predelivery_alert_check
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [Target List] 自動抽出された最新の対象者リスト
--    Data Grain: user_id, order_id
----------------------------------------------------------------------
auto_extracted_target_list AS (
    SELECT
        user_id, order_id, order_no, order_status, order_status_numbr,
        is_payment_received, ship_date, delivered_date, digital_gift_present_date,

        is_product_a_first_order, is_product_b_first_order,
        is_course_3bottle_first, is_course_upgraded_1_to_2, is_course_upgraded_1_to_3,
        is_eligible_for_bonus_gift,

        product_category || subsc_category || ship_category AS product_subsc_ship_category,
        is_subsc_active,

        is_cus_black, is_cus_deleted_merged, is_cus_merged,

        -- 【10日プレチェック判定】発送トラブルや未入金を数日前（平日）に先回りして検知する
        CASE
            WHEN DATEDIFF(day, ship_date, CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE) >= 10 THEN 1
            ELSE 0
        END AS is_predelivery_precheck,

        -- 【タイムライン判定】今日を基準とした過去・現在・未来
        CASE
            WHEN DATEDIFF(day, digital_gift_present_date, CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE) > 0 THEN '過去'
            WHEN DATEDIFF(day, digital_gift_present_date, CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE) = 0 THEN '現在'
            WHEN DATEDIFF(day, digital_gift_present_date, CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE) < 0 THEN '未来'
            ELSE NULL
        END AS time_line

    FROM
        int_fraud_risk_detection -- 【前工程】09_int_fraud_risk_detection
),

----------------------------------------------------------------------
-- 2. [PII Master] 顧客属性マスタ (個人情報/PII)
--    Data Grain: user_id
----------------------------------------------------------------------
customer_pii_master AS (
    SELECT
        user_id,
        email,
        is_null_email,
        LOWER(TRIM(email)) || user_id AS hash_key_source -- ハッシュ化キーの生成関係（安全対策のため"ソルト"を加える）
    FROM
        dim_customers_pii -- 【顧客マスタ】個人情報あり
),

----------------------------------------------------------------------
-- 3. [Bounce List] メール配信不達テーブル
--    Data Grain: email
----------------------------------------------------------------------
bounced_email_list AS (
    SELECT
        email,
        1 AS is_unreach_email
    FROM
        raw_bounced_emails -- 配信不達データ
    GROUP BY
        email
),

----------------------------------------------------------------------
-- 4. [Opt-out List] メール購読解除テーブル
--    Data Grain: email
----------------------------------------------------------------------
optout_email_list AS (
    SELECT
        email,
        1 AS is_unsubsc_email
    FROM
        raw_unsubscribed_emails -- メール購読解除データ
    GROUP BY
        email
),

----------------------------------------------------------------------
-- 5. [Email Status] メールエラー状態の統合
--    Data Grain: user_id
----------------------------------------------------------------------
user_email_alert_status AS (
    SELECT
        a.user_id,
        a.is_null_email,
        COALESCE(b.is_unreach_email, 0) AS is_unreach_email,
        COALESCE(c.is_unsubsc_email, 0) AS is_unsubsc_email,
        SHA2(a.hash_key_source, 256)    AS hash_key

    FROM
        customer_pii_master a -- 02. の情報

    LEFT JOIN
        bounced_email_list b -- 03. の情報
    ON a.email = b.email

    LEFT JOIN
        optout_email_list c -- 04. の情報
    ON a.email = c.email
),

----------------------------------------------------------------------
-- 6. [Anomaly Detection] アラートフラグの付与
--    Data Grain: user_id, order_id
----------------------------------------------------------------------
detect_irregular_targets AS (
    SELECT
        z.*,

        -- 【アラート1】出荷止まり
        CASE
            WHEN z.is_predelivery_precheck = 1
             AND z.order_status_numbr >= 1
             AND z.order_status_numbr <= 5 THEN 1
            ELSE 0
        END AS is_shipped_not_delivered,

        -- 【アラート2】当日解約中
        CASE
            WHEN z.time_line = '現在'
             AND z.is_subsc_active <> 1 THEN 1
            ELSE 0
        END AS is_due_to_subsc_cancelled,

        COALESCE(y.is_null_email, 0)    AS is_null_email,
        COALESCE(y.is_unreach_email, 0) AS is_unreach_email,
        COALESCE(y.is_unsubsc_email, 0) AS is_unsubsc_email,

        -- 【アラート3】メール不備（過去分にはアラートを出さず、現在・未来の対象者のみ検知）
        CASE
            WHEN z.time_line IN ('現在', '未来')
             AND
                (
                    COALESCE(y.is_null_email, 0) = 1
                    OR COALESCE(y.is_unreach_email, 0) = 1
                    OR COALESCE(y.is_unsubsc_email, 0) = 1
                )
                THEN 1
            ELSE 0
        END AS is_due_to_email_error,

        -- 【アラート4】未入金（持ち逃げ防止）
        CASE
            WHEN z.is_predelivery_precheck = 1
             AND z.is_payment_received <> 1 THEN 1
            ELSE 0
        END AS is_payment_pending,

        y.hash_key

    FROM
        auto_extracted_target_list z -- 01. の情報

    LEFT JOIN
        user_email_alert_status y -- 05. の情報
    ON z.user_id = y.user_id
)

----------------------------------------------------------------------
-- 7. [Final Output] 分析・確認用データの整形
--    Data Grain: user_id, order_id
----------------------------------------------------------------------
SELECT
    user_id                        AS "ユーザーID",
    order_id                       AS "注文ID",
    order_no                       AS "注文番号",
    order_status                   AS "注文ステータス",
    order_status_numbr             AS "受注明細状態",
    is_payment_received            AS "入金済フラグ",
    ship_date                      AS "出荷日",
    delivered_date                 AS "配達完了日",
    digital_gift_present_date      AS "プレゼント日_デジタルギフト",

    is_product_a_first_order       AS "商品ラインA_新規フラグ",
    is_product_b_first_order       AS "商品ラインB_新規フラグ",
    is_course_3bottle_first        AS "初回3本_定期フラグ",
    is_course_upgraded_1_to_2      AS "初回1本→2本_定期フラグ",
    is_course_upgraded_1_to_3      AS "初回1本→3本_定期フラグ",
    is_eligible_for_bonus_gift     AS "追加特典ダミー_同梱フラグ",

    product_subsc_ship_category    AS "商品/定期/出荷_分類",
    is_subsc_active                AS "定期継続フラグ",

    is_cus_black                   AS "ブラックフラグ",
    is_cus_deleted_merged          AS "削除/統合フラグ",
    is_cus_merged                  AS "顧客統合フラグ",

    time_line                      AS "タイムライン",
    is_shipped_not_delivered       AS "出荷止まりフラグ",
    is_payment_pending             AS "未入金フラグ",
    is_due_to_subsc_cancelled      AS "当日_定期解約中フラグ",
    is_null_email                  AS "メールアドレス未登録_フラグ",
    is_unreach_email               AS "メール配信失敗_フラグ",
    is_unsubsc_email               AS "メール配信停止_フラグ",
    is_due_to_email_error          AS "メール不備フラグ",

    CASE WHEN is_shipped_not_delivered = 1 THEN '出荷_出荷完了止まり' ELSE NULL END AS "出荷チェック",
    CASE WHEN is_payment_pending = 1 THEN '入金_未入金止まり' ELSE NULL END AS "入金チェック",
    CASE WHEN is_due_to_subsc_cancelled = 1 THEN '定期解約中_当日時点' ELSE NULL END AS "定期解約チェック",

    CASE
        WHEN is_null_email = 1    THEN 'メールアドレス_未登録'
        WHEN is_unreach_email = 1 THEN 'メールアドレス_配信失敗'
        WHEN is_unsubsc_email = 1 THEN 'メールアドレス_購読解除'
        ELSE NULL
    END AS "顧客情報登録チェック",

    hash_key AS "ハッシュ化キー"

FROM
    detect_irregular_targets -- 06. の情報

ORDER BY
    user_id ASC, ship_date ASC
;
