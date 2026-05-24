# 概要 / Overview

カスタマーサポートの応対履歴（非構造化テキスト）から「顧客統合依頼」を自動抽出し、データとして構造化するステージングテーブルの設計例です。

以下の高度なアルゴリズムを含みます。
- **REGEXP_SUBSTR（正規表現）** を用いた、非構造化テキストからの特定パターン（8桁顧客ID）の抽出
- 抽出されたIDの実在性とステータスをマスタと照合する **バリデーション・ロジック**
- 依頼元と依頼先の双方にフラグを伝播させ、名寄せ漏れを防ぐ **双方向マッピング（Bidirectional Mapping）**

This query extracts customer merge requests from unstructured support notes and transforms them into structured data. It features advanced techniques such as Regex-based ID extraction, ID validation against master records, and bidirectional mapping to ensure both parties in a merge request are correctly flagged.

---

# SQL Design Pattern
非構造化テキストの構造化と双方向フラグ伝播ロジック
Structuring Unstructured Text & Bidirectional Flag Propagation Logic

## 課題 / Problem

ECシステムを長年運用する中で、「結婚による改姓」や「引越しによる住所変更」が発生した顧客は、システム的な自動マッチング（氏名や電話番号の一致）だけでは重複を検知できません。
しかし、現場のカスタマーサポート担当者は応対の中で「このお客様は過去のID:12345678と同一人物である」という確信を得て、メモを残している場合があります。この貴重な「人間の知見（非構造化データ）」がテキストに埋もれたままだと、LTVの正確な計測や、初回限定施策の二重利用（不正利用）を完全に防ぐことができません。

In long-running EC systems, automated matching (e.g., via name or phone) often fails to detect duplicates when customers change their surnames or addresses. However, CS agents often identify these duplicates manually and record them in free-text notes like "Merge this with ID: 12345678." If these "human-in-the-loop" insights remain unstructured, it prevents accurate LTV analysis and the detection of promo abuse.

## 解決策 / Solution

**【正規表現によるID抽出 (Regex-based Extraction)】**
自由記述のメモから、正規表現を用いて「前後に数字を含まない純粋な8桁の数字（顧客IDパターン）」を自動抽出します。さらに、抽出されたIDがマスタ（新旧統合マスタ）に実在するかを即座に検証し、ノイズ（電話番号の一部や金額など）による誤検知を最小化しています。

**【双方向マッピングと伝播 (Bidirectional Logic Propagation)】**
「ユーザーAがユーザーBとの統合を依頼した」という1つのイベントから、ユーザーA側・ユーザーB側双方のレコードに「統合依頼あり」のフラグを立てるロジックを実装。これにより、後続の名寄せ工程において、どちらのユーザーIDを主軸に集計しても、確実に重複シグナルをキャッチできる設計としています。

The pipeline extracts 8-digit patterns from notes using Regex and validates them against an integrated master. By implementing bidirectional mapping, it ensures that a single merge request ("User A merge with User B") flags both records, allowing downstream deduplication processes to catch the signal regardless of which ID is queried.

---

## 処理ステップ / Processing Steps

本SQLは以下の処理ステップ（CTE）で構成されています。

### 1. Master Integration
現行システムと旧システムの顧客マスタを統合し、全世代の検証用ユーザーベースを構築。

### 2. Regex Extraction
応対メモから正規表現を用いて統合相手の8桁IDを抽出。

### 3. ID Validation
抽出されたIDの実在確認と、削除・統合済みステータスの検証（ノイズ除去）。

### 4. Bidirectional Record Expansion
依頼元と依頼先、双方の視点でのレコードを生成（UNION ALL）。

### 5. Final Aggregation
ユーザーID単位で集約し、後続クエリでJOIN可能なフラグマスタを生成。

---

# データ構造 / Input Data Structure

このSQLは以下のマスタおよびトランザクションテーブルを前提としています。

### Raw / Source Tables
- `raw_users_current` : 現行システムの顧客マスタ
- `raw_users_legacy` : 旧システムの顧客マスタ
- `raw_crm_notes` : 顧客応対履歴メモ

---

# データ品質チェック / Data Quality Strategy

### ID Existence Validation (ID実在性の検証)
自由記述テキストから数字を抽出する際、誤って電話番号や日付を拾ってしまうリスクがあります。本クエリでは、抽出された数字をそのまま信じるのではなく、必ず統合マスタと `LEFT JOIN` させ、実在するIDと一致した場合のみ `has_valid_target_user_id = 1` を立てることで、データ品質を担保しています。

When extracting numbers from free-text, there's a risk of picking up phone numbers or dates. This query ensures data quality by cross-referencing extracted IDs against the integrated master via a LEFT JOIN, setting a validation flag only when a match is confirmed.

---

# データパイプライン内の位置 / Architecture Position

本SQLはデータパイプラインの **Staging Layer（下ごしらえ層）** に位置します。非構造化データを構造化し、MDM（マスターデータ管理）の核となるシグナルを提供します。

```text
[Raw Tables]
   │
   ├─▶ raw_crm_notes ───────────┐
   ├─▶ raw_users_current / legacy ─┴─▶ 01_stg_customer_note_merge_requests.sql (This SQL)
   │                                   │
   └───────────────────────────────────┼──▶ 02_int_entity_resolution_scoring.sql ──▶ Master Data
```

---

# 運用と保守 / Operations & Maintenance  

### 正規表現パターンの保守 (Regex Pattern Maintenance)  
顧客IDの桁数変更や、プレフィックス（英字等）の追加が発生した場合は、extract_incident_memo CTE内の REGEXP_SUBSTR パターンを更新する必要があります。  
If Customer ID formats change (e.g., changes in digit count or adding prefixes), the REGEXP_SUBSTR pattern in the extract_incident_memo CTE must be updated.  

### 運用ルールの変更監視 (CS Operational Monitoring)  
応対カテゴリ（073 など）の運用ルールや、統合を意味するキーワードの標準化が進んだ場合、WHERE句のフィルタリング条件を調整することで抽出精度をさらに高めることが可能です。  
Monitoring changes in CS operational categories or standardizing "merge" keywords will allow for further refinement of the filtering logic in the WHERE clause.  
