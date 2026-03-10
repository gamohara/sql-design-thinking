# Subscription Price Calculation

## 概要 / Overview

定期購入における次回配送金額を計算するSQLの設計例です。

以下の処理を含みます。

- 定期配送周期の正規化
- 商品小計の計算
- 割引適用
- 税抜金額計算
- ポイント配分ロジック

このSQLは、サブスクリプション型ECデータにおける  
SQL設計パターンとデータ理解のための思考プロセスを示す例です。

---

Example SQL for calculating subscription delivery pricing including:

- delivery cycle normalization
- discount calculation
- tax calculation
- point allocation logic

This example demonstrates SQL design patterns and structured thinking for understanding subscription-based ecommerce datasets.

## SQL Example

- subscription_point_allocation_logic.sql
