# 概要 / Overview

サブスクリプション特典（デジタルギフト）施策の「起点」となる、特典対象商品ラインの初回購入（F1）レコードを精緻に抽出し、候補者リストを作成するSQLの設計例です。

以下の処理を含みます。
- 特典対象商品ラインの新規購入コードによる明細抽出
- ユーザー単位の手動例外（削除・特例追加）の反映
- 「商品名表記」「DM履歴」「同梱物印字」という3つの独立したファクトによる、頑健な対象者判定

このSQLは、キャンペーンコード1本に依存せず複数の証拠を組み合わせて対象者を確定させる、堅牢なデータエンジニアリング設計を示す例です。

Example SQL for precisely extracting the "anchor" first purchase (F1) records that trigger a subscription milestone gift campaign. This example demonstrates a robust eligibility-confirmation design that cross-validates multiple independent facts rather than relying on a single campaign code flag.

---

## データパイプライン内の位置 / Architecture Position

本ケースは [Advanced_marketing_foundation](../../Advanced_marketing_foundation/) の次工程として、`stg_all_purchases_base` を土台に構築されています。本クエリはケース全体の起点（Step 01）です。

This case builds on top of `stg_all_purchases_base` as the next step after [Advanced_marketing_foundation](../../Advanced_marketing_foundation/). This query is the entry point (Step 01) of the case.

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern
複数ファクトによる頑健な対象者判定と責務分離された例外対応
Multi-Fact Eligibility Confirmation & Separated Exception Handling

### 課題 / Problem

特典付与の判定を単一のキャンペーンコードフラグだけに依存すると、過去の商品名表記変更などの歴史的経緯によって取り逃し（False Negative）が発生します。また、手動運用CSVによる「ユーザー単位の削除」と「注文単位の削除」を同一クエリで同時に処理すると、データ粒度の違いによる予期せぬ増殖・消失バグのリスクがあります。

Relying on a single campaign-code flag for eligibility risks false negatives caused by historical inconsistencies (e.g., product naming changes). Additionally, processing "user-level" and "order-level" manual deletions in the same query risks data-grain bugs such as unintended row amplification or loss.

### 解決策 / Solution

**【複数ファクトによる裏付け】**
「商品名にギフト表記があるか」「過去のDM送付履歴があるか」「同梱物にギフト対象の印字があるか」の3つの独立したファクトのいずれかを満たせば対象者と確定する、冗長性のある判定ロジックを採用しています。

**【責務の分離（2段階構成）】**
手動例外対応を「ユーザー単位」（本クエリ）と「注文単位」（次工程）に明確に分割。異なる粒度の処理を1つのクエリに混在させないことで、データ増殖・消失バグのリスクを排除しています。

By confirming eligibility through any of three independent facts, and by splitting manual exception handling into a two-stage architecture (user-level here, order-level in the next query), this design eliminates both false-negative risk and data-grain bugs.

---

## 処理ステップ / Processing Steps

本SQLは以下の処理ステップ（CTE）で構成されています。

### 1. Anchor Purchase Extraction
特典対象商品ラインの新規購入コードによる明細抽出。

### 2. User-Level Manual Exception Handling
注文単位への集約と、手動CSVによるユーザー単位の削除・特例追加の反映。

### 3. Multi-Fact Eligibility Evaluation
DM履歴・同梱物印字マスタとの結合による対象者ファクトの付与と最終判定。

### 4. Final Output Generation
状態カテゴリの付与と最終データ生成。

---

## データ構造 / Input Data Structure

### Staging Tables
- `raw_gift_eligible_purchases` : 特典対象商品ラインの購入明細抽出（GUIパラメータ層で事前絞込済み）

### Master / Reference Tables
- `map_gift_manual_exceptions` : 手動対応リスト（ユーザー単位・注文単位の削除／特例追加）
- `raw_dm_history` : 過去のDM送付履歴
- `raw_catalog_gift_markers` : 同梱物（明細書印字）データ

---

## データ品質チェック / Data Quality Strategy

### Redundant Fact Validation
対象者判定を1つのフラグに依存させず、3つの独立したファクトのOR条件で確定させることで、歴史的なデータ不整合による取り逃しリスクを低減しています。

By requiring eligibility to be corroborated by any of three independent facts (not a single flag), the risk of missed eligible customers due to historical data inconsistencies is minimized.

---

## 運用と保守 / Operations & Maintenance

### 手動対応リストの運用 (Manual Exception List)
`map_gift_manual_exceptions` は、システムで自動判定できない「手動での除外」や「特例での追加」を制御する重要なマスタです。イレギュラーが発生した場合は、このCSVを更新してください。本クエリでは `exception_type IN ('DELETE_BY_USER', 'ADD_IRREGULAR')` のレコードのみを評価し、注文単位の削除（`DELETE_BY_ORDER` 等）は次工程（02）で処理します。

### アーキテクチャ分割の維持 (Maintaining the Split Architecture)
将来的にクエリを統合したくなる場面があっても、ユーザー単位と注文単位の例外処理を同一クエリに戻すことは避けてください。データ粒度の違いによるバグ再発のリスクがあります。
