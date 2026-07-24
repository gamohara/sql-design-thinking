/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 対象者リスト突合・自動採番マスタ（休日制御付き）
  Target List Reconciliation & Holiday-Safe Auto-Numbering — Intermediate Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  システムが自動生成した対象者リストと、運用担当者が手動管理しているリスト（CSV）を
  突き合わせ、差異や漏れがないかを検証・モニタリングする。特典対象日を「過去・現在・未来」
  の3つのタイムラインに分割し、それぞれ検証と自動更新を行う。

  ★【ベルトコンベア形式のタイムライン制御と休日対応】
  対象者は時間の経過とともに「未来 → 現在 → 過去」へとベルトコンベアのように自動で
  押し出されていく。しかし休日は手動リスト更新が止まるため、休日中に自動削除・追加されて
  そのまま過去に流れたデータが月曜日の自動採番で採番ズレを引き起こす。これを防ぐため、
  「今日は手動更新が停止しているか（is_holiday）」を外部CSVから読み込み、休日の場合は
  『現在分』の離脱除外・新規追加を自動でブロック（完全固定）する。

  ★【自動採番の脆弱性対策】
  過去の最大採番Noを独立したCTEに保管し、採番時にCROSS JOINで結合する。これにより、
  手動リストの「現在」や「未来」が0件でFULL JOINが空振りした場合でも採番が1にリセット
  される脆弱性を解消している。

  Reconciles the system-extracted target list against the operator-managed CSV across three
  timelines (past/current/future). A "belt conveyor" holiday-safety mechanism freezes
  current-timeline additions/removals on days when the manual CSV isn't updated, preventing
  numbering drift. The maximum historical sequence number is isolated in its own CTE and
  joined via CROSS JOIN, eliminating a reset-to-1 vulnerability when the manual list is empty.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
  1. manual_target_list / auto_extracted_target_list / weekday_calendar_master
     比較対象データと曜日マスタの取得
  2. past_max_present_no
     過去の最大採番Noの独立取得（脆弱性対策）
  3. verify_past_targets / verify_current_targets / verify_future_targets
     タイムライン別の突合検証（現在分は休日ブロック判定を含む）
  4. combine_new_and_future_targets / assign_new_present_no
     新規対象者への自動採番
  5. Final Output

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  user_id, product_subsc_ship_category

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  gift_seq_no

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: FULL JOIN, CROSS JOIN, DAYOFWEEK)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 対象者リスト突合中間テーブル
  int_target_list_reconciliation
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [Manual List] 記録用の手動更新テーブル（CSV）
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
manual_target_list AS (
    SELECT
        gift_seq_no,
        user_id,
        digital_gift_present_date,
        product_subsc_ship_category,
        digital_gift_expiration_date,
        NULLIF(serial_number, '') AS serial_number,
        irregular_gift_present_date,
        email_send_status,

        CASE
            WHEN DATEDIFF(day, digital_gift_present_date, CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE) > 0 THEN '過去'
            WHEN DATEDIFF(day, digital_gift_present_date, CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE) = 0 THEN '現在'
            WHEN DATEDIFF(day, digital_gift_present_date, CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE) < 0 THEN '未来'
            ELSE NULL
        END AS time_line

    FROM
        map_gift_target_ledger -- 対象者リスト
),

----------------------------------------------------------------------
-- 2. [System List] 自動抽出された最新の対象者リスト
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
auto_extracted_target_list AS (
    SELECT
        user_id, order_id, order_no, order_status, order_status_numbr,

        CASE WHEN is_payment_received = 1 THEN '入金済' ELSE '未入金' END AS payment_status,

        ship_date, delivered_date, digital_gift_present_date,

        is_product_a_first_order, is_product_b_first_order,
        is_course_3bottle_first, is_course_upgraded_1_to_2, is_course_upgraded_1_to_3,
        is_eligible_for_bonus_gift,

        product_subsc_ship_category,
        is_subsc_active,

        is_cus_black, is_cus_deleted_merged, is_cus_merged,

        DATEDIFF(day, CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE, digital_gift_present_date) AS lead_time_present_date,
        time_line

    FROM
        int_predelivery_alert_check -- 【前工程】10_int_predelivery_alert_check

    WHERE
        is_shipped_not_delivered <> 1 -- 出荷から10日以上経過で出荷止まりは除外
      AND is_payment_pending <> 1     -- 出荷から10日以上経過で未入金止まりは除外
      AND is_due_to_email_error <> 1  -- メールアドレスに不備がある顧客は除外
),

----------------------------------------------------------------------
-- 3. [Weekday Master] 曜日による動作スイッチ用リスト
--    Data Grain: weekday_category_id
----------------------------------------------------------------------
weekday_calendar_master AS (
    SELECT
        weekday_category_id,
        weekday_category_name,
        is_holiday
    FROM
        dim_weekday_calendar -- 曜日別稼働カレンダー
),

----------------------------------------------------------------------
-- 4. [Numbering Base] 過去の最大採番Noの取得（独立金庫）
--    Data Grain: 1行のみ
----------------------------------------------------------------------
past_max_present_no AS (
    SELECT
        COALESCE(MAX(gift_seq_no), 0) AS max_seq_no_past_time
    FROM
        manual_target_list -- 01. 手動リスト
    WHERE
        time_line = '過去'
),

----------------------------------------------------------------------
-- 5. [Verify Past] 過去分の突き合わせ
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
verify_past_targets AS (
    SELECT
        a.*,

        CASE
            WHEN a.irregular_gift_present_date IS NOT NULL THEN a.irregular_gift_present_date
            ELSE a.digital_gift_present_date
        END AS digital_gift_present_date_adjusted,

        b.order_status_comp,
        b.payment_status_comp,

        CASE
            WHEN NULLIF(a.user_id, '') IS NOT NULL
             AND NULLIF(b.user_id_comp, '') IS NULL THEN '登録抹消'
            ELSE NULL
        END  AS alert_status_main,

        NULL AS alert_status_detail

    FROM
        (SELECT * FROM manual_target_list WHERE time_line = '過去') a

    LEFT JOIN
        (
            SELECT
                user_id AS user_id_comp, order_id AS order_id_comp, order_no AS order_no_comp,
                order_status AS order_status_comp, payment_status AS payment_status_comp,
                ship_date AS ship_date_comp, digital_gift_present_date AS digital_gift_present_date_comp,
                product_subsc_ship_category AS product_subsc_ship_category_comp,
                is_subsc_active AS is_subsc_active_comp, is_cus_black AS is_cus_black_comp,
                is_cus_deleted_merged AS is_cus_deleted_merged_comp, is_cus_merged AS is_cus_merged_comp
            FROM
                auto_extracted_target_list
            WHERE
                time_line = '過去'
              AND order_status_numbr = 6 -- 注文ステータス「配達完了」のみ
        ) b
    ON a.user_id = b.user_id_comp
    AND a.product_subsc_ship_category = b.product_subsc_ship_category_comp

    ORDER BY
        a.gift_seq_no ASC
),

----------------------------------------------------------------------
-- 6. [Verify Current: Base] 現在分の突き合わせ用ベース作成
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
current_targets_raw_set AS (
    SELECT
        CASE WHEN NULLIF(c.user_id, '') IS NULL THEN d.user_id_comp ELSE c.user_id END AS user_id_adjusted,
        NULLIF(c.user_id, '')       AS user_id,
        NULLIF(d.user_id_comp, '')  AS user_id_comp,

        CASE WHEN c.digital_gift_present_date IS NULL THEN d.digital_gift_present_date_comp ELSE c.digital_gift_present_date END AS digital_gift_present_date,

        CASE
            WHEN c.irregular_gift_present_date IS NOT NULL THEN c.irregular_gift_present_date
            WHEN c.digital_gift_present_date IS NULL       THEN d.digital_gift_present_date_comp
            ELSE c.digital_gift_present_date
        END AS digital_gift_present_date_adjusted,

        CASE WHEN NULLIF(c.product_subsc_ship_category, '') IS NULL THEN d.product_subsc_ship_category_comp ELSE c.product_subsc_ship_category END AS product_subsc_ship_category,

        d.order_status_comp,
        d.payment_status_comp,
        c.serial_number,
        c.irregular_gift_present_date,

        CASE WHEN NULLIF(c.time_line, '') IS NULL THEN d.time_line_comp ELSE c.time_line END AS time_line,

        DAYOFWEEK(
            CASE WHEN c.digital_gift_present_date IS NULL THEN d.digital_gift_present_date_comp ELSE c.digital_gift_present_date END
        ) AS weekday_category_id

    FROM
        (
            SELECT user_id, digital_gift_present_date, product_subsc_ship_category,
                   digital_gift_expiration_date, serial_number, irregular_gift_present_date, time_line
            FROM manual_target_list
            WHERE time_line = '現在'
        ) c

    FULL JOIN
        (
            SELECT
                user_id AS user_id_comp, order_id AS order_id_comp, order_no AS order_no_comp,
                order_status AS order_status_comp, payment_status AS payment_status_comp,
                ship_date AS ship_date_comp, digital_gift_present_date AS digital_gift_present_date_comp,
                product_subsc_ship_category AS product_subsc_ship_category_comp,
                is_subsc_active AS is_subsc_active_comp, is_cus_black AS is_cus_black_comp,
                is_cus_deleted_merged AS is_cus_deleted_merged_comp, is_cus_merged AS is_cus_merged_comp,
                time_line AS time_line_comp
            FROM
                auto_extracted_target_list
            WHERE
                time_line = '現在'
              AND order_status_numbr = 6
        ) d
    ON c.user_id = d.user_id_comp
    AND c.product_subsc_ship_category = d.product_subsc_ship_category_comp
),

----------------------------------------------------------------------
-- 7. [Verify Current: Holiday Block] 現在分の突き合わせ（休日ブロック判定）
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
verify_current_targets AS (
    SELECT
        e.user_id_adjusted, e.digital_gift_present_date, e.digital_gift_present_date_adjusted,
        e.product_subsc_ship_category, e.order_status_comp, e.payment_status_comp,
        e.serial_number, e.irregular_gift_present_date, e.time_line,

        -- 休日の場合は、システムに存在しなくなっていても離脱させない（固定）
        CASE
            WHEN COALESCE(f.is_holiday, 0) <> 1
             AND NULLIF(e.user_id, '') IS NOT NULL
             AND NULLIF(e.user_id_comp, '') IS NULL THEN 1
            ELSE 0
        END AS is_excluded,

        -- 休日の場合は、システムに新規で入ってきても追加させない（固定）
        CASE
            WHEN COALESCE(f.is_holiday, 0) = 1
             AND NULLIF(e.user_id, '') IS NULL
             AND NULLIF(e.user_id_comp, '') IS NOT NULL THEN 1
            ELSE 0
        END AS is_included,

        CASE
            WHEN NULLIF(e.user_id, '') IS NOT NULL AND NULLIF(e.user_id_comp, '') IS NULL     THEN '対象離脱'
            WHEN NULLIF(e.user_id, '') IS NULL     AND NULLIF(e.user_id_comp, '') IS NOT NULL THEN '新規追加'
            ELSE NULL
        END  AS alert_status_main,

        NULL AS alert_status_detail

    FROM
        current_targets_raw_set e -- 06. の情報

    LEFT JOIN
        weekday_calendar_master f -- 03. 曜日リスト
    ON e.weekday_category_id = f.weekday_category_id
),

----------------------------------------------------------------------
-- 8. [Verify Future] 未来分の突き合わせ
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
verify_future_targets AS (
    SELECT
        CASE WHEN NULLIF(g.user_id, '') IS NULL THEN h.user_id_comp ELSE g.user_id END AS user_id_adjusted,

        CASE
            WHEN g.digital_gift_present_date IS NULL          THEN h.digital_gift_present_date_comp
            WHEN g.digital_gift_present_date <> h.digital_gift_present_date_comp
             AND g.digital_gift_present_date IS NOT NULL
             AND h.digital_gift_present_date_comp IS NOT NULL THEN h.digital_gift_present_date_comp
            ELSE g.digital_gift_present_date
        END AS digital_gift_present_date,

        CASE
            WHEN g.irregular_gift_present_date IS NOT NULL THEN g.irregular_gift_present_date
            WHEN g.digital_gift_present_date IS NULL       THEN h.digital_gift_present_date_comp
            WHEN g.digital_gift_present_date <> h.digital_gift_present_date_comp
             AND g.digital_gift_present_date IS NOT NULL
             AND h.digital_gift_present_date_comp IS NOT NULL THEN h.digital_gift_present_date_comp
            ELSE g.digital_gift_present_date
        END AS digital_gift_present_date_adjusted,

        CASE WHEN NULLIF(g.product_subsc_ship_category, '') IS NULL THEN h.product_subsc_ship_category_comp ELSE g.product_subsc_ship_category END AS product_subsc_ship_category,

        h.order_status_comp,
        h.payment_status_comp,
        g.serial_number,
        g.irregular_gift_present_date,

        CASE WHEN NULLIF(g.time_line, '') IS NULL THEN h.time_line_comp ELSE g.time_line END AS time_line,

        CASE
            WHEN NULLIF(g.user_id, '') IS NOT NULL AND NULLIF(h.user_id_comp, '') IS NULL THEN 1
            ELSE 0
        END AS is_excluded,

        CASE
            WHEN NULLIF(g.user_id, '') IS NOT NULL AND NULLIF(h.user_id_comp, '') IS NULL     THEN '対象離脱'
            WHEN NULLIF(g.user_id, '') IS NULL     AND NULLIF(h.user_id_comp, '') IS NOT NULL THEN '新規追加'
            ELSE NULL
        END AS alert_status_main,

        CASE
            WHEN g.digital_gift_present_date <> h.digital_gift_present_date_comp
             AND g.digital_gift_present_date IS NOT NULL
             AND h.digital_gift_present_date_comp IS NOT NULL
                THEN g.digital_gift_present_date || ' → ' || h.digital_gift_present_date_comp || ' に更新'
            ELSE NULL
        END AS alert_status_detail

    FROM
        (
            SELECT user_id, digital_gift_present_date, product_subsc_ship_category,
                   digital_gift_expiration_date, serial_number, irregular_gift_present_date, time_line
            FROM manual_target_list
            WHERE time_line = '未来'
        ) g

    FULL JOIN
        (
            SELECT
                user_id AS user_id_comp, order_id AS order_id_comp, order_no AS order_no_comp,
                order_status AS order_status_comp, payment_status AS payment_status_comp,
                ship_date AS ship_date_comp, digital_gift_present_date AS digital_gift_present_date_comp,
                product_subsc_ship_category AS product_subsc_ship_category_comp,
                is_subsc_active AS is_subsc_active_comp, is_cus_black AS is_cus_black_comp,
                is_cus_deleted_merged AS is_cus_deleted_merged_comp, is_cus_merged AS is_cus_merged_comp,
                time_line AS time_line_comp
            FROM auto_extracted_target_list
            WHERE time_line = '未来'
        ) h
    ON g.user_id = h.user_id_comp
    AND g.product_subsc_ship_category = h.product_subsc_ship_category_comp
),

----------------------------------------------------------------------
-- 9. [Union for Numbering] ナンバリング対象データの統合
--    Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
combine_new_and_future_targets AS (
    SELECT
        user_id_adjusted, digital_gift_present_date, digital_gift_present_date_adjusted,
        product_subsc_ship_category, order_status_comp, payment_status_comp,
        serial_number, irregular_gift_present_date, NULL AS email_send_status,
        time_line, alert_status_main, alert_status_detail
    FROM verify_current_targets -- 07. の情報
    WHERE is_excluded <> 1 AND is_included <> 1

    UNION ALL

    SELECT
        user_id_adjusted, digital_gift_present_date, digital_gift_present_date_adjusted,
        product_subsc_ship_category, order_status_comp, payment_status_comp,
        serial_number, irregular_gift_present_date, NULL AS email_send_status,
        time_line, alert_status_main, alert_status_detail
    FROM verify_future_targets -- 08. の情報
    WHERE is_excluded <> 1
),

----------------------------------------------------------------------
-- 10. [Auto Numbering] 新規対象者へのNo付与
--     Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
assign_new_present_no AS (
    SELECT
        *,
        ROW_NUMBER() OVER(
            ORDER BY i.digital_gift_present_date_adjusted ASC, i.digital_gift_present_date ASC, i.user_id_adjusted ASC
        ) + COALESCE(j.max_seq_no_past_time, 0) AS gift_seq_no

    FROM
        combine_new_and_future_targets i -- 09. の情報

    CROSS JOIN
        past_max_present_no j -- 04. 独立させた過去最大No
),

----------------------------------------------------------------------
-- 11. [Final Union] すべての検証済データの結合
--     Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
combine_all_verified_targets AS (
    SELECT
        gift_seq_no, user_id, digital_gift_present_date, digital_gift_present_date_adjusted,
        product_subsc_ship_category, order_status_comp, payment_status_comp,
        serial_number, irregular_gift_present_date, email_send_status,
        time_line, alert_status_main, alert_status_detail
    FROM verify_past_targets -- 05. 過去分の情報

    UNION ALL

    SELECT
        gift_seq_no, user_id_adjusted AS user_id, digital_gift_present_date, digital_gift_present_date_adjusted,
        product_subsc_ship_category, order_status_comp, payment_status_comp,
        serial_number, irregular_gift_present_date, email_send_status,
        time_line, alert_status_main, alert_status_detail
    FROM assign_new_present_no -- 10. 新規採番済みの情報
)

----------------------------------------------------------------------
-- 12. [Final Output] 分析・確認用データの整形と最適化
--     Data Grain: user_id, product_subsc_ship_category
----------------------------------------------------------------------
SELECT
    gift_seq_no                         AS "No",
    user_id                             AS "ユーザーID",
    digital_gift_present_date           AS "プレゼント日_デジタルギフト",
    product_subsc_ship_category         AS "商品/定期/出荷_分類",
    order_status_comp                   AS "注文ステータス",
    payment_status_comp                 AS "入金ステータス",
    serial_number                       AS "シリアルナンバー",
    irregular_gift_present_date         AS "イレギュラープレゼント日_デジタルギフト",
    email_send_status                   AS "メール配信ステータス_手動CSV由来",

    time_line                           AS "タイムライン",
    DATEDIFF(day, CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE,
            digital_gift_present_date)   AS "本日からデジタルギフトまでの日数",
    digital_gift_present_date_adjusted  AS "プレゼント日_デジタルギフト_イレギュラー加味",

    alert_status_main                   AS "アラート_大分類",
    alert_status_detail                 AS "アラート_詳細"

FROM
    combine_all_verified_targets -- 11. の情報

ORDER BY
    gift_seq_no ASC
;
