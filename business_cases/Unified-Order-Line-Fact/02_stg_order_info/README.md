# 概要 / Overview

EC受注データ（商品明細およびヘッダ）に対するデータクレンジング、定期判定の補正、および注文IDの正規化を行うSQLの設計例です。

以下の処理を含みます。
- マスタ補正辞書を用いたプロモコードと商品情報のクレンジング
- 結合の増幅（Redundant Join）を防ぐための基本テーブルの早期統合（Early Materialization）
- 歴史的な旧ID体系（頭文字C）に起因するカテゴリ欠損データのヒューリスティック推測（Heuristic Classification）
- 返品トランザクションと元注文を紐付ける「親子の絆キー（Order Link Key）」の正規表現生成

このSQLは、レガシーシステムの「汚いデータ」を分析可能な「クリーンデータ」へと変換するための、泥臭くも極めて堅牢なデータエンジニアリングの手法を示しています。

Example SQL for cleansing order data, heuristically classifying subscription items, and normalizing order IDs. This example demonstrates highly robust data engineering techniques to transform "dirty data" from legacy systems into clean, analyzable datasets.

---

# SQL Design Pattern
旧ID体系のヒューリスティック分類と親子の絆キー生成ロジック
Legacy ID Heuristic Classification & Order Link Key Generation Logic

## 課題 / Problem

長期稼働しているECシステムでは、過去の仕様変更によりID体系が混在（例：頭文字がCの13桁と、Aの17桁など）し、古いデータでは商品カテゴリ情報（定期同梱品か単品か）が欠損している場合があります。
また、返品データは元注文のID末尾に枝番（`-001`等）が付与されて別レコードとして生成されるため、単純なJOINでは元注文とのLTV（顧客生涯価値）や返品率の分析が困難です。

In long-running EC systems, historical specification changes often lead to mixed ID formats and missing category information for older data. Furthermore, return transactions are generated as separate records with a suffix (e.g., `-001`) appended to the original order ID, making it difficult to join them for LTV or return rate analysis.

## 解決策 / Solution

**【定期判定のヒューリスティック補正】**
マスタやDB上の確固たる事実（SYSTEM_FACT）だけでなく、注文内の「RG品（定期商品）の行数」などの状況証拠を元に定期フラグを推測するロジックを実装しています。
ヒューリスティック推測は、誤分類（False Positive）を最小化するために複数条件を段階的に評価する設計としています。
また、その推測の**信頼度（Reliability）**をスコアリングして出力することで、データ利用者に品質の透明性を提供します。

The heuristic classification is designed with multi-step evaluation to minimize false positives, ensuring reliable subscription inference.

**【親子の絆キー（Order Link Key）の生成】**
正規表現（`.*-0[0-9]{2}$`）を用いて、「本当に返品フラグである枝番」のみを正確に削り落とし、元注文と返品データを1対1（または1対多）で完璧に紐付けるためのユニバーサルな結合キーを生成します。

This regex-based key enables accurate linking between original orders and return transactions.

## 処理ステップ / Processing Steps

本SQLは以下の処理ステップで構成されています。

### 1. Error Data Exclusion
エラーログに基づく異常データ除外

### 2. Subscription Base Preparation
定期購入情報の重複排除

### 3. Order Item Cleansing
商品マスタを用いた商品明細補正

### 4. Order Header Cleansing
プロモコード補正

### 5. Base Table Integration
明細とヘッダの早期統合

### 6. Heuristic Subscription Classification
定期商品の推測分類

### 7. Order ID Normalization
注文リンクキー生成

### 8. Final Output Generation
最終データ生成

---

# データ構造 / Input Data Structure

### Transaction Tables
- `raw_order_items` : 注文商品明細
- `raw_orders` : 注文ヘッダ

### Master & Correction Tables
- `dim_products` : 補正済み商品情報マスタ
- `dim_subscription_info` : 定期購入情報テーブル
- `map_promo_code_correction` : プロモコード手動補正辞書
- `map_subsc_heuristic_correction` : 定期区分推測ロジック適用リスト（旧ID形式約7,000件）

---

# データ品質チェック / Data Quality Strategy

### Data Observability (品質モニタリング指標)
本クエリでは、単にデータを補正するだけでなく、**「補正の由来（信頼度）」**を以下のカラムとして出力します。

| column | description |
| :--- | :--- |
| `classification_reliability` | 定期判定の由来（`SYSTEM_FACT`, `MANUAL_HEURISTIC` など） |
| `manual_heuristic_ratio_pct` | 全データに対する手動推測（MANUAL_HEURISTIC）の割合(%) |

**【運用アクション】**
`manual_heuristic_ratio_pct` が想定値（数%）を大きく超えて急増した場合、システム側で新たなカテゴリ欠損バグが発生している可能性が高いため、データチームが即座にロジック見直し（インシデント対応）に入れる仕組みです。

---

# データパイプライン内の位置 / Architecture Position

本SQLは、Query1で確定した金額データと結合するための**「正しい注文属性（Dimension）」**を提供する Staging Layer です。

```text
[Raw Tables]
   │
   ├─▶ 01_stg_order_amount.sql 
   ├─▶ 02_stg_order_info.sql (This SQL) ──┐
   │                                      ▼
   ├─▶ 03_stg_return_history.sql[Intermediate]
   ├─▶ 04_int_cancellation_return ─────▶ 05_fct_all_purchases_unified
```
---

# 運用と保守 / Operations & Maintenance 

### データ品質監視とSLI (Data Quality Monitoring & SLI)
本クエリで算出される `manual_heuristic_ratio_pct`（手動推測の割合）は、データ基盤の健康状態を測る重要な監視指標（SLI: Service Level Indicator）です。BIツールやオーケストレーションツール（dbt, Airflow等）でこの値を監視し、閾値（例: 5%）を超えて急増した場合は「上流システムでのカテゴリ情報欠損バグ」を疑い、即座にアラートを発報する運用を推奨します。

The `manual_heuristic_ratio_pct` acts as a Service Level Indicator (SLI) for data health. We recommend monitoring this value via BI or orchestration tools (e.g., dbt, Airflow). A sudden spike (e.g., > 5%) triggers an immediate alert, indicating a potential category data loss bug in the upstream systems.

### 正規表現ロジックの保守 (Regex Logic Maintenance)
返品注文と元注文を紐付ける「親子の絆キー（`order_link_key`）」の生成には、正規表現 `.*-0[0-9]{2}$` を使用しています。将来的にECシステムの仕様変更により、枝番が3桁（例: `-100`）になるなどのフォーマット変更が発生した場合は、`order_id_normalization` CTE内の正規表現パターンのアップデートが必要です。

The generation of the `order_link_key` relies on the regex pattern `.*-0[0-9]{2}$`. If future EC system updates introduce new return branch formats (e.g., 3-digit suffixes like `-100`), the regex pattern in the `order_id_normalization` CTE must be updated accordingly.

### 補正辞書の運用と拡張性 (Dictionary Management & Extensibility)
プロモーションコードの補正や、旧ID形式における例外的な定期判定ルールは、SQL内にハードコードするのではなく、外部の補正辞書テーブル（`map_promo_code_correction`, `map_subsc_heuristic_correction`）に切り出しています（疎結合設計）。これにより、将来のイレギュラーパターンの追加時にも、SQLのコード改修・テストを行うことなく、マスタデータの更新のみで迅速に対応可能です。

Exceptions such as promo code corrections and legacy ID heuristic rules are separated into external dictionary tables (loosely coupled design) rather than hardcoded in SQL. This allows data teams to handle new edge cases simply by updating the master data, without requiring SQL code modifications or deployments.
