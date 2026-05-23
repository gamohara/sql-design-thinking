# 概要 / Overview

新たに導入した「顧客獲得日を起点とした純新規判定ロジック（Immutable Pure-New Evaluation）」の精度と安全性を、データパイプライン内で継続的に監視（Audit）するためのテスト・監査用クエリ設計例です。

以下の処理を含みます。
- 「全履歴ベース」と「獲得日ベース」の判定結果のズレの可視化
- データの健康状態（Health Status）の5段階ラベリング
- ロジックの網目から漏れた「潜在的バグ（False Negative）」の自動検知

このSQLは、データエンジニアリングにおいて極めて重要となる「データに対するテスト駆動開発（Data Testing）」と「パイプラインの品質監視（Data Observability）」のベストプラクティスを示す例です。

Example SQL for auditing and verifying the accuracy of the newly introduced "Immutable Pure-New Evaluation" logic within the data pipeline. This example showcases best practices in Data Testing and Data Observability, including the visualization of logic efficacy, health status labeling, and automatic detection of potential data leaks (False Negatives).

---

# SQL Design Pattern
パイプライン品質監査と健康状態ラベリングロジック
Pipeline Quality Audit & Health Status Labeling Logic

## 課題 / Problem

高度なヒューリスティック推測やテキストマイニング（オペレーターのコメント欄からのキーワード抽出）に依存するデータ処理ロジックは、常に「抽出漏れ（False Negative）」のリスクを孕んでいます。
例えば、顧客統合（名寄せ）を防ぐロジックを実装しても、オペレーターが今までと違う書き方（例：「名寄せ処理済」ではなく「アカウント合算済」など）をした場合、システムは統合を検知できず、再びKPIの過去改変バグが発生してしまいます。これを日々のレポートの数字が狂うまで気づけないのは、データ基盤として致命的です。

Data processing logic relying on heuristic estimation or text mining (e.g., keyword extraction from operator notes) is inherently prone to False Negatives. If operator behaviors change and edge cases slip through, the pipeline silently corrupts downstream KPIs. Failing to detect these leaks until business reports break is fatal to data infrastructure reliability.

## 解決策 / Solution

**【データ監査層 (Audit Layer) の新設】**
データマートを作成するメインのパイプラインとは別に、ロジックの「健康状態」を監視する専用のテストクエリを用意します。
「統合フラグが立っていない」にもかかわらず、「全履歴の初回購入」と「獲得日の初回購入」が一致しないユーザーは、数学的に矛盾（＝フラグ漏れの疑い）が生じています。この矛盾を検知してラベリング（パターン④）し、構成比（%）を算出することで、異常な状態を早期に検知する仕組みを構築しました。

By isolating an Audit Layer, the pipeline proactively monitors its own health. Users who exhibit a mathematical contradiction—conflicting "first purchase" statuses despite lacking a merge flag—are labeled as potential leaks (Pattern ④). Calculating the percentage distribution of these cohorts establishes an early warning system.

---

## 処理ステップ / Processing Steps

本SQLは以下の処理ステップ（CTE）で構成されています。

### 1. Base Extraction
前工程のマスタから、判定用フラグと統合フラグの抽出

### 2. Pattern Labeling
フラグの整合性チェックに基づく健康状態のラベリング（パターン分類）
- **パターン①【SUCCESS】**: 狙い通りに過去データ混入から純新規を救済できた層
- **パターン④【ALERT!!】**: フラグ漏れの疑いがある矛盾層

### 3. Final Output & SLI Generation
判定パターンごとの対象ユーザー数および構成比（%）の集計

---

# データパイプライン内の位置 / Architecture Position

本SQLはデータパイプラインの **Audit Layer（監査層）** に位置し、`int_pure_new_classification_master` の実行直後に品質テストとして動作します。

```text
[Pipeline]
   │
   ├─▶ 04_int_pure_new_classification.sql ──▶ Fact Tables (Main Analytics)
   │
   └─▶ 05_audit_pure_new_logic.sql (This SQL: Pipeline Monitoring) ──▶ Alerting System
```  

---

# 運用と保守 / Operations & Maintenance  

### アラートの閾値と対応アクション (Alert Thresholds and Next Actions)  
保守担当者は、本クエリの出力結果における パターン「④【ALERT!!】」の構成比(%) を常に監視してください。  

- 正常状態: 1%未満 であれば、許容される運用ノイズとして無視できます。  

- アラート状態: 5% などを超えた場合、テキスト抽出の網目から漏れた名寄せ処理が大量発生しています。速やかに is_cus_merged フラグを生成している上流工程のSQLを確認し、LIKE演算子の検索キーワード（例：『名寄せ』や『合算』など）を追加するメンテナンスを実施してください。  

Monitor the percentage of "Pattern ④ [ALERT!!]". If it exceeds 5%, it strongly indicates a failure in upstream text mining logic. Data teams must immediately update the upstream SQL keyword extraction conditions (e.g., adding new LIKE patterns for operator notes) to restore data integrity.
