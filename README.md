# SQL Design Patterns for Business Data Analysis

## 概要 / Overview

このリポジトリでは、ビジネスデータ分析およびデータ基盤構築で実際に使用される  
**SQL設計パターンとデータモデリングの考え方**をまとめています。

単なるSQLの書き方ではなく、以下のテーマを中心に整理しています。

- 複雑なビジネスロジックの整理
- データパイプライン設計
- データ品質管理（Data Quality / Observability）
- 再利用可能なSQL設計パターン

掲載しているSQLは、実務で使用していたロジックをベースに  
企業情報や機密情報を除去した**抽象化サンプル**として公開しています。

---

This repository contains **SQL design patterns and data modeling techniques**  
used in real-world business data analysis and data engineering.

The focus is not just writing SQL queries, but designing **reliable analytical datasets through structured query design**.

Topics covered include:

- SQL design for complex business logic
- Data pipeline structuring
- Window function based calculations
- Data modeling with explicit data grain
- Data quality monitoring and observability

All examples are abstracted from real-world SQL used in production environments,  
with company-specific information removed.

---

# SQL Design Philosophy

このリポジトリでは、SQLを以下の順序で設計することを重視しています。

1. **Business Purpose**  
   何のためのデータか（分析目的）

2. **Data Grain**  
   1行が何を表すか（例：`order_id × line_no`）

3. **Primary Key**  
   データの一意性の定義

4. **Table Relationships**  
   テーブル間の結合関係

5. **Calculation Logic**  
   Window関数や集計ロジック

6. **Data Quality Checks**  
   金額整合性や異常検知

単なるSQLクエリではなく  
**分析用データセットを設計するSQL**を重視しています。

---

When designing SQL, the following structured approach is used:

1. Business Purpose  
2. Data Grain  
3. Primary Key  
4. Table Relationships  
5. Calculation Logic  
6. Data Quality Checks  

The goal is not only writing SQL, but **designing reliable analytical datasets**.

---

# Example Topics Covered

このリポジトリでは、以下のような実務に近いSQL設計テーマを扱っています。

- 割引・ポイントの明細按分ロジック
- レガシーデータのヒューリスティック補正
- 返品注文と元注文のリンクキー生成
- Window関数による累積計算
- データ品質監視（Data Observability）
- 注文データの統合ファクトテーブル構築

These examples demonstrate SQL patterns used for:

- Financial amount allocation
- Heuristic classification for legacy datasets
- Parent–child order linking
- Running total calculations using window functions
- Data quality monitoring
- Building analytical fact tables

---

# Overall Architecture / 全体アーキテクチャ

`business_cases` 配下の5つのケースは、それぞれ独立したサンプルであると同時に、  
実際には**1つの大きなデータ基盤（受注データ統合 → マーケティングKPI基盤 → 顧客特典配布）を構成するモジュール群**として設計されています。

The five cases under `business_cases` can be read independently, but they are also designed as  
**modules of a single, larger data platform** (order data integration → marketing KPI foundation → customer reward fulfillment).

```mermaid
graph TD
    subsc[("📁 subscription<br/>定期購入 次回配送金額・ポイント配分")]:::case
    mdm[("📁 customer_entity_resolution_mdm<br/>顧客名寄せ・重複検知")]:::case

    subsc -->|dim_subscription_info| uolf
    mdm -->|dim_customers| uolf

    uolf["📁 Unified-Order-Line-Fact<br/>受注・返品・キャンセルの統合ファクト"]:::case
    uolf -->|"fct_all_purchases_unified ≒ stg_all_purchases_base"| amf

    mdm -->|merged customer master| amf

    amf["📁 Advanced_marketing_foundation<br/>純新規判定・マーケティングKPI基盤"]:::case
    amf -->|"stg_all_purchases_base（購入・定期実績の土台）"| smgf

    smgf["📁 subscription_milestone_gift_fulfillment<br/>定期購入マイルストーン特典配布システム"]:::case

    classDef case fill:#e8f5e9,stroke:#388e3c,stroke-width:2px;
```

- **subscription**: 定期購入の金額・ポイント配分ロジック → `Unified-Order-Line-Fact` の定期情報として参照
- **customer_entity_resolution_mdm**: 顧客の名寄せ・重複検知 → `Unified-Order-Line-Fact` のブラックリスト判定、および `Advanced_marketing_foundation` の顧客統合に耐えうる純新規判定の土台
- **Unified-Order-Line-Fact**: 受注明細単位での金額・ステータスの統合ファクトテーブル構築（出力が次工程の入力になる）
- **Advanced_marketing_foundation**: 上記すべてを土台に、マーケティングKPI（純新規・LTV等）を算出するレイヤー
- **subscription_milestone_gift_fulfillment**: 定期購入が特定の累計本数に到達した顧客へデジタルギフトを付与する、20クエリ構成のCRM/マーケティング自動化パイプライン（最終レイヤー）

各ケースのREADMEには、この全体像における位置づけ（Upstream / Downstream）を明記しています。

---

# 設計判断の背景 / Design Decision Background

個々のクエリレベルの設計パターン（各ケースの `SQL Design Pattern` セクションを参照）とは別に、  
リポジトリ全体の構成・ドキュメント方針として下した、横断的な設計判断を記録します。

Beyond the per-query design patterns documented in each case's own `SQL Design Pattern` section,  
this section records the cross-cutting decisions made about how the repository itself is structured and documented.

### 1. ケースを「独立サンプル集」ではなく「1つの基盤」として明示する

**判断**: 5つの `business_cases` を、互いに無関係な独立サンプルとして並べるのではなく、上記のMermaid図とケース間のUpstream/Downstream相互参照によって、1つのデータ基盤を構成するモジュール群であることを明示した。

**理由**: 各ケースの中には、他ケースの出力テーブル（例: `stg_all_purchases_base`、`dim_customers`）を「所与の入力」として参照している箇所がある。この依存関係を明示しないと、読者はそのテーブルがどこから来るのか分からず、サンプルとして理解しづらくなる。

**トレードオフ**: 一方で、ケース同士が密結合しているかのような誤解を招くリスクがある。そのため、各ケースのREADMEには「本ケースは自己完結的に読める」旨と、上流依存はあくまで参照であることを併記している。

**Decision**: Rather than presenting the 5 business cases as unrelated independent samples, this repository explicitly documents them as modules of one larger data platform, via the Mermaid diagram above and Upstream/Downstream cross-references in each case's README.
**Rationale**: Several cases reference another case's output table (e.g. `stg_all_purchases_base`, `dim_customers`) as a given input; without making this explicit, readers cannot tell where those tables come from.
**Tradeoff**: This risks implying the cases must always be used together. Each case's README therefore also states that it can be read as a self-contained example, with the upstream link being informational rather than a hard dependency.

### 2. 日本語エイリアスのみのカラムに、下流参照用の英語名を新たに付与する

**判断**: 上流クエリの最終SELECTが日本語カラム名（エイリアス）のみを出力し、CTE内部にも対応する英語名が存在しない場合、下流クエリからの参照のために、その日本語カラムの意味に基づいた英語のsnake_case名を新たに考案し、あたかも元から存在した内部識別子であるかのように使用した。

**理由**: 本リポジトリの既存の慣習（例: `05_fct_all_purchases_unified` → `Advanced_marketing_foundation` 間の参照）が、日本語エイリアス化前の英語名でテーブル間参照を行うスタイルを採用しているため、これに合わせることで下流クエリ群の可読性・一貫性を保った。

**トレードオフ**: この英語名は元のソースコードに文字として存在するものではなく、あくまで推測による命名である。命名がカラムの実際の意味とズレるリスクがあり、読者はこれが「原文にある名前」ではなく「本リポジトリでの一般化のために考案した名前」であることを踏まえて読む必要がある。

**Decision**: When an upstream query's final SELECT exposes only a Japanese-language column alias — with no corresponding English name anywhere in its CTEs — this repository invents an English snake_case name based on the column's meaning, for use by downstream queries, treating it as if it were the original internal identifier.
**Rationale**: This matches the repository's existing convention (e.g. references from `Advanced_marketing_foundation` to `05_fct_all_purchases_unified`) of cross-referencing tables using their pre-alias English names, keeping downstream queries consistent and readable.
**Tradeoff**: The invented name is not literally present in the original source — it is an inference. It could drift from the column's true intended meaning, so readers should treat it as a naming choice made for this repository's abstraction, not a literal transcription of the original system.

---

# Repository Structure
```text
📁 sql-design-thinking
 ├── 📄 README.md
 └── 📁 business_cases
 │    └── 📁 subscription
 │    │
 │    └── 📁 customer_entity_resolution_mdm
 │    │
 │    └── 📁 unified_order_line_fact
 │    │
 │    └── 📁 advanced_marketing_foundation
 │    │
 │    └── 📁 subscription_milestone_gift_fulfillment
 │
 └── 📁 advanced_sql_recipes
```

Each directory represents a **business data modeling case**.

Typical structure:

query_name/
SQL implementation
README explaining business logic
Data modeling explanation
Data quality checks

---

# Target Audience

このリポジトリは主に以下のエンジニア向けに作成しています。

- BIエンジニア  
- データアナリスト  
- Analytics Engineer  
- データエンジニア  

特に、

**ビジネスデータを分析可能なデータセットへ変換するSQL設計**

に関心のある方を対象としています。

---

# Notes

本リポジトリのSQLは教育・共有目的で公開しています。

- 実際の企業データは含まれていません
- テーブル名やロジックは抽象化されています
- 特定の企業やサービスとは関係ありません

The SQL examples are published for educational purposes.  
No real company data is included.
