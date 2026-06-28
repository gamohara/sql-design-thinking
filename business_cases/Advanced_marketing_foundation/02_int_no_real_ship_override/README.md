# 概要 / Overview

ECシステムの「ダミー出荷（実発送なし対応）」に起因する、売上の二重計上と返品時のデータ欠損（金額0円問題）を修復し、クリーンな分析用マスタを出力するSQL設計例です。

以下の高度なアーキテクチャを含みます。
- データの分裂・合算・ID変更というカオスな非対称性に対応する**「多段フォールバック修復（Multi-Tier Data Restoration）」**
- 形式的返品から最終的なビジネス実態（入金済等）への**「ステータス継承（Status Inheritance）」**
- 紐付けエラーを許容し、売上消失を防ぐための**「フェイルセーフ制御（Fail-safe Control）」**

このSQLは、データエンジニアリングにおける「異常データの補正」と「システム制約による欠損の安全な復元」を行うアーキテクチャ・パターンの実践例です。

Example SQL for repairing double-counted revenues and missing financial data caused by operational dummy shipments. This example showcases advanced architectural patterns, including a multi-tier fallback mechanism to handle asymmetric data splits/merges, dynamic status inheritance, and fail-safe controls to prevent revenue loss.

---

# SQL Design Pattern
多段フォールバック修復と安全なデータ伝播
Multi-Tier Data Restoration & Safe Data Propagation via Window Functions

## 課題 / Problem

旧システムにおける「返品時に金額・数量が0にリセットされてしまう問題」を修復するには、ダミー出荷側の実績値を持ってくる必要があります。しかし、現場のオペレーションの過程で「商品Aが2個」だったものが、ダミー側では「商品Aが1個、商品Bが1個」に分裂したり、逆に合算されたり、商品IDが変わってしまったりするケース（データの非対称性）が頻発します。
単なる「商品ID＋枝番」の1対1マッチング（JOIN）ではこれらを修復できず、結果として分析データに無数のNULL（欠損値）が発生してしまいます。

In legacy systems, executing a return often resets item quantities and amounts to zero. To restore this data, actuals from the dummy shipment must be utilized. However, operational workarounds frequently cause data asymmetry—items are split, merged, or substituted across the original and dummy orders. Simple 1-to-1 JOINs fail to handle these edge cases, resulting in massive NULL values in the analytics data mart.

## 解決策 / Solution

**【ウィンドウ関数による値の伝播 (Value Propagation via Window Functions)】**
ダミー出荷と返品のペアを1つのグループ（Partition）として括り、`MAX() OVER(PARTITION BY group_order_id)` を用いてダミー側が保持している「正しい数量・金額・支払方法」をグループ内の欠損レコードに伝播（Propagation）させ、上書き（Override）します。これによりJOIN爆発のリスクをゼロに抑えた安全な修復を実現しています。

**【3段構えのフォールバック・アーキテクチャ (3-Tier Fallback Restoration)】**
どのようなイレギュラーデータでも確実に修復できるよう、ウィンドウ関数を活用して以下の3つの修復ルートを実装しました。
1. **通常ルート (Exact Match)**: 商品ID＋枝番 が完全一致する場合に適用。
2. **分裂ルート (Category Rollup)**: ダミー側で明細が分裂した場合、カテゴリ単位で合算（SUM）した値を適用。
3. **ID違いルート (Category-Sequential Match)**: 明細数は同じだが商品IDが変わった場合、カテゴリ内の連番でお見合い適用。

これにより、JOIN爆発のリスクをゼロに抑えたまま、修復成功率を極限まで引き上げることに成功しています。

By utilizing Window Functions, the pipeline implements a 3-tier fallback architecture (Exact Match, Category Rollup, and Category-Sequential Match). This guarantees safe data restoration even when items are split or substituted, maximizing recovery rates while completely eliminating the risk of JOIN explosions.

---

## 処理ステップ / Processing Steps

本SQLは以下の処理ステップ（CTE）で構成されています。

### 1. Base Data Retrieval
元データの取得（実発送なし対応前のベースデータ）

### 2. Pair Information Filtering
ペア情報の取得と信頼度（30点以上）によるフィルタリング

### 3. Key Expansion (Unpivoting)
ペア情報の縦展開（JOIN用共通キーの生成）

### 4. Value Propagation
ウィンドウ関数を用いたダミー出荷実績値のグループ内伝播

### 5. Data Override
旧形式データの欠損修復（金額・数量等のオーバーライド）

### 6. Final Output & Fail-safe Exclusion
返品フラグの継承、派生フラグの生成、およびフェイルセーフ除外の適用

---

# データ構造 / Input Data Structure

このSQLは以下のステージングテーブルを前提としています。

### Staging Tables
- `stg_all_purchases_base` : 全購入基本データ（05_fct_all_purchases_unified）
- `stg_no_real_ship_matching` : 前工程で生成された実発送なし・返品紐付け結果（01_stg_no_real_ship_matching）

---

# データパイプライン内の位置 / Architecture Position

本SQLはデータパイプラインの **Intermediate Layer（中間処理層）** に位置します。
ダミー出荷の特定（SQL 5.2）とセットで動作し、ノイズのないクリーンな売上・返品データマートを提供します。

```text
[Raw Tables]
   │
   ├─▶ stg_all_purchases_base ────────┐
   ├─▶ raw_no_real_ship_data  ──┐     │
   │                            ▼     ▼
   │  01_stg_no_real_ship_matching.sql│
   │                                  │
   └──────────────────────────────────┼──▶ 02_int_no_real_ship_override.sql (This SQL) ──▶ Fact Tables
   ```  

---

# 運用と保守 / Operations & Maintenance  

### 信頼度閾値のチューニング (Reliability Threshold Tuning)  
dummy_pairs_info CTE内の抽出条件 match_score >= 30 は、紐付けを採用するか否かのクリティカルな閾値です。データ監査の結果、誤った紐付け（False Positive）が多いと判断された場合は、この値を 60（RELAXED）等に引き上げることで、より厳格な修復コントロールが可能です。  

The extraction condition match_score >= 30 is a critical threshold. If regular data audits indicate an increase in false positive pairings, data teams can increase this threshold to 60 (RELAXED) to enforce stricter restoration controls.  

### 派生フラグの活用 (Leveraging Derived Flags)  
本クエリで出力される ダミー返品フラグ (is_dummy_return) と 返品_返金保証除く_フラグ (is_pure_return) は、BIツール等で極めて重要です。「システム上の返品率」ではなく、「顧客の不満に起因する真の返品率」をダッシュボードでモニタリングする際は、これらのフラグをフィルターとして活用してください。
