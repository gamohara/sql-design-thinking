# 概要 / Overview

ECデータパイプラインの最終成果物となる**「全購入情報統合ファクトテーブル（Unified All Purchases Fact Table）」**を生成するSQL設計例です。

以下の処理を含みます。
- 前工程で精製された各データマート（金額、属性、ステータス）の統合
- 分析のノイズとなる「返品（マイナス売上）明細」の除外と、親注文への「返品フラグ」の転写
- 複数回返品における理由メモの重複排除（Deduplication）と文字列集約（String Aggregation）
- BIツールでの分析要件に合わせたコード値の日本語ラベル化（Dimension Formatting）

このSQLは、複雑なトランザクションデータ群を、ビジネスサイドが直感的に分析できる「1つの完璧なファクトテーブル（Single Source of Truth）」へと統合するデータモデリングの集大成を示しています。

Example SQL for generating the final deliverable of the EC data pipeline: the Unified All Purchases Fact Table. This example demonstrates the culmination of data modeling, integrating complex transaction datasets into a single, perfect Fact Table (Single Source of Truth) that business teams can intuitively analyze.

---

# SQL Design Pattern
スター・スキーマ統合と安全な非正規化ロジック
Star Schema Integration & Safe Denormalization Logic

## 課題 / Problem

高度な分析基盤において、金額計算や状態判定のロジックを1つの巨大なSQL（スパゲッティコード）に詰め込むと、保守性や計算パフォーマンスが壊滅的に悪化します。
しかし、BIツールを使うビジネスユーザーにとっては、情報が複数テーブルに分散している（正規化されすぎている）状態は非常に分析しづらく、「売上金額と返品フラグが一緒に入った、シンプルで巨大な1つのテーブル」が求められます。
また、1つの注文に対する複数回の返品（-001, -002）の自由記述メモを結合する際、単純なJOINでは元注文のレコードが増幅（JOIN爆発）し、売上金額が2倍3倍に膨れ上がる大事故を引き起こします。

## 解決策 / Solution

**【安全な非正規化 (Safe Denormalization)】**
上流工程で機能ごとに独立・隔離（モジュール化）して作成した「金額」「属性」「ステータス」の各中間テーブルを、この最終ステージで一気に結合（非正規化）します。機能が分離されているため、この統合クエリ自体は極めてシンプルで見通しが良くなります。

**【JOIN爆発の防止とLISTAGGの活用】**
返品理由の結合において、サブクエリで明細ごとの重複を排除（Deduplication）した後、`LISTAGG` 関数（Snowflake互換）を用いて1行の文字列に集約（Aggregation）しています。これにより、結合対象の粒度（Grain）が `order_link_key`（1注文1行）に完全に固定され、JOIN爆発による売上の二重計上リスクを数学的に排除しています。

---

## 処理ステップ / Processing Steps

本SQLは以下の処理ステップで構成されています。

### 1. Base Order Info Integration
注文属性情報の取得（マイナス売上レコードの除外）

### 2. Financial Data Integration
累積案分で計算された正確な金額情報の結合

### 3. Status Flag Integration
親子の絆キー（Order Link Key）を用いたキャンセル・返品フラグの親注文への転写

### 4. Return Reason Aggregation
返品理由メモのユニーク化と文字列結合（JOIN爆発防止ロジック）

### 5. Dimension Formatting & Final Output
BIツール向けコード変換（支払方法、受注経路など）および最終出力

---

# データ構造 / Input Data Structure

このSQLは、データパイプラインの上流で作成された以下の全てのStaging / Intermediateテーブルを統合します。

### Upstream Tables (前工程の出力テーブル)
- `stg_order_info` : 注文属性クレンジングマスタ (Query 2)
- `stg_order_amount` : 金額案分・検証マスタ (Query 1)
- `int_cancellation_return` : キャンセル・返品集約マスタ (Query 4)
- `stg_return_history` : 返品保管マスタ (Query 3)

### Dimension Tables (マスタ・リスト)
- `dim_payment_methods` : 支払方法区分マスタ
- `list_no_shipping_orders` : 実発送なし除外リスト

---

# データ品質チェック / Data Quality Strategy

### Deduplication Guarantee (重複排除の保証)
本クエリの中核は、左側のベーステーブル（`base_order_table`）の行数（Row Count）と売上合計額（SUM of Sales）が、`LEFT JOIN` を繰り返した後でも **「絶対に増幅・変化しないこと」** を保証する点にあります。サブクエリによるグループ化と集約関数を徹底することで、ファクトテーブルの最も重要な「データ粒度の純度」を守り抜いています。

---

# データパイプライン内の位置 / Architecture Position

本SQLはデータパイプラインの **Final Layer（最終出力層）** に位置し、ビジネス側が直接参照するデータマート（Data Mart）として機能します。

```text
[Raw Tables]
   │
   ├─▶ 01_stg_order_amount.sql ───────┐
   ├─▶ 02_stg_order_info.sql ─────────┼──────┐
   │                                  ▼      │
   ├─▶ 03_stg_return_history.sql ─────┼────┐ │
   ├─▶ 04_int_cancellation_return ────┘    │ │
   │                                       ▼ ▼
   └────────────────────────────────▶ 05_fct_all_purchases_unified (This SQL: 最終ファクト)
```

---

# 運用と保守 / Operations & Maintenance 

### BIツール連携の最適化 (BI Tool Integration)

このテーブルの出力結果は、BIツール（Tableau, Looker, b-dash等）に直接接続されることを前提としています。カラム名が日本語にエイリアスされているため、ビジネスユーザーは事前のメタデータ定義なしで即座にピボットテーブル等の分析を開始可能です。  

The output of this table is designed for direct connection to BI tools. Because column names are aliased in business-friendly Japanese, end-users can immediately begin drag-and-drop analysis without requiring preliminary metadata definitions in the BI semantic layer.  

### 機能の疎結合による保守性の向上 (Maintainability via Loose Coupling)

将来、「金額案分のルール」や「定期推測のロジック」に変更があった場合でも、この最終統合クエリ（fct_all_purchases_unified）を修正する必要は一切ありません。変更箇所は該当する上流の Staging クエリ内に限定されるため、大規模なデータ基盤であっても安全かつ迅速なアップデートが可能です。  

If rules for "amount proration" or "subscription heuristic inference" change in the future, this final integration query requires absolutely zero modifications. Changes are localized to the respective upstream Staging queries, enabling safe and rapid updates even in large-scale data infrastructures.  
