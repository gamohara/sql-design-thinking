# 概要 / Overview

ECファクトデータに対して、商品属性、広告媒体、顧客ステータス、および各種キャンペーンフラグを結合し、BIツールでの分析次元（Dimensions）を大幅に拡張するSQL設計例です。

以下の高度なデータ処理を含みます。
- 注文日時とマスタの更新履歴を比較した、**SCD Type 2（ゆっくり変化する次元）に基づく広告媒体の正確な紐付け**
- 1注文複数明細を考慮した、`DENSE_RANK` 関数による**正確な累計購入回数（F1, F2...）の算出**
- マスタに存在しない「幽霊顧客」に対する、後続のCRM誤配信を防ぐための**フェイルセーフ制御（強制削除フラグの付与）**

Example SQL for enriching EC fact data by integrating product attributes, advertising media, customer statuses, and various campaign flags to expand analytical dimensions for BI tools. This example showcases advanced data processing such as SCD Type 2 resolution for ad media, precise cumulative purchase counts via DENSE_RANK, and fail-safe controls for missing "ghost customers."

---

# SQL Design Pattern
SCD Type 2 解決とフェイルセーフ型ディメンション統合
SCD Type 2 Resolution & Fail-safe Dimension Integration

## 課題 / Problem

効果改善のために広告LP（ランディングページ）が改修された場合、同じプロモコードであっても、注文されたタイミングによって顧客が見た内容は異なります（新旧LPの混在）。これを単一のプロモコードだけで結合すると、ABテストの引き上げ率やLTV分析が正確に行えません。
また、DWH環境においてはシステム統合（名寄せ）の過程で「トランザクションには存在するが、顧客マスタからは消滅している幽霊顧客」が稀に発生します。このデータをそのまま後続のCRM（デジタルギフト券の自動送付など）に流すと、重大なコンプライアンス違反や誤送付リスクを引き起こします。

When ad landing pages (LPs) are updated for optimization, customers may see different versions despite using the same promo code. Joining solely on the promo code corrupts A/B test and LTV analytics. Furthermore, data integrations can produce "ghost customers" who exist in transaction logs but are missing from customer masters. Passing these records to downstream CRM pipelines (e.g., digital gift card distribution) poses severe compliance risks.

## 解決策 / Solution

**【SCD Type 2 による時系列解決 (SCD Type 2 Resolution)】**
外部の「更新履歴CSV」を連携させ、顧客の注文日時（`ordered_at`）とプロモの改修日時（`updated_at`）を動的に比較するロジック（`is_promo_status`）を実装しました。これにより、同じプロモコードであっても時系列に応じた「正しいバージョンの媒体マスタ」を1対1で正確に結合（SCD Type 2の解決）できます。

**【フェイルセーフ制御 (Fail-safe Control)】**
顧客マスタ（`dim_customers`）との `LEFT JOIN` 結果を監視し、「IDがNULL、またはすでに削除・統合済み」のユーザーに対しては、SQL側で強制的に `is_cus_deleted_merged = 1`（削除フラグ）を上書きするフェイルセーフを実装。これにより、分析ノイズとCRMの運用事故を未然に防ぎます。

---

## 処理ステップ / Processing Steps

本SQLは以下の処理ステップ（CTE）で構成されています。

### 1. Base Fact Retrieval
前工程で精製された受注ファクトデータの取得

### 2~6. Dimension Masters Preparation
商品、媒体、顧客、プロモ更新履歴、キャンペーンCSVの取得と整理

### 7. Promo Version Evaluation (SCD Processing)
注文日時と履歴マスタを比較したプロモ新旧バージョンの動的判定

### 8. Dimension Integration & Fail-safe
全マスタの横断結合および、幽霊顧客に対する強制削除フラグの付与

### 9. Analytics Metrics Calculation & Final Output
BIツール向けディメンション整形と、`DENSE_RANK` を用いた累計購入回数（F1/F2）の算出

---

# データ構造 / Input Data Structure

### Fact Tables
- `int_order_dummy_override_master` : 実発送なし処理・フラグ修復済みの受注ファクト

### Dimension Tables & CSVs
- `dim_products` : 商品属性マスタ
- `dim_media_info` : 媒体情報マスタ（新旧の運用状態保持）
- `dim_customers` : 顧客属性マスタ
- `src_promo_update_history` : プロモコード更新履歴（CSV）
- `src_product_campaign_flags` : 商品別キャンペーン・解約ルール一覧（CSV）

---

# データパイプライン内の位置 / Architecture Position

本SQLはデータパイプラインの **Enrichment Layer（ディメンション拡充層）** に位置します。

```text
[Fact] int_order_dummy_override_master ──┐
[Dim]  dim_products ─────────────────────┤
[Dim]  dim_media_info ───────────────────┼──▶ 03_stg_product_media_enrichment.sql (This SQL) ──▶ Next Process
[Dim]  dim_customers ────────────────────┤
[CSV]  src_promo_update_history ─────────┤
[CSV]  src_product_campaign_flags ───────┘
```  

---

# 運用と保守 / Operations & Maintenance  

### プロモーション改修履歴の運用 (Promo Update History Management)  
媒体側でLPのファーストビュー（FV）更新やオファー変更が発生した場合、データチームは src_promo_update_history (CSV) に対象コードと更新日時（JST）を追記するだけで、本SQLを修正することなく動的に新旧フラグが切り替わる疎結合（Loosely Coupled）な運用設計となっています。  

If LPs are updated (e.g., First View or Offer changes), the marketing or data team simply appends the promo code and update timestamp to the src_promo_update_history CSV. The SQL dynamically resolves the versions without requiring any code modifications, ensuring a loosely coupled operational design.  

### 新規キャンペーンへの拡張性 (Campaign Extensibility)  
特定の新規施策（例：ブランドAの初回購入キャンペーン、全額返金保証）が追加された際は、src_product_campaign_flags (CSV) にカラムとフラグ（0/1）を追加し、本SQLの SELECT句 に追記するだけで即座にBIツールでLTV分析が可能になります。  
