# 概要 / Overview

顧客マスタ内に点在する「同一人物である可能性が高い複数アカウント（重複登録）」を、個人情報の類似度スコアと現場オペレーターの応対履歴を組み合わせて自動判定し、スコアリングする中間テーブルの設計例です。

以下の高度なアルゴリズムを含みます。
- **5段階ゲート・ヒューリスティックマッチング**: 厳格から寛容まで、条件の組み合わせを段階的に評価
- **NULL暴走防止機構 (Null-Poisoning Prevention)**: 未入力項目による誤一致を防ぐ安全装置
- **ハイブリッド・スコアリング**: システム的な一致と、人間による手動統合依頼（応対メモ）を統合
- **安全な配列集約**: 複数ソースから抽出された候補IDを、重複なくクリーンに統合

This project demonstrates a data modeling design for Customer Entity Resolution. It scores highly probable duplicate accounts by combining system-based heuristic matching across 5 gates with human-in-the-loop signals (CRM notes), utilizing advanced array functions to ensure safe and deduplicated candidate lists.

---

# SQL Design Pattern
多段階ゲートマッチングとNULL安全なエンティティ解決
Multi-Gate Matching & Null-Safe Entity Resolution

## 課題 / Problem

同一人物が複数のアカウントを保持している状態（重複登録）は、LTV（顧客生涯価値）分析の歪み、DMの重複送付によるコスト増、初回限定価格の不正利用などのリスクを招きます。
しかし、単純な `GROUP BY` 等による重複排除では、「メールアドレスが未入力（NULL）の顧客同士が全て一致してしまう」といった「NULL暴走」の危険があり、また「結婚による改姓」や「入力ミス」による表記揺れを拾いきれません。

Duplicate accounts degrade LTV analysis accuracy and increase operational costs/risks. Simple deduplication methods often fall victim to "Null-poisoning" where missing values cause thousands of unrelated records to match, and basic logic fails to catch surname changes or minor typos.

## 解決策 / Solution

**【5段階ゲート・マッチング】**
氏名、カナ、郵便番号、電話番号、メールアドレスを組み合わせ、完全一致（レベル5）から部分一致（レベル1）まで、5つの判定関門（Gate）を設置。優先順位の高い関門から順に評価する排他ロジックにより、判定精度の透明性を確保しています。

**【NULL暴走防止の安全装置】**
比較用カラムに `COALESCE(col, 'DUMMY_' || user_id)` を適用。項目が空（NULL）の場合は、そのユーザー自身のIDをプレフィックスとした一意な文字列を動的に生成して埋め込むことで、数学的に「他人との誤一致」を100%排除しています。

**【外部シグナル（CS知見）の統合】**
前工程（`01_stg_customer_note_merge_requests`）で抽出された「人間による統合依頼」がある場合、システムマッチの精度に関わらずスコアを格上げするロジックを実装。システムの限界を人間の知見で補完しています。

---

## 処理ステップ / Processing Steps

本SQLは以下の処理ステップ（CTE）で構成されています。

### 1. Base Extraction & Null Prevention
顧客基本情報の整理と、DUMMY ID埋め込みによるNULL一致の防止。

### 2. Group Aggregation
5段階の各ゲートごとに、ウィンドウ関数（COUNT/LISTAGG）を用いて重複カウントとIDリストを算出。

### 3. Duplicate Detection
各ゲートにおいて「2人以上の重複」があるレコードを特定。

### 4. Exclusive Logic & Array Merge
優先度の高いゲートを正としてフラグを確定。ARRAY関数を用いて関連IDをクリーンにマージ。

### 5. Hybrid Scoring
システムゲートと応対メモシグナルを統合し、1〜5点の最終スコアを付与。

### 6. Final Output Generation
名寄せ候補リストとして、BIツールや運用担当者が利用しやすい形式で出力。

---

# データ構造 / Input Data Structure

このSQLは以下のマスタおよび前工程テーブルを前提としています。

### Source Tables
- `raw_users_current`: 現行システムの顧客マスタ
- `stg_customer_note_merge_requests`: 応対メモから統合シグナルを抽出したStagingテーブル (Query 01)

---

# データ品質チェック / Data Quality Strategy

### Deduplication Reliability (判定精度の可視化)
出力される `match_score`（1〜5）に基づき、以下の基準で運用を制御します。
- **Score 3〜5**: 自動統合または「確定候補」として扱い、分析用マートで即座に名寄せを適用。
- **Score 1〜2**: 「可能性あり」として扱い、運用担当者による目視確認リストへ自動振り分け。

---

# データパイプライン内の位置 / Architecture Position

本SQLはデータパイプラインの **Intermediate Layer（中間処理層）** に位置します。Stagingで収集した断片的なシグナルを統合し、信頼性の高い「名寄せ候補マスタ」を構築します。

```text
[Raw Tables]
   │
   ├─▶ raw_crm_notes ───────────┐
   ├─▶ raw_users_current / legacy ─┴─▶ 01_stg_customer_note_merge_requests.sql
   │                                   │
   └───────────────────────────────────┼──▶ 02_int_entity_resolution_scoring.sql (This SQL)
                                       │    │
                                       ▼    ▼
                                [Master Data Management] ──▶ Analytics Fact Tables
```  

---

# 運用と保守 / Operations & Maintenance  

### スコアリング閾値の調整 (Scoring Threshold Tuning)  
名寄せの判定をより厳格にしたい場合は、SELECT句の 確定_統合フラグ の条件を match_score > 3 に引き上げることで、精度の高い層のみを自動処理の対象に絞り込むことが可能です。  

### 新しい判定要素の追加 (Adding New PII Elements)  
将来的に「生年月日」や「住所（番地まで）」を判定要素に加える場合、agg_matching_groups CTEに新しいゲート条件を定義し、スコア計算ロジックに組み込むことで容易に拡張可能な設計となっています。  
