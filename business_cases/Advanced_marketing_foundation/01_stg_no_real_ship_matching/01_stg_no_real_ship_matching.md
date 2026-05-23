# 概要 / Overview

ECシステムのオペレーション都合で発生する「実発送なし（ダミー出荷）」データと、それに対応する「形式的返品」データを、SQLのみで正確に1対1でペアリングするデータエンジニアリング設計例です。

以下の高度なアルゴリズムを含みます。
- `LISTAGG` 関数を利用した注文構成の**フィンガープリント（Fingerprint）生成**と配列比較
- 厳格から寛容まで、6段階（STRICT〜POTENTIAL）に分けた**多段階ゲート・マッチング（Multi-Gate Matching Evaluation）**
- 1つの返品IDを複数のダミーIDが取り合う「N対MのJOIN爆発」を防ぐための、**カスケード型貪欲法（Cascade Greedy Algorithm）による競合解消**

このSQLは、データエンジニアリングにおける「状態遷移のモデリング（State Modeling）」と、複雑なビジネス要件をロジックに落とし込む設計パターンを示す例です。

Example SQL for strictly pairing "Dummy Shipments" with "Formal Returns" caused by EC operational workarounds. This example showcases advanced SQL algorithms, including Fingerprint Generation for array-like comparisons, Multi-Gate Matching, and a Cascade Greedy Algorithm to resolve N-to-M JOIN explosions. This example demonstrates State Modeling in data engineering, translating nuanced business requirements into robust SQL logic.

---

# SQL Design Pattern
カスケード型貪欲法による N対M JOIN爆発の解決
Resolving N-to-M JOIN Explosions via Cascade Greedy Algorithm

## 課題 / Problem

ECシステムにおいて、決済方法の変更や預り金対応を行う際、「一度返品処理を行い、商品を出荷せずに再度別IDで売上を立てる（ダミー出荷）」というオペレーションが頻発します。
このデータを放置すると、LTV（顧客生涯価値）や継続率が二重計上され、分析基盤が崩壊します。
しかし、これらをシステム上で紐付けるキーは存在せず、商品内容や金額、時系列から**「推測してペアリング（Bipartite Matching）」**するしかありません。単純にJOINすると、同じ返品データを複数のダミー出荷が取り合い、データが天文学的に増殖（JOIN爆発）してしまいます。

In EC systems, operational workarounds (e.g., changing payment methods) often generate "Dummy Shipments" and "Formal Returns" without a shared linkage key. Attempting to pair them heuristically via simple JOINs leads to massive N-to-M JOIN explosions, as multiple dummy shipments compete for the same return ID, corrupting LTV and retention analytics.

## 解決策 / Solution

**【フィンガープリントによる構成比較 (Fingerprint Comparison)】**
注文内の複数商品の「商品ID」や「数量」を、`LISTAGG` 関数を用いて1つの文字列（例: `A:2|B:1`）にハッシュ化（フィンガープリント化）し、これをキーにして厳密な完全一致判定を可能にしました。

**【カスケード型貪欲法 (Cascade Greedy Conflict Resolution)】**
マッチングの強度（6段階）と時系列に基づき、全ての候補に優先順位（Rank）を付与します。
CTEの連鎖を利用し、「Rank 1で確定したペア（相思相愛）」を `LEFT JOIN ... IS NULL`（Anti-Join）で除外し、残ったフリーなID同士で「Rank 2（敗者復活戦）」を確定させる……というカスケード処理をSQLのみで実装。これにより、**プログラム言語を用いずにSQLだけで「1対1の双方向ユニーク（Strict 1-to-1 Bidirectional Uniqueness）」を数学的に担保**しています。

By ranking candidates and implementing a greedy algorithm via successive Anti-Joins to exclude already-matched IDs, the pipeline ensures strict 1-to-1 bidirectional uniqueness using only SQL.

---

## 処理ステップ / Processing Steps

本SQLは以下の処理ステップ（CTE）で構成されています。

### 1. Fingerprint Generation
ダミー出荷側と返品側それぞれの注文明細を `LISTAGG` で文字列化し、4種類のフィンガープリントを生成。

### 2. Multi-Gate Matching (Gate 1~6)
完全一致（STRICT）からカテゴリ推測（POTENTIAL）まで、6段階の条件でペア候補を抽出。

### 3. Union & Conflict Ranking
全関門の候補を統合し、スコアと時系列でユーザー内の優先順位（Rank）を付与。

### 4. Cascade Conflict Resolution (Rank 1~3)
Anti-Join（自己除外結合）を用いた貪欲法による敗者復活戦。使用済みのIDを弾きながら1対1のペアを順次確定。

### 5. Final Output & SLI Calculation
確定ペアの結合と、マッチング品質を監視するためのSLI（紐づけ強度分布）の算出。

---

# データ構造 / Input Data Structure

このSQLは以下のステージングテーブルを前提としています。

### Staging Tables
- `raw_no_real_ship_data` : 実発送なし（ダミー出荷）データ
- `stg_all_purchases_base` : 全購入基本データ（比較用のシステム返品データ抽出元）

---

# データ品質チェック / Data Quality Strategy

### Data Observability (マッチング品質のSLI化)
このパイプラインは不確実なデータ同士を推測で紐付けるため、常に品質監視が必要です。
本クエリでは、`STRICT`（信頼度100）から `UNMATCHED`（紐付け失敗）までの割合を、**データ品質監視用のSLI（Service Level Indicator）**としてカラムに付与しています。

To monitor the quality of heuristic pairings, the query calculates the percentage distribution of match strengths (from STRICT to UNMATCHED) as Service Level Indicators (SLIs).

---

# データパイプライン内の位置 / Architecture Position

本SQLはデータパイプラインの **Intermediate Layer（中間処理層）** に位置します。ダミー出荷の特定と除外フラグの生成をここで行います。

```text
[Raw Tables]
   │
   ├─▶ stg_all_purchases_base ────────┐
   ├─▶ raw_no_real_ship_data  ──┐     │
   │                            ▼     ▼
   └───────────────────────▶ 01_stg_no_real_ship_matching.sql (This SQL) ──▶ Next Process
```  

---

# 運用と保守 / Operations & Maintenance  

### マッチング精度の監視 (Matching Accuracy SLIs)  
運用チームは、UNMATCHED または POTENTIAL の割合が急増した場合、「ECシステムの裏側で未知のイレギュラー処理が発生した」とみなし、即座に業務プロセス（コールセンター等のオペレーション）のヒアリングを行う必要があります。  

If the proportion of UNMATCHED or POTENTIAL records spikes, it strongly indicates a new, unhandled operational workaround in the EC system. The data team must investigate upstream business processes (e.g., call center workflows) immediately.  
