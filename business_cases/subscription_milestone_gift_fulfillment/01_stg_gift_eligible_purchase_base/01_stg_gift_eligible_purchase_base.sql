/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 デジタルギフト特典の起点（F1）候補者抽出マスタ（ユーザー単位例外対応）
  Gift-Eligible Purchase Base Extraction (User-Level Exceptions) — Staging Layer

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. 起点購入の抽出
     特典対象商品ラインの「新規購入コード」で購入した明細を抽出する。
  2. ユーザー単位の手動例外反映
     注文単位に集約したうえで、手動運用リスト（CSV）による「ユーザー単位の削除」および
     「特例追加」フラグを反映する。注文単位の削除は責務を分離し、後工程で行う。
  3. 複数ファクトによる頑健な対象判定
     過去、特典コード自体に商品名の表記ゆれがあった歴史的経緯を吸収するため、
     単一フラグに依存せず「商品名にギフト表記があるか」「過去のDM送付履歴があるか」
     「同梱物にギフト対象の印字があるか」の3つのファクト（証拠）のいずれかで裏付けを取る。

  1. Anchor Purchase Extraction
     Extracts line items purchased with a "new customer" code belonging to gift-eligible
     product lines.
  2. User-Level Manual Exception Handling
     After aggregating to the order grain, applies user-level manual deletion/addition flags
     from an operator-managed CSV. Order-level deletion is deliberately deferred to the next
     query to keep data-grain concerns separated.
  3. Robust Multi-Fact Eligibility Evaluation
     To absorb historical inconsistencies (e.g., a period where the gift wording was missing
     from the product name), eligibility is confirmed by any of three independent facts:
     product name marker, past DM history, or an insert-marker printed on the invoice.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
このクエリは以下の処理ステップで構成されています。
This query consists of the following processing layers.

  1. purchase_base
     特典対象商品ラインの新規購入明細の抽出
     Extraction of line items purchased under gift-eligible new-customer codes.

  2. filter_by_user_level_exceptions
     注文単位への集約とユーザー単位の手動例外反映
     Aggregation to order grain and application of user-level manual exceptions.

  3. add_evaluation_flags
     DM履歴・同梱物印字との結合による対象者ファクトの付与
     Enrichment with DM history and insert-marker facts to confirm eligibility.

  4. Final Output
     状態カテゴリの付与と出力
     Final output with derived classification labels.

【データ粒度 / Data Grain】
----------------------------------------------------------------------------------------------
  Order Level (F1候補の注文単位)

【主キー / Primary Key】
----------------------------------------------------------------------------------------------
  user_id, order_id

【実行環境 / Execution Environment】
----------------------------------------------------------------------------------------------
  Standard SQL (Snowflake compatible: LISTAGG / ARRAY_AGG)

【出力データ / Output Dataset】
----------------------------------------------------------------------------------------------
 デジタルギフト特典 F1候補者ステージングテーブル
  stg_gift_eligible_purchase_base
==============================================================================================
*/

WITH
----------------------------------------------------------------------
-- 1. [Anchor Base] 特典対象商品ラインの新規購入明細抽出
--    Data Grain: order_id, line_no
----------------------------------------------------------------------
purchase_base AS (
    SELECT
        user_id,
        order_id,
        line_no,

        product_id,
        product_name,
        product_analysis_category_level_4,
        product_analysis_category_level_5,

        order_status,
        order_status_numbr,
        is_payment_received,
        ordered_date,
        shipment_date,
        delivered_date,

        -- キャンペーンフラグ（外部パラメータ由来）
        is_product_a_first_order,        -- 商品ラインAの新規コードで購入
        is_product_b_first_order,        -- 商品ラインBの新規コードで購入
        is_course_3bottle_first,         -- 初回3本コースのコードで購入
        is_course_upgraded_1_to_2,       -- 初回1本、2回目からは2本コードで購入
        is_course_upgraded_1_to_3,       -- 初回1本、2回目からは3本コードで購入
        is_gift_eligible_code,           -- 特典（デジタルギフト）がつくコードで購入

        -- 商品名にギフト表記があるかの判定（歴史的経緯の吸収用）
        CASE WHEN product_name LIKE '%GIFT_MARKER%' THEN 1 ELSE 0 END AS has_product_name_gift_marker,

        quantity,
        is_subsc,
        subsc_id,

        is_sys_return,
        return_completed_date,

        is_cus_black,
        is_cus_deleted_merged,
        is_cus_merged

    FROM
        raw_gift_eligible_purchases -- 【元データ】特典対象商品ラインの購入明細抽出（GUIパラメータ層で事前絞込済み）

    WHERE
        is_product_a_first_order = 1
       OR is_product_b_first_order = 1
),

----------------------------------------------------------------------
-- 2. [User-Level Correction] 注文単位への集約と除外データのフィルタリング
--    Data Grain: order_id
----------------------------------------------------------------------
filter_by_user_level_exceptions AS (
    SELECT
        a.*,

        COALESCE(b.is_deleted_by_user_list, 0)   AS is_deleted_by_user_list,
        COALESCE(b.is_manual_override_add, 0)    AS is_manual_override_add

    FROM
        (
        SELECT
            user_id,
            order_id,
            LISTAGG(product_id, ',') WITHIN GROUP (ORDER BY product_id ASC) AS product_id,
            ARRAY_TO_STRING(ARRAY_AGG(product_name) WITHIN GROUP (ORDER BY product_id ASC), ', ') AS product_name,
            MAX(order_status)                  AS order_status,
            MAX(order_status_numbr)             AS order_status_numbr,
            MAX(is_payment_received)            AS is_payment_received,
            MAX(ordered_date)                   AS ordered_date,
            MAX(shipment_date)                  AS shipment_date,
            MAX(delivered_date)                 AS delivered_date,
            MAX(is_product_a_first_order)       AS is_product_a_first_order,
            MAX(is_product_b_first_order)       AS is_product_b_first_order,
            MAX(is_course_3bottle_first)        AS is_course_3bottle_first,
            MAX(is_course_upgraded_1_to_2)      AS is_course_upgraded_1_to_2,
            MAX(is_course_upgraded_1_to_3)      AS is_course_upgraded_1_to_3,
            MAX(is_gift_eligible_code)          AS is_gift_eligible_code,
            MAX(has_product_name_gift_marker)   AS has_product_name_gift_marker,
            SUM(quantity)                       AS quantity,
            MAX(is_subsc)                       AS is_subsc,
            MAX(subsc_id)                       AS subsc_id,
            MAX(is_sys_return)                  AS is_sys_return,
            MAX(return_completed_date)          AS return_completed_date,
            MAX(is_cus_black)                   AS is_cus_black,
            MAX(is_cus_deleted_merged)          AS is_cus_deleted_merged,
            MAX(is_cus_merged)                  AS is_cus_merged
        FROM
            purchase_base -- 01. の情報
        GROUP BY
            user_id, order_id
        ) a

    -- 【手動対応】ユーザー単位の削除・追加リストを結合
    LEFT JOIN
        map_gift_manual_exceptions b -- 手動対応リスト（ユーザー単位の削除／特例追加）
    ON a.user_id = b.user_id
    AND b.exception_type IN ('DELETE_BY_USER', 'ADD_IRREGULAR')

    WHERE
        a.is_sys_return <> 1
      AND COALESCE(b.is_deleted_by_user_list, 0) <> 1
),

----------------------------------------------------------------------
-- 3. [Fact Evaluation] 対象者の確定とファクト（証拠）の結合
--    Data Grain: order_id
----------------------------------------------------------------------
add_evaluation_flags AS (
    SELECT
        c.*,

        COALESCE(d.has_dm_gift_history, 0)     AS has_dm_gift_history,
        COALESCE(e.has_insert_gift_marker, 0)  AS has_insert_gift_marker

    FROM
        filter_by_user_level_exceptions c -- 02. の情報

    -- 【ファクト補強】過去のDM履歴マスタを結合
    LEFT JOIN
        (
            SELECT
                user_id,
                1 AS has_dm_gift_history
            FROM
                raw_dm_history -- レガシーDM配信システム連携履歴
            WHERE
                dm_code = 'GIFT_DM_CODE' -- （DM発送なし）ギフト特典プレゼント対象者
            GROUP BY
                user_id
        ) d
    ON c.user_id = d.user_id

    -- 【ファクト補強】注文時、明細書にギフト特典関係の印字があるかどうか
    LEFT JOIN
        (
            SELECT
                user_id,
                order_id,
                1 AS has_insert_gift_marker
            FROM
                raw_catalog_gift_markers -- 全購入データにおけるカタログ/プレゼント同梱物編集
            WHERE
                insert_product_code IN ('GIFT_INSERT_CODE_1', 'GIFT_INSERT_CODE_2') -- 明細書へのギフト特典印字用ダミー商品
            GROUP BY
                user_id, order_id
        ) e
    ON c.user_id = e.user_id
    AND c.order_id = e.order_id

    WHERE
        (
          c.is_gift_eligible_code = 1
          AND (
                c.has_product_name_gift_marker = 1
                OR COALESCE(d.has_dm_gift_history, 0) = 1
                OR COALESCE(e.has_insert_gift_marker, 0) = 1
              )
        )
       OR c.is_manual_override_add = 1
)

----------------------------------------------------------------------
-- 4. [Final Output] 分析・確認用データの整形
--    Data Grain: order_id
----------------------------------------------------------------------
SELECT
    -- ====== IDs ======
    user_id                        AS "ユーザーID",
    order_id                       AS "注文ID",
    product_id                     AS "商品ID",
    product_name                   AS "商品名",
    order_status                   AS "注文ステータス",
    order_status_numbr             AS "受注明細状態",
    is_payment_received            AS "入金済フラグ",
    ordered_date                   AS "受注日",
    shipment_date                  AS "出荷日",
    delivered_date                 AS "配達完了日",
    is_sys_return                  AS "返品フラグ_システム基準",
    return_completed_date          AS "返品受付日",
    quantity                       AS "注文数",
    subsc_id                       AS "定期購入ID",

    -- ====== Gift Eligibility & Course Flags ======
    is_product_a_first_order       AS "商品ラインA_新規フラグ_注文単位",
    is_product_b_first_order       AS "商品ラインB_新規フラグ_注文単位",
    is_course_3bottle_first        AS "初回3本_定期フラグ",
    is_course_upgraded_1_to_2      AS "初回1本→2本_定期フラグ",
    is_course_upgraded_1_to_3      AS "初回1本→3本_定期フラグ",
    is_gift_eligible_code          AS "デジタルギフトフラグ",
    has_product_name_gift_marker   AS "商品名「ギフト表記」有フラグ",

    -- ====== Irregular / Check Flags ======
    is_manual_override_add         AS "イレギュラー追加フラグ",
    has_dm_gift_history             AS "DM履歴「ギフト対象」フラグ",
    has_insert_gift_marker          AS "同梱物「ギフト表記」有フラグ",
    is_cus_black                   AS "ブラックフラグ",
    is_cus_deleted_merged          AS "削除/統合フラグ",
    is_cus_merged                  AS "顧客統合フラグ",

    -- ====== Derived Category Labels ======
    CASE
        WHEN is_product_a_first_order = 1 THEN '[PRODUCT_A] '
        WHEN is_product_b_first_order = 1 THEN '[PRODUCT_B] '
        ELSE NULL
    END AS "商品_分類",

    CASE
        WHEN is_course_3bottle_first = 1 THEN '3本定期 : '
        WHEN is_course_upgraded_1_to_2 = 1
          OR is_course_upgraded_1_to_3 = 1 THEN '2本定期 : '
        ELSE NULL
    END AS "定期_分類",

    '1回目出荷' AS "出荷_分類"

FROM
    add_evaluation_flags -- 03. の情報
;
