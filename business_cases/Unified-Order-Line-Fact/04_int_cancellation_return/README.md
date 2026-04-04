# 概要 / Overview

EC受注データから「キャンセル（CNSL）」および「返品（Return）」の複雑なステータスを判定・集約し、後続の分析用ファクトテーブルに結合するためのフラグマスタを生成するSQL設計例です。

以下の処理を含みます。
- ステータスコード、数量、理由メモのキーワードを用いた複合的な状況判定
- 明細レベルから注文レベル、さらに「親子の絆キー」を用いた親注文への状態集約（Rolling up & Status Transfer）
- キャンセルと返品が競合した場合のビジネスルールに基づく優先順位解決
- 保証対象商品の有無と顧客属性（ブラックリスト等）をクロスチェックした全額返金可否の判定

このSQLは、データエンジニアリングにおける「状態遷移のモデリング（State Modeling）」と、複雑なビジネス要件をロジックに落とし込む設計パターンを示す例です。

Example SQL for evaluating and aggregating complex cancellation and return statuses to generate a definitive flag master for the downstream Fact Table. This example demonstrates State Modeling in data engineering, translating nuanced business requirements into robust SQL logic.

---

# SQL Design Pattern
複合条件ステータス判定と親子ステータス転写ロジック
Multi-Condition Status Evaluation & Parent-Child Status Transfer Logic

## 課題 / Problem

ECシステムにおいて、注文が「キャンセル」や「返品」に至るプロセスは単一ではありません。
「出荷前に取り消された」「出荷後未受取になった」「受け取った後に一部返品された」など状態は様々であり、システム上も『ステータスコード』『数量（マイナス）』『理由メモへの自由記述』など、複数の箇所にフラグが分散しています。
さらに、返品データは出荷元データ（親注文）とは別の「枝番付き注文（子注文）」として生成されるため、単純な集約では親注文に返品ステータスを反映させることが困難です。

In e-commerce systems, order cancellations and returns are not straightforward. They span multiple states, and the evidence is scattered across status codes, negative quantities, and free-text notes. Furthermore, return transactions are generated as separate "child" records with a suffix, making it difficult to reflect return statuses onto the original "parent" order through simple aggregation.

## 解決策 / Solution

**【競合解決と状態の確定 (Conflict Resolution)】**
分散しているフラグを明細レベルで一次判定した後、注文単位へ集約。さらに「キャンセル」と「返品」のフラグが同時に立った場合、ビジネスルールに基づいて「返品（Return）」を優先する競合解決ロジックを実装し、状態の矛盾を排除しています。

**【親注文へのステータス転写 (Parent-Child Integration)】**
集約をあえて「2段階」に分けて行います。
1段階目で「注文ID（枝番含む）」ごとにフラグを確定させた後、2段階目で `order_link_key`（親子の絆キー）を用いて再集約します。これにより、別々に存在していた「出荷元（親）」と「返品注文（子）」のレコードが融合し、返品ステータスが正しく親注文にマージ（転写）されます。

---

## 処理ステップ / Processing Steps

本SQLは以下の処理ステップ（CTE）で構成されています。

### 1. Base Evaluation
明細レベルでの一次ステータス判定（数量、コード、キーワード検索）

### 2. Status Classification
複合条件による「出荷前キャンセル」「出荷後返品」の二次判定

### 3. Order-Level Rollup
注文単位（`order_id`）への状態集約（親子はまだ別々の状態）

### 4. Conflict Resolution
ステータス競合時の優先順位に基づく最終フラグ確定

### 5. Customer Validation
顧客マスタとのクロスチェックによる属性（ブラックリスト等）の判定

### 6. Refund Eligibility Finalization
全額返金保証の適用可否判定

### 7. Parent-Child Integration
「親子の絆キー」による共通集約（返品データから出荷元データへのステータス転写）

### 8. Filter Targeted Records
キャンセルまたは返品データへの絞り込み

### 9. Final Output Generation
フラグマスタとしての最終結果出力

---

# データ構造 / Input Data Structure

このSQLは以下のステージングおよびマスタテーブルを前提としています。

### Staging Tables
- `stg_order_info` : 前工程で正規化・クレンジングされた注文マスタ

### Dimension Tables
- `dim_customers` : 顧客マスタ（ブラックリスト、退会ステータス保持）

---

# データ品質チェック / Data Quality Strategy

### Status Conflict Prevention
本クエリの中核は、**「1つの注文に対して、キャンセルと返品のフラグが同時に 1 にならないこと」**を保証する点にあります。このクエリを通すことで、後続のBIツールにおいて「キャンセル率」と「返品率」の分母・分子が重複し、合計が100%を超えるようなレポーティング事故を未然に防ぎます。

The core of this query is ensuring that a single order does not have both cancellation and return flags set to 1 simultaneously. This prevents downstream reporting accidents in BI tools, such as the sum of cancellation and return rates exceeding 100%.

---

# データパイプライン内の位置 / Architecture Position

本SQLはデータパイプラインの **Intermediate Layer（中間処理層）** に位置します。
複雑なステータス判定と親へのステータス転写をここで完結させることで、最終ファクトテーブルの結合ロジックをシンプルに保ちます。

```text
[Raw Tables]
   │
   ├─▶ 01_stg_order_amount.sql 
   ├─▶ 02_stg_order_info.sql ──┐
   │                           ▼
   ├─▶ 03_stg_return_history.sql 
   ├─▶ 04_int_cancellation_return (This SQL: 状態評価・集約) ──┐
   │                                                           ▼
   └──────────────────────────────────────────▶ 05_fct_all_purchases_unified
```  

---

# 運用と保守 / Operations & Maintenance 

### 理由メモ（自由記述）判定の保守 (Free-text Logic Maintenance)

「出荷後未受取」の判定ロジックには、オペレーターが入力する理由メモのキーワード（長期、配送戻り、拒否）を使用しています。将来的にコールセンターの運用ルールが変更され、新しい定型文が導入された場合は、status_evaluation_base CTE内の LIKE 検索パターンを更新する必要があります。  

The evaluation logic for "shipped but unreceived" orders relies on keyword matching (長期, 配送戻り, 拒否) in free-text notes entered by operators. If call center operational rules change and new standard phrases are introduced, the LIKE search patterns in the status_evaluation_base CTE must be updated.  

### ブラックリスト顧客の動的評価 (Dynamic Blacklist Evaluation)

全額返金判定において、顧客のブラックリスト状態をチェックしていますが、これは「注文時点」ではなく「クエリ実行時点（現在）」の最新状態を正として評価しています。これにより、事後的にブラックリスト入りした悪質なユーザーを分析から即座に除外（または特定）することが可能です。  

In the refund eligibility check, the customer's blacklist status is evaluated based on the "current" state rather than the "time of order." This allows data teams to dynamically and retroactively exclude (or identify) malicious users who were blacklisted after their purchase.  
