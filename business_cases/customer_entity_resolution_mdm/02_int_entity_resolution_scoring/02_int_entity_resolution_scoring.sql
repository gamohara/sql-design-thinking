/*
==============================================================================================
【クエリ概要 / Query Overview】
----------------------------------------------------------------------------------------------
 顧客エンティティ解決および名寄せスコアリングマスタ
  Customer Entity Resolution & Deduplication Scoring (Intermediate Layer)

【業務ロジック / Business Logic】
----------------------------------------------------------------------------------------------
  1. 段階的ゲートマッチング
     顧客マスタ内の個人情報（姓名、カナ、郵便番号、電話番号、メール）の組み合わせを
     5段階（厳格〜寛容）で評価し、「同一人物である可能性」をランク付けします。
  2. NULL暴走の防止
     未入力項目（NULL）同士が誤って「一致」と判定されるのを防ぐため、
     比較用カラムには「DUMMY_ + 自身のユーザーID」を埋め込む安全装置を実装。
  3. 外部シグナルの統合
     システム上のマッチング結果に加え、前工程（01_stg_customer_note_merge_requests）で
     抽出したCSスタッフによる「応対メモの統合シグナル」を掛け合わせ、最終スコアを動的に決定。
  4. 重複IDの安全な集約
     各関門で抽出された「同一人物候補のIDリスト」を、配列操作関数
     （SPLIT, ARRAY_DISTINCT, ARRAY_TO_STRING）を用いて安全に重複排除しマージ。

  1. Multi-Gate Heuristic Matching
     Evaluates combinations of PII across 5 progressive gates (strict to relaxed) 
     to rank the probability of duplicate customer records.
  2. Null-Poisoning Prevention
     Comparison columns are padded with a unique string ('DUMMY_' + user_id) to prevent 
     false positives where NULL values unintentionally match each other.
  3. External Signal Integration
     Combines system matching results with human-in-the-loop signals (CS merge requests) 
     extracted in the previous step to dynamically determine the final score.
  4. Safe Array Aggregation
     Utilizes array functions to safely deduplicate and merge candidate ID lists 
     identified across multiple matching gates.

【CTE構造 / CTE Structure】
----------------------------------------------------------------------------------------------
このクエリは以下の処理ステップで構成されています。
This query consists of the following processing layers.

  1. extract_customer_base
     顧客基本情報と応対メモシグナルの抽出、NULL時暴走を防ぐ比較用項目の作成。
  2. agg_matching_groups
     各関門の組み合わせごとに、重複人数と対象ユーザーIDのリストをウィンドウ関数で集計。
  3. detect_duplicate_users
     各組み合わせにおいて、重複（2人以上）しているかを判定。
  4. determine_exclusive_match_gate
     優先度の高い関門を正として排他フラグを立て、重複IDリストを配列操作でマージ。
  5. calc_match_score
     システムマッチと応対メモを統合して最終スコアを付与し、全関連IDを統合。
  6. Final Output
     名寄せ候補のみを抽出し、ランクおよびフラグを付与して最終出力。

【データ粒度 / Data Grain】
----------------------------------------------------------------------
  User ID Level (1ユーザー1行)

【実行環境 / Execution Environment】
----------------------------------------------------------------------
  Standard SQL (Snowflake compatible: utilizes ARRAY_DISTINCT, SPLIT, ARRAY_TO_STRING)

【出力データ / Output Dataset】
----------------------------------------------------------------------
 名寄せスコアリング中間テーブル
  int_entity_resolution_scoring
==============================================================================================
*/

WITH 
----------------------------------------------------------------------
-- 1. [Base Extraction] ユーザー情報の整理と名寄せ用比較項目の作成
----------------------------------------------------------------------
extract_customer_base AS (
    SELECT 
        -- IDs
        a.user_id, 
        
        -- Display Columns (表示用)
        NULLIF(TRIM(COALESCE(a.last_name, '') || COALESCE(a.first_name, '')), '') AS customer_name,
        NULLIF(TRIM(COALESCE(a.last_name_kana, '') || COALESCE(a.first_name_kana, '')), '') AS customer_name_kana,
        NULLIF(TRIM(REPLACE(a.postal_code, '-', '')), '') AS postal_code,
        NULLIF(TRIM(REPLACE(a.phone_number, '-', '')), '') AS phone_number,
        NULLIF(TRIM(COALESCE(a.mobile_email, a.pc_email)), '') AS email,
        
        -- Match Columns (比較用: NULL時は IDを埋め込み誤一致を防ぐ)
        COALESCE(NULLIF(TRIM(COALESCE(a.last_name, '') || COALESCE(a.first_name, '')), ''), 'DUMMY_' || a.user_id) AS match_name,
        COALESCE(NULLIF(TRIM(COALESCE(a.last_name_kana, '') || COALESCE(a.first_name_kana, '')), ''), 'DUMMY_' || a.user_id) AS match_name_kana,
        COALESCE(NULLIF(TRIM(REPLACE(a.postal_code, '-', '')), ''), 'DUMMY_' || a.user_id) AS match_postal_code,
        COALESCE(NULLIF(TRIM(REPLACE(a.phone_number, '-', '')), ''), 'DUMMY_' || a.user_id) AS match_phone_number,
        COALESCE(NULLIF(TRIM(COALESCE(a.mobile_email, a.pc_email)), ''), 'DUMMY_' || a.user_id) AS match_email,
        
        -- Dates & Status
        a.birth_date, 
        a.customer_acquisition_date, 
        TO_NUMBER(COALESCE(NULLIF(TRIM(a.is_deleted), ''), '0')) AS is_deleted,
        TO_NUMBER(COALESCE(NULLIF(TRIM(a.is_merged), ''), '0')) AS is_merged,
        
        -- Exclusion Flags
        CASE WHEN NULLIF(a.last_name, '') LIKE '%********%' OR NULLIF(a.last_name, '') LIKE '%テスト%' OR NULLIF(a.last_name, '') IS NULL THEN 1 ELSE 0 END AS is_test_customer,
        CASE WHEN TRIM(a.user_management_level) IN ('employee', 'client') THEN 1 ELSE 0 END AS is_employee_client,
        
        -- External Signals (前工程: 01_stg_customer_note_merge_requests 由来)
        COALESCE(b.is_merge_requested_in_note, 0) AS is_match_incident,
        COALESCE(b.has_valid_target_user_id, 0) AS has_user_id_match,
        COALESCE(b.is_target_deleted_or_merged, 0) AS is_deleted_or_merged,
        NULLIF(b.extracted_target_user_ids, '') AS merged_user_ids
        
    FROM
        raw_users_current a 
    LEFT JOIN
        stg_customer_note_merge_requests b ON a.user_id = b.user_id
), 

----------------------------------------------------------------------
-- 2. [Group Aggregation] 各関門の組み合わせごとに重複人数とIDリストを算出
----------------------------------------------------------------------
agg_matching_groups AS (
    SELECT 
        *,
        -- Gate 1 (5 Elements)
        COUNT(*) OVER(PARTITION BY match_name, match_name_kana, match_postal_code, match_phone_number, match_email) AS gate1_count,
        LISTAGG(user_id, ',') WITHIN GROUP (ORDER BY user_id ASC) OVER(PARTITION BY match_name, match_name_kana, match_postal_code, match_phone_number, match_email) AS gate1_check_userid_all,
        
        -- Gate 2 (4 Elements)
        COUNT(*) OVER(PARTITION BY match_name, match_postal_code, match_phone_number, match_email) AS gate2_01_count,
        LISTAGG(user_id, ',') WITHIN GROUP (ORDER BY user_id ASC) OVER(PARTITION BY match_name, match_postal_code, match_phone_number, match_email) AS gate2_01_check_userid_all,
        COUNT(*) OVER(PARTITION BY match_name_kana, match_postal_code, match_phone_number, match_email) AS gate2_02_count,
        LISTAGG(user_id, ',') WITHIN GROUP (ORDER BY user_id ASC) OVER(PARTITION BY match_name_kana, match_postal_code, match_phone_number, match_email) AS gate2_02_check_userid_all,
        
        -- Gate 3 (3 Elements)
        COUNT(*) OVER(PARTITION BY match_name, match_phone_number, match_email) AS gate3_01_count,
        LISTAGG(user_id, ',') WITHIN GROUP (ORDER BY user_id ASC) OVER(PARTITION BY match_name, match_phone_number, match_email) AS gate3_01_check_userid_all,
        COUNT(*) OVER(PARTITION BY match_name_kana, match_phone_number, match_email) AS gate3_02_count,
        LISTAGG(user_id, ',') WITHIN GROUP (ORDER BY user_id ASC) OVER(PARTITION BY match_name_kana, match_phone_number, match_email) AS gate3_02_check_userid_all,
        COUNT(*) OVER(PARTITION BY match_name, match_postal_code, match_phone_number) AS gate3_03_count,
        LISTAGG(user_id, ',') WITHIN GROUP (ORDER BY user_id ASC) OVER(PARTITION BY match_name, match_postal_code, match_phone_number) AS gate3_03_check_userid_all,
        COUNT(*) OVER(PARTITION BY match_name_kana, match_postal_code, match_phone_number) AS gate3_04_count,
        LISTAGG(user_id, ',') WITHIN GROUP (ORDER BY user_id ASC) OVER(PARTITION BY match_name_kana, match_postal_code, match_phone_number) AS gate3_04_check_userid_all,
        COUNT(*) OVER(PARTITION BY match_name, match_postal_code, match_email) AS gate3_05_count,
        LISTAGG(user_id, ',') WITHIN GROUP (ORDER BY user_id ASC) OVER(PARTITION BY match_name, match_postal_code, match_email) AS gate3_05_check_userid_all,
        COUNT(*) OVER(PARTITION BY match_name_kana, match_postal_code, match_email) AS gate3_06_count,
        LISTAGG(user_id, ',') WITHIN GROUP (ORDER BY user_id ASC) OVER(PARTITION BY match_name_kana, match_postal_code, match_email) AS gate3_06_check_userid_all,
        
        -- Gate 4 (1 Element: Email)
        COUNT(*) OVER(PARTITION BY match_email) AS gate4_count,
        LISTAGG(user_id, ',') WITHIN GROUP (ORDER BY user_id ASC) OVER(PARTITION BY match_email) AS gate4_check_userid_all,
        
        -- Gate 5 (2 Elements)
        COUNT(*) OVER(PARTITION BY match_name, match_postal_code) AS gate5_01_count,
        LISTAGG(user_id, ',') WITHIN GROUP (ORDER BY user_id ASC) OVER(PARTITION BY match_name, match_postal_code) AS gate5_01_check_userid_all,
        COUNT(*) OVER(PARTITION BY match_name_kana, match_postal_code) AS gate5_02_count,
        LISTAGG(user_id, ',') WITHIN GROUP (ORDER BY user_id ASC) OVER(PARTITION BY match_name_kana, match_postal_code) AS gate5_02_check_userid_all,
        COUNT(*) OVER(PARTITION BY match_name, match_phone_number) AS gate5_03_count,
        LISTAGG(user_id, ',') WITHIN GROUP (ORDER BY user_id ASC) OVER(PARTITION BY match_name, match_phone_number) AS gate5_03_check_userid_all,
        COUNT(*) OVER(PARTITION BY match_name_kana, match_phone_number) AS gate5_04_count,
        LISTAGG(user_id, ',') WITHIN GROUP (ORDER BY user_id ASC) OVER(PARTITION BY match_name_kana, match_phone_number) AS gate5_04_check_userid_all

    FROM extract_customer_base
    WHERE is_test_customer <> 1 AND is_employee_client <> 1
),

----------------------------------------------------------------------
-- 3. [Duplicate Detection] 重複（2人以上）しているかを判定
----------------------------------------------------------------------
detect_duplicate_users AS (
    SELECT 
        *,
        CASE WHEN gate1_count > 1 THEN 1 ELSE 0 END AS is_gate1_match_user,
        CASE WHEN gate1_count > 1 THEN gate1_check_userid_all ELSE NULL END AS gate1_check_userid,
        CASE WHEN gate2_01_count > 1 OR gate2_02_count > 1 THEN 1 ELSE 0 END AS is_gate2_match_user,
        CASE WHEN gate2_01_count > 1 THEN gate2_01_check_userid_all ELSE NULL END AS gate2_01_check_userid,
        CASE WHEN gate2_02_count > 1 THEN gate2_02_check_userid_all ELSE NULL END AS gate2_02_check_userid,
		CASE
			WHEN gate3_01_count > 1 OR gate3_02_count > 1 OR gate3_03_count > 1 OR gate3_04_count > 1 OR gate3_05_count > 1 OR gate3_06_count > 1  THEN 1
			ELSE 0
		END AS is_gate3_match_user,
        CASE WHEN gate3_01_count > 1 THEN gate3_01_check_userid_all ELSE NULL END AS gate3_01_check_userid,
        CASE WHEN gate3_02_count > 1 THEN gate3_02_check_userid_all ELSE NULL END AS gate3_02_check_userid,
        CASE WHEN gate3_03_count > 1 THEN gate3_03_check_userid_all ELSE NULL END AS gate3_03_check_userid,
        CASE WHEN gate3_04_count > 1 THEN gate3_04_check_userid_all ELSE NULL END AS gate3_04_check_userid,
        CASE WHEN gate3_05_count > 1 THEN gate3_05_check_userid_all ELSE NULL END AS gate3_05_check_userid,
        CASE WHEN gate3_06_count > 1 THEN gate3_06_check_userid_all ELSE NULL END AS gate3_06_check_userid,
        CASE WHEN gate4_count > 1 THEN 1 ELSE 0 END AS is_gate4_match_user,
        CASE WHEN gate4_count > 1 THEN gate4_check_userid_all ELSE NULL END AS gate4_check_userid,
		CASE
			WHEN gate5_01_count > 1 OR gate5_02_count > 1 OR gate5_03_count > 1 OR gate5_04_count > 1  THEN 1
			ELSE 0
		END AS is_gate5_match_user,
        CASE WHEN gate5_01_count > 1 THEN gate5_01_check_userid_all ELSE NULL END AS gate5_01_check_userid,
        CASE WHEN gate5_02_count > 1 THEN gate5_02_check_userid_all ELSE NULL END AS gate5_02_check_userid,
        CASE WHEN gate5_03_count > 1 THEN gate5_03_check_userid_all ELSE NULL END AS gate5_03_check_userid,
        CASE WHEN gate5_04_count > 1 THEN gate5_04_check_userid_all ELSE NULL END AS gate5_04_check_userid
    FROM agg_matching_groups
),

----------------------------------------------------------------------
-- 4. [Exclusive Logic] 優先度の高い関門を正として排他処理
----------------------------------------------------------------------
determine_exclusive_match_gate AS (
    SELECT 
        *,
        is_gate1_match_user AS is_gate1_match,
		CASE WHEN is_gate1_match_user <> 1 AND is_gate2_match_user = 1 THEN 1 ELSE 0 END AS is_gate2_match,
		ARRAY_TO_STRING(ARRAY_DISTINCT(SPLIT(NULLIF(TRIM(COALESCE(gate2_01_check_userid || ',', '') || COALESCE(gate2_02_check_userid || ',', ''), ','), ''), ',')), ',') AS gate2_check_userid,
		CASE WHEN is_gate1_match_user <> 1 AND is_gate2_match_user <> 1 AND is_gate3_match_user = 1 THEN 1 ELSE 0 END AS is_gate3_match,
		ARRAY_TO_STRING(ARRAY_DISTINCT(SPLIT(NULLIF(TRIM(COALESCE(gate3_01_check_userid || ',', '') || COALESCE(gate3_02_check_userid || ',', '') || COALESCE(gate3_03_check_userid || ',', '') || COALESCE(gate3_04_check_userid || ',', '') || COALESCE(gate3_05_check_userid || ',', '') || COALESCE(gate3_06_check_userid || ',', ''), ','), ''), ',')), ',') AS gate3_check_userid,
		CASE WHEN is_gate1_match_user <> 1 AND is_gate2_match_user <> 1 AND is_gate3_match_user <> 1 AND is_gate4_match_user = 1 THEN 1 ELSE 0 END AS is_gate4_match,
		CASE WHEN is_gate1_match_user <> 1 AND is_gate2_match_user <> 1 AND is_gate3_match_user <> 1 AND is_gate4_match_user <> 1 AND is_gate5_match_user = 1 THEN 1 ELSE 0 END AS is_gate5_match,
		ARRAY_TO_STRING(ARRAY_DISTINCT(SPLIT(NULLIF(TRIM(COALESCE(gate5_01_check_userid || ',', '') || COALESCE(gate5_02_check_userid || ',', '') || COALESCE(gate5_03_check_userid || ',', '') || COALESCE(gate5_04_check_userid || ',', ''), ','), ''), ',')), ',') AS gate5_check_userid
    FROM detect_duplicate_users
),

----------------------------------------------------------------------
-- 5. [Scoring] スコアリングとID統合
----------------------------------------------------------------------
calc_match_score AS (
    SELECT 
        *,
		CASE
			WHEN is_gate1_match = 1 THEN 5
			WHEN is_gate2_match = 1 THEN 4
			WHEN is_gate3_match = 1 THEN 3
			WHEN is_match_incident = 1 AND has_user_id_match = 1 THEN 3
			WHEN (is_gate4_match = 1 OR is_gate5_match = 1) AND is_match_incident = 1 AND has_user_id_match <> 1 THEN 2
			WHEN (is_gate4_match = 1 OR is_gate5_match = 1) AND is_match_incident <> 1 AND has_user_id_match <> 1 THEN 1
		    ELSE 0
		END AS match_score,
		CASE
			WHEN is_gate1_match <> 1 AND is_gate2_match <> 1 AND is_gate3_match <> 1 AND is_gate4_match <> 1 AND is_gate5_match <> 1 
                 AND (is_match_incident = 1 OR has_user_id_match = 1) THEN 1
		    ELSE 0
		END AS is_review_required,
		ARRAY_TO_STRING(ARRAY_DISTINCT(SPLIT(NULLIF(TRIM(COALESCE(gate1_check_userid || ',', '') || COALESCE(gate2_check_userid || ',', '') || COALESCE(gate3_check_userid || ',', '') || COALESCE(gate4_check_userid || ',', '') || COALESCE(gate5_check_userid || ',', '') || COALESCE(merged_user_ids || ',', ''), ','), ''), ',')), ',') AS match_userid,
        CASE WHEN is_deleted = 1 OR is_merged = 1 OR is_deleted_or_merged = 1 THEN 1 ELSE 0 END AS is_delete_merged
	FROM
		determine_exclusive_match_gate
	WHERE
		is_gate1_match = 1 OR is_gate2_match = 1 OR is_gate3_match = 1 OR is_gate4_match = 1 OR is_gate5_match = 1 OR is_match_incident = 1
)

----------------------------------------------------------------------
-- 6. [Final Output] 名寄せ候補の最終出力
----------------------------------------------------------------------
SELECT
	user_id                                           AS "ユーザーID", 
	customer_name                                     AS "氏名",
	customer_name_kana                                AS "氏名かな",
	postal_code                                       AS "郵便番号",
	phone_number                                      AS "電話番号",
    email                                             AS "メールアドレス",
	birth_date                                        AS "生年月日", 
	customer_acquisition_date                         AS "顧客獲得日", 
	is_gate1_match                                    AS "精度「最高」_統合フラグ",
	is_gate2_match                                    AS "精度「高」_統合フラグ",
	is_gate3_match                                    AS "精度「中」_統合フラグ",
	is_gate4_match                                    AS "精度「低」_統合フラグ",
	is_gate5_match                                    AS "精度「最低」_統合フラグ",
	is_review_required                                AS "確認要_統合フラグ",
    match_userid                                      AS "ユーザーID_統合候補",
	match_score                                       AS "統合ランク",
	CASE WHEN match_score > 2 THEN 1 ELSE 0 END 	  AS "確定_統合フラグ",
	CASE WHEN match_score = 1 THEN 1 ELSE 0 END 	  AS "可能性_統合フラグ",
	is_delete_merged                                  AS "削除/統合フラグ"
FROM
    calc_match_score
ORDER BY
    match_score DESC, postal_code ASC, customer_name_kana ASC
;
