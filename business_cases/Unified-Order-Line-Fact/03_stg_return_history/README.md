# 概要 / Overview

前工程でクレンジング・正規化された受注データから、返品（マイナス計上）データのみを安全に分離抽出し、詳細な金額情報を付与して保管するSQLの設計例です。

以下の処理を含みます。
- 正規化テーブルからの返品トランザクションの分離抽出（Data Isolation）
- 返品元の親注文と紐付けるための `order_link_key` の保持
- 生トランザクションテーブルへの再アクセスによる、返品時の決済金額・税抜金額のエンリッチメント（Enrichment）

このSQLは、複雑なECデータ分析において、「売上高」と「返品額」のライフサイクルを明確に切り分けるためのアーキテクチャ（関心の分離）を示す例です。

Example SQL for isolating return transactions from normalized order data and enriching them with detailed financial information. This example demonstrates an architectural best practice (Separation of Concerns) in complex EC data analytics, ensuring that the lifecycles of "gross sales" and "returns" are managed independently.

---

# SQL Design Pattern
返品データの隔離とエンリッチメント（関心の分離）
Data Isolation and Enrichment for Return Transactions

## 課題 / Problem

ECシステムにおいて、売上（購入）と返品は発生タイミングが異なる独立したトランザクションです。
分析用のファクトテーブルを作成する際、購入データと返品データを同じパイプライン上で処理しようとすると、後続のLTV（顧客生涯価値）計算や純売上（Net Sales）の集計時にロジックが極度に複雑化し、バグの温床となります。

In e-commerce systems, purchases and returns are independent transactions that occur at different times. Attempting to process both within the same pipeline drastically complicates logic during downstream LTV or Net Sales aggregation, often leading to calculation errors.

## 解決策 / Solution

**【関心の分離 (Separation of Concerns)】**
前工程のテーブルから「返品フラグが立っているデータ」のみを抽出（Isolate）し、別の独立したテーブルとして保管します。これにより、本線パイプライン（購入データの集計）を汚染することなく、純粋な売上分析が可能になります。

**【データエンリッチメント (Data Enrichment)】**
前工程で切り捨てられた「返品特有の金額情報（マイナス金額など）」を復元するため、意図的に大元の生テーブル（Raw Tables）へ再結合（JOIN）し、分析や監査（Audit）に十分な情報量を持たせています。親注文と紐付く `order_link_key` が保持されているため、いつでもLTV相殺計算などに利用可能です。

---

## 処理ステップ / Processing Steps

本SQLは以下の処理ステップで構成されています。

### 1. Return Data Extraction
前工程のマスタから返品データ（`is_return_order = 1`）のみを抽出

### 2. Financial Enrichment
生テーブル（`raw_orders`, `raw_order_items`）と再結合し、返品に特化した金額情報の付与

### 3. Final Output Generation
保管用・監査用ストックテーブルとしての最終データ生成

---

# データ構造 / Input Data Structure

### Staging Tables
- `stg_order_info` : Query2で作成された受注正規化マスタ

### Raw Transaction Tables (Enrichment用)
- `raw_orders` : 注文ヘッダ（返品時の決済額取得用）
- `raw_order_items` : 注文商品明細（返品時の商品税抜額取得用）

---

# データパイプライン内の位置 / Architecture Position

本SQLはデータパイプラインの **Intermediate Layer（中間処理層）** に位置します。
以降のパイプラインに「クリーンな売上データ」を流すための、フィルター兼ストレージの役割を果たします。

```text[Raw Tables]
   │
   ├─▶ 01_stg_order_amount.sql 
   ├─▶ 02_stg_order_info.sql ──┐
   │                           ▼
   ├─▶ 03_stg_return_history.sql (This SQL: 隔離・保管)
   ├─▶ 04_int_cancellation_return ───────▶ 05_fct_all_purchases_unified
