# 概要 / Overview

EC受注データにおける金額の明細案分と整合性検証を行うSQLの設計例です。

以下の処理を含みます。
- エラーログに基づく異常データの除外
- 累積和を用いた割引額の明細案分
- ECシステム値と手動計算値の動的比較・採用
- 1円以上の金額不整合の自動検知

このSQLは、複雑なトランザクションデータにおける
「1円のズレも許さない」データエンジニアリングの設計パターンと、
データ品質監視（Data Observability）の思考プロセスを示す例です。

Example SQL for prorating order amounts and validating financial integrity, including:
- Exclusion of anomalous data based on error logs
- Discount proration using cumulative running sums
- Dynamic comparison and selection between system and recalculated values
- Automatic detection of financial discrepancies over 1 yen

This example demonstrates data engineering design patterns for ensuring 
absolute financial accuracy and the structured thinking behind Data Observability 
in complex transactional datasets.

---

# SQL Design Pattern
受注金額における累積案分と動的整合性検証ロジック
Order Amount Cumulative Proration & Dynamic Validation Logic

## 課題 / Problem

注文全体にかかる割引（クーポン、ポイント等）を複数の明細に按分する際、
単純な割り算では端数処理（切り捨て等）の積み重ねにより、
合計決済額に対して数円のズレ（Rounding Error）が発生します。
また、ECシステムの仕様やアップデートにより、
システムが保持する決済額と手動計算額に不一致が生じることがあります。

When prorating order-level discounts across multiple line items, 
simple division causes rounding errors, leading to a mismatch with the total payment. 
Additionally, system specifications or updates can cause discrepancies 
between system-recorded payments and manually recalculated values.

## 解決策 / Solution

Window関数の累計和（Running Sum）を用いた
**累積差分方式（Cumulative Difference Allocation）**を採用し、端数ズレを完全に排除しています。
さらに、手動計算値とシステム値の誤差を算出し、
実際の最終決済額に最も近い値を自動採用する
**動的評価ロジック（Dynamic Evaluation Logic）**を実装しています。

This SQL uses a running sum allocation strategy to completely eliminate rounding errors. 
Furthermore, it implements a dynamic evaluation logic that compares manually 
recalculated values with system values, automatically selecting the one 
closest to the actual final payment (Single Source of Truth).

## 数式 / Formula

**【累積配分額 / Cumulative Allocated Discount】**
`D_cumulative_i = floor( D_total × ( cumulative_amount_i / total_amount ) )`

**【明細配分額 / Item-level Discount】**
`D_item_i = D_cumulative_i - D_cumulative_{i-1}`

*(金額の高い順にソートして累積計算を行うことで、端数誤差を自動的に高額商品へ吸収させます)*
*(By sorting in descending order of price before accumulating, rounding differences are automatically absorbed by higher-priced items.)*

---

# データ構造 / Input Data Structure

このSQLは以下のECトランザクションおよびマスタテーブルを前提としています。
The query assumes the following transactional and dimension tables.

### `raw_order_items` (注文商品明細テーブル)
| column | description |
| :--- | :--- |
| `order_id` | 注文ID |
| `line_no` | 注文明細番号 |
| `product_id` | 商品ID |
| `quantity` | 注文数量 |
| `line_subtotal_incl_tax` | 税込明細金額 |
| `line_tax_amount` | 明細税額 |

### `raw_orders` (注文ヘッダテーブル)
| column | description |
| :--- | :--- |
| `user_id` | 顧客ID |
| `order_id` | 注文ID |
| `subtotal_amount` | 注文小計 |
| `total_payment_amount`| 最終決済金額 |

### `dim_products` (商品マスタ)
| column | description |
| :--- | :--- |
| `product_id` | 商品ID |
| `product_name` | 正規化された商品名 |
| `tax_rate` | 適用税率 (例: 100, 108, 110) |

### `source_error_log` (データ品質エラーログ)
| column | description |
| :--- | :--- |
| `order_id` | 注文ID |
| `error_reason` | エラー理由 |
| `error_flag` | 除外フラグ |

---

# データ品質チェック / Data Quality Strategy

このSQLはトランザクションデータに対して複数のデータ品質チェックを実装しています。
This query implements several data quality validation checks.

### 1. Master Consistency Check
商品マスタに存在しない商品を検出 / Detects products missing from the product master.

### 2. Order Subtotal Validation
明細小計と注文小計の整合性確認 / Validates consistency between line subtotals and the order header subtotal.

### 3. Payment Integrity Check
再計算した注文合計と最終決済額の差分検証 / Verifies the difference between the recalculated order total and the system's final payment.

これらの結果は `error_detail` カラムとして出力され、データ品質監視（Data Observability）に利用できます。
These results are output in the `error_detail` column and can be utilized for Data Observability monitoring.

---

# データパイプライン内の位置 / Architecture Position

このSQLはデータパイプラインの **Staging Layer (下ごしらえ層)** に位置します。
The query is designed as part of the **Staging Layer** in the analytics pipeline.

```text
[Raw Tables]
   │
   ├─▶ 01_stg_order_amount.sql (This SQL) ──┐
   ├─▶ 02_stg_order_info.sql                │
   │                                        ▼
   ├─▶ 03_stg_return_history.sql      [Intermediate]
   ├─▶ 04_int_cancellation_return ───────▶ 05_fct_all_purchases_unified
```
このステージでは以下を目的としています。
The primary objectives of this stage are:

- 金額整合性の確保 / Ensuring financial integrity 
- 異常データの検知 / Detecting anomalous data
- 明細単位データの正規化 / Normalizing line-item level data

---

# 運用と保守 / Operations & Maintenance

### データ品質監視 / Data Quality Monitoring
本クエリは単なるデータ変換ではなく、**「データ品質ゲート」**としての役割を果たします。error_detail が空でないレコードを監視・アラート通知することで、上流システムの不具合やマスタ登録漏れを早期に検知することが可能です。

This query acts not just as a transformation step, but as a Data Quality Gate. By monitoring records where error_detail is not empty, data teams can proactively detect upstream system bugs or missing master data entries.

### 拡張性 / Extensibility
新しい割引タイプ（例：期間限定キャンペーン等）が追加された場合でも、order_header CTE内の total_discount_incl_points の計算式を更新するだけで、明細への案分ロジックを変更することなく対応できる疎結合（Loosely Coupled）な設計になっています。

The design is loosely coupled; if new discount types are introduced, updating the calculation in the order_header CTE is sufficient. The core proration logic remains untouched, ensuring high maintainability.
