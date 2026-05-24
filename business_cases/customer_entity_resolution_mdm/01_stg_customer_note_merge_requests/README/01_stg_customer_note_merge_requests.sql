/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 カスタマーサポート応対メモからの顧客統合依頼抽出
  Extraction of Customer Merge Requests from Support Notes (Staging Layer)

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. 新旧ユーザーマスタの統合 (Cross-System Master Integration)
     現行システム（Current）と旧システム（Legacy）の顧客マスタを統合し、
     全世代のIDを網羅した検証用ユーザーベースを構築します。
  2. 正規表現によるID抽出 (Regex-based ID Extraction)
     応対メモ（自由記述）の中から、特定のカテゴリ（統合依頼）かつ特定のキーワードを
     含むものをフィルタリングし、正規表現を用いて「8桁の顧客ID」を自動抽出します。
  3. 抽出IDの存在検証 (ID Validation & Cleansing)
     抽出されたIDがマスタに実在するかを検証し、誤検知（False Positive）を排除します。
  4. 双方向マッピングの生成 (Bidirectional Record Expansion)
     「ユーザーAがユーザーBとの統合を依頼した」という情報を、A側・B側双方の
     レコードとして展開（UNION）します。これにより、後続の名寄せスコアリングにおいて
     どちらのIDを主軸にしても統合シグナルを検知可能になります。

  1. Cross-System Master Integration
     Unions current and legacy customer masters to create a comprehensive 
     validation base covering all historical User IDs.
  2. Regex-based ID Extraction
     Filters support notes for specific categories (merge requests) and keywords, 
     then utilizes REGEXP_SUBSTR to automatically extract 8-digit Customer IDs.
  3. ID Validation & Cleansing
     Cross-checks extracted IDs against the integrated master to ensure they exist, 
     eliminating false positives from unstructured text.
  4. Bidirectional Record Expansion
     Expands a single merge request ("User A wants to merge with User B") into 
     bidirectional records for both IDs. This ensures the merge signal is detected 
     regardless of which ID is treated as the primary in downstream scoring.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
このクエリは以下の処理ステップで構成されています。
This query consists of the following processing layers.

  1. comb_user_status_masters / agg_user_status
     現行・旧システムマスタの縦結合およびID単位のステータス集約。
     Union of current/legacy masters and status aggregation per User ID.

  2. extract_incident_memo
     正規表現によるメモからの8桁ID抽出と、ノイズ（定期申込等）の除外。
     Regex extraction of 8-digit IDs from notes and noise reduction.

  3. validate_extracted_userid
     抽出IDの実在確認と、メイン/相手双方の削除・統合フラグの取得。
     ID existence verification and retrieval of status flags for both parties.

  4. generate_merged_userid_list
     ARRAY関数を用いた、重複のない統合候補IDリストの生成。
     Creation of deduplicated candidate ID lists using Array functions.

  5. split_main_user / split_matched_user / union_target_users
     依頼元・依頼先双方に行を展開し、全ての関係者にフラグを伝播。
     Bidirectional expansion to propagate flags to all involved users.

  6. Final Output
     ユーザーID単位での最終集約。
     Final aggregation per User ID.

【データ粒度 / Data Grain】
----------------------------------------------------------------------
  User ID Level (1ユーザー1行)

【出力データ / Output Dataset】
----------------------------------------------------------------------
 顧客統合依頼（応対メモ由来）中間テーブル
  stg_customer_note_merge_requests
==============================================================================================
*/

WITH 
----------------------------------------------------------------------
-- 1. [Master Integration] 現行・旧システムの顧客ステータス統合
----------------------------------------------------------------------
comb_user_status_masters AS (
    -- 現行システムマスタ (Current System)
    SELECT
        user_id, 
        TO_NUMBER(COALESCE(NULLIF(TRIM(is_deleted), ''), '0')) AS is_deleted,
        TO_NUMBER(COALESCE(NULLIF(TRILL(is_merged), ''), '0')) AS is_merged
    FROM 
        raw_users_current

    UNION ALL

    -- 旧システムマスタ (Legacy System)
    SELECT
        user_id, 
        TO_NUMBER(COALESCE(NULLIF(TRIM(is_deleted), ''), '0')) AS is_deleted,
        TO_NUMBER(COALESCE(NULLIF(TRIM(is_merged), ''), '0')) AS is_merged
    FROM 
        raw_users_legacy
),

agg_user_status AS (
    SELECT
        user_id, 
        MAX(is_deleted) AS is_deleted,
        MAX(is_merged)  AS is_merged
    FROM 
        comb_user_status_masters
    GROUP BY
        user_id
),

----------------------------------------------------------------------
-- 2. [Regex Extraction] 応対メモからの8桁ID抽出
----------------------------------------------------------------------
extract_incident_memo AS (
    SELECT
        user_id,
        incident_id, 
        -- 正規表現で「他の数字に囲まれていない連続する8桁」を抽出
        REGEXP_SUBSTR(note_text, '(^|[^0-9])([0-9]{8})([^0-9]|$)', 1, 1, 'e', 2) AS user_id_match
    FROM 
        raw_crm_notes -- 【元データ】顧客応対履歴
    WHERE
        (category_code = 'MERGE_REQUEST_CODE' OR note_text LIKE '%統合%')
        AND note_text NOT LIKE '%定期申込%'
),

----------------------------------------------------------------------
-- 3. [Validation] 抽出されたIDの存在確認とステータス付与
----------------------------------------------------------------------
validate_extracted_userid AS (
    SELECT
        a.user_id, 
        a.incident_id, 
        COALESCE(main.is_deleted, 0)  AS is_deleted_main,
        COALESCE(main.is_merged, 0)   AS is_merged_main,
        
        -- マスタに実在する場合のみIDを残す（誤検知防止）
        CASE WHEN match.user_id IS NOT NULL THEN a.user_id_match ELSE NULL END AS user_id_match_adjusted,
        CASE WHEN match.user_id IS NOT NULL THEN 1 ELSE 0 END AS has_user_id_match,
        
        COALESCE(match.is_deleted, 0)  AS is_deleted_match,
        COALESCE(match.is_merged, 0)   AS is_merged_match
    FROM 
        extract_incident_memo a
    LEFT JOIN agg_user_status main ON a.user_id = main.user_id 
    LEFT JOIN agg_user_status match ON a.user_id_match = match.user_id 
),

----------------------------------------------------------------------
-- 4. [List Generation] 重複のない統合候補リスト(Array)の作成
----------------------------------------------------------------------
generate_merged_userid_list AS (
    SELECT
        *, 
        ARRAY_TO_STRING(
            ARRAY_DISTINCT(
                SPLIT(
                    NULLIF(TRIM(COALESCE(user_id || ',', '') || COALESCE(user_id_match_adjusted || ',', ''), ','), ''), 
                    ','
                )
            ),
            ','
        ) AS merged_user_ids
    FROM 
        validate_extracted_userid
),

----------------------------------------------------------------------
-- 5. [Bidirectional Mapping] 依頼元・依頼先双方への行展開 (Expansion)
----------------------------------------------------------------------
union_target_users AS (
    -- 依頼主側のレコード (Main User)
    SELECT
        user_id, 
        CASE WHEN is_deleted_main = 1 OR is_merged_main = 1 THEN 1 ELSE 0 END AS is_deleted_or_merged,
        merged_user_ids,
        has_user_id_match
    FROM generate_merged_userid_list

    UNION ALL

    -- 抽出された相手側のレコード (Matched User)
    SELECT
        user_id_match_adjusted AS user_id, 
        CASE WHEN is_deleted_match = 1 OR is_merged_match = 1 THEN 1 ELSE 0 END AS is_deleted_or_merged,
        merged_user_ids,
        has_user_id_match
    FROM generate_merged_userid_list
    WHERE has_user_id_match = 1
)

----------------------------------------------------------------------
-- 6. [Final Aggregation] ユーザーID単位での最終集約
----------------------------------------------------------------------
SELECT
    user_id                        AS user_id, 
    MAX(is_deleted_or_merged)      AS is_target_deleted_or_merged, 
    MAX(merged_user_ids)           AS extracted_target_user_ids,
    MAX(has_user_id_match)         AS has_valid_target_user_id,
    1                              AS is_merge_requested_in_note
FROM
    union_target_users
GROUP BY
    user_id
;
