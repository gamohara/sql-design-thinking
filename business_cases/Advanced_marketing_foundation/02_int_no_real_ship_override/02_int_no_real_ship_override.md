# 概要 / Overview

ECシステムの「ダミー出荷（実発送なし対応）」に起因する、売上の二重計上と返品時のデータ欠損（金額0円問題）を修復し、クリーンな分析用マスタを出力するSQL設計例です。

以下の処理を含みます。
- ウィンドウ関数を活用した安全な「欠損データの修復（Data Restoration / Override）」
- 形式的返品から最終的なビジネス実態への「ステータス継承（Status Inheritance）」
- 紐付けエラーを許容し、売上消失を防ぐための「フェイルセーフ制御（Fail-safe Control）」

このSQLは、データエンジニアリングにおける「異常データの補正」と「システム制約による欠損の安全な復元」を行うアーキテクチャ・パターンの実践例です。

Example SQL for repairing double-counted revenues and missing financial data caused by operational dummy shipments. This example showcases architectural patterns in data engineering for safe data restoration via Window Functions, dynamic status inheritance, and fail-safe controls to prevent revenue loss.

---

# SQL Design Pattern
ウィンドウ関数による安全なデータ伝播とフェイルセーフ制御
Safe Data Propagation via Window Functions & Fail-safe Control

## 課題 / Problem

ECシステムでは、決済変更などに伴う「ダミー出荷」とその相方である「形式的返品」が発生します。これを放置すると売上が二重計上されますが、さらに深刻なのが「旧システムにおける返品時のデータ欠損」です。
旧システムでは、返品処理が行われると元の「商品数量」や「金額」が0にリセットされてしまう仕様があり、そのままでは返品された商品構成や被害額の分析が不可能です。単純にJOINでダミー出荷側のデータを持ってこようとすると、明細の粒度違いによりJOIN爆発（Redundant Join）が発生し、分析基盤が破綻します。

Operational "dummy shipments" and their corresponding "formal returns" not only cause double-counting of revenue but also lead to severe data loss. In legacy systems, executing a return often resets item quantities and amounts to zero, paralyzing return analysis. Simple JOINs to retrieve actuals from the dummy shipment lead to redundant joins and pipeline failures.

## 解決策 / Solution

**【ウィンドウ関数による値の伝播 (Value Propagation via Window Functions)】**
ダミー出荷と返品のペアを1つのグループ（Partition）として括り、`MAX() OVER(PARTITION BY group_order_id)` を用いてダミー側が保持している「正しい数量・金額・支払方法」をグループ内の欠損レコードに伝播（Propagation）させ、上書き（Override）します。これによりJOIN爆発のリスクをゼロに抑えた安全な修復を実現しています。

**【フェイルセーフ除外 (Fail-safe Exclusion)】**
修復を終えた「ダミー出荷レコード」は二重計上を防ぐために除外（WHERE句でフィルタリング）しますが、「紐付けに失敗したダミー出荷（`is_match = 0`）」はあえて残す設計（Fail-safe）を採用しています。これにより、「二重計上になるかもしれないが、売上自体が消失する最悪の事態は防ぐ」というビジネス判断をSQLレイヤーで担保しています。

By utilizing Window Functions for value propagation, the pipeline securely restores missing legacy data without risking JOIN explosions. Furthermore, un-matched dummy shipments are intentionally retained via fail-safe logic, mathematically prioritizing "potential double-counting" over the absolute disaster of "revenue loss."

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
