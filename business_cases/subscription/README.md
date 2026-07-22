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

---

## データパイプライン内の位置 / Architecture Position

本ケースの出力は、[Unified-Order-Line-Fact](../Unified-Order-Line-Fact/) の `02_stg_order_info` における  
定期購入情報（`dim_subscription_info`）として参照される想定です。

The output of this case is intended to be referenced as the subscription dimension  
(`dim_subscription_info`) in `02_stg_order_info` of [Unified-Order-Line-Fact](../Unified-Order-Line-Fact/).

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern

### 定期購入における累計配分ロジック  
Subscription Point Allocation Logic

**課題 / Problem**

複数商品にポイントを按分する際、  
四捨五入の積み重ねによって合計が1ポイントずれる問題が発生します。

When allocating points across multiple items,  
rounding errors can cause the final total to differ from the intended value.

---

**解決策 / Solution**

Window関数の累計和（Running Sum）を用いた  
**累積差分方式（Cumulative Difference Allocation）**を採用しています。

This SQL uses a **running sum allocation strategy**  
to ensure that the total allocated points always match the original value.

---

**数式 / Formula**

累計配分ポイント
P_cumulative_i = floor(
P_total × ( cumulative_amount_i / total_amount )
)

---

**実装SQL / SQL Implementation**

- [subscription_point_allocation_logic.sql](./subscription_point_allocation_logic.sql)

このSQLでは、上記のロジックを **CTEを用いて11ステップに分解**し、  
可読性と計算の正確性を両立しています。

The SQL implementation decomposes this logic into  
**11 CTE steps** to improve readability and maintainability.
