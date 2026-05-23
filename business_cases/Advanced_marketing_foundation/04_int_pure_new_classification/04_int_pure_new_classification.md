# 概要 / Overview

ECデータパイプラインにおいて、マーケティングKPI（CPAやLTV等）の土台となる「純新規フラグ」と「累計購入回数」を、顧客統合（名寄せ）による過去データ改変から保護し、厳密に算出して付与するSQL設計例です。

以下の高度なデータ処理を含みます。
- ノイズとなる付帯商品を除外し、ビジネスのコア（定期 / トライアル）にのみ着目したデータフィルタリング
- `DENSE_RANK` と `PARTITION BY` トリックを用いた、複数基準（全履歴 vs 獲得日以降）での動的採番
- システム上の「顧客統合（Merge）」によって失われる「獲得当時の純新規ステータス」を復元・固定化するロジック（Immutable Pure-New Evaluation）

Example SQL for generating strictly evaluated "Pure-New" flags and cumulative purchase counts, which serve as the foundation for marketing KPIs like CPA and LTV. This example demonstrates an advanced technique to protect historical "Pure-New" statuses from being overwritten by operational customer merges, ensuring immutable and reliable analytics.

---

# SQL Design Pattern
顧客統合（名寄せ）を考慮した Immutable（不変）な純新規判定ロジック
Immutable Pure-New Classification Logic Resilient to Customer Merges

## 課題 / Problem

ECシステムを長く運用していると、重複して登録された顧客アカウントを手動または自動で統合（Merge）する処理が発生します。この際、別々だった過去の購入履歴が1つのユーザーIDに合算されます。
このデータをそのまま `ORDER BY` で採番し直すと、**「当時、純新規の広告から入ってきたにもかかわらず、統合された結果、過去の別アカウントの購入が1回目となり、現在のデータ上では『リピーター』に書き換わってしまう」**という大問題（KPIの過去改変）が発生します。
これにより、「特定の月の新規獲得CPA」を振り返って集計するたびに数字が変わってしまい、分析基盤への信頼が完全に失われます。

When duplicate customer accounts are merged, legacy purchase histories are aggregated under a single User ID. If cumulative purchase counts are simply recalculated over this merged history, customers who were correctly flagged as "Pure-New" at the time of acquisition are retroactively overwritten as "Repeaters." This historical alteration breaks marketing KPIs (e.g., CPA, CPO), destroying trust in the analytics platform because historical reports change every time they are refreshed.

## 解決策 / Solution

**【獲得日を起点とした動的採番 (Acquisition-Anchored Rank)】**
顧客統合フラグ（`is_cus_merged`）が立っているユーザーに対してのみ、「顧客獲得日」を起点（Anchor）として採用します。さらに、基幹システムと外部カートシステム間のデータ連携ラグを吸収するため、「獲得日 - 3日」のバッファラインを引き、それ以前の過去データは採番から除外する（PARTITIONを分ける）というSQLのトリックを使用しています。

**【指標の動的切り替え (Dynamic Flag Determination)】**
最終出力において、非統合顧客は「全履歴ベースの1回目」、統合顧客は「獲得日ベースの1回目」を動的に使い分け、1つの【純新規フラグ(統合考慮)】にまとめます。これにより、過去にどう名寄せされようと変動しない、不変（Immutable）なビジネス指標を算出できます。

By establishing an anchor point ("Customer Acquisition Date - 3 days") for merged users and separating the partition for ranking, the SQL recalculates the purchase sequence solely from that point forward. The final output dynamically selects the correct baseline (Full-History vs. Acquisition-Anchored), guaranteeing an immutable "Pure-New" flag.

---

## 処理ステップ / Processing Steps

本SQLは以下の処理ステップ（CTE）で構成されています。

### 1. Core Product Filtering
LTV分析において重要となる主要商品群（RG: 定期 / TR: トライアル）への絞り込み

### 2. Dual-Baseline Ranking Computation
`DENSE_RANK()` を用いた、「全履歴ベース」および「獲得日考慮ベース」の2軸並行での購入回数採番

### 3. Product Mix Evaluation
同一注文内に RG/TR が混在した場合の、ビジネスルール（RG優先）に基づく商品構成フラグの生成

### 4. Dynamic Pure-New Flag Determination
顧客マスタの統合ステータス（`is_cus_merged`）を評価し、最終的な【純新規フラグ(統合考慮)】を動的に確定

### 5. Final Output Generation
BIツール向けのディメンション整形と最終データセットの出力

---

# データ構造 / Input Data Structure

このSQLは以下のエンリッチメント済ステージングテーブルを前提としています。

### Staging Tables
- `stg_product_media_enrichment_master` : 前工程で生成された商品・媒体・顧客情報結合マスタ

---

# データ品質チェック / Data Quality Strategy

### 乖離モニタリング (Divergence Monitoring for Flag Fragility)
本クエリでは、唯一の正として扱う【純新規フラグ(統合考慮)】だけでなく、チェック用の【純新規フラグ(全履歴)】と【純新規フラグ(分析対象)】もあえて残して出力しています。
BIツール上でこれらのフラグ間の差分（乖離件数）をモニタリングすることで、システム上で「想定外の大量の顧客統合」が行われていないか、あるいは「獲得日の異常な書き換え」が発生していないかを監査（Audit）することが可能です。

By intentionally outputting the intermediate check flags alongside the final "Pure-New" flag, data teams can monitor the divergence between them in BI tools. A sudden spike in divergence serves as an alert for unexpected mass customer merges or abnormal acquisition date overwrites in the upstream system.

---

# データパイプライン内の位置 / Architecture Position

本SQLはデータパイプラインの **Intermediate Layer（中間処理層）** に位置し、マーケティング分析の最重要KPIを確定させます。

```text
[Raw Tables]
   │
   ├─▶ 01_stg_no_real_ship_matching.sql 
   ├─▶ 02_int_no_real_ship_override.sql 
   ├─▶ 03_stg_product_media_enrichment.sql ──┐
   │                                         ▼
   └─────────────────────────────────────────▶ 04_int_pure_new_classification.sql (This SQL) ──▶ Fact Tables
```
