# 概要 / Overview

確定済みのF1（起点購入）を基準に、その顧客の「F2以降の定期購入実績」を漏れなく抽出し、特典付与判定のベースデータを作成するSQLの設計例です。

以下の処理を含みます。
- 顧客ごとの起点（F1）出荷日の特定
- F1より後に発生した定期購入明細の抽出
- 同一顧客・同一出荷日に複数注文が発生した場合の警告フラグ付与

Example SQL for extracting all subscription shipments occurring after a customer's anchor (F1) purchase, with same-day multi-order anomalies surfaced as warnings for downstream handling.

---

## データパイプライン内の位置 / Architecture Position

[02_stg_gift_eligible_order_confirmed](../02_stg_gift_eligible_order_confirmed/) で確定したF1リストをアンカーとして使用します。

Uses the confirmed F1 list from [02_stg_gift_eligible_order_confirmed](../02_stg_gift_eligible_order_confirmed/) as its anchor.

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern
時系列アンカーによる継続実績抽出と異常出荷の可視化
Time-Series Anchored Extraction & Anomalous Shipment Visibility

### 課題 / Problem

特典付与の条件は「初回から複数回の継続」が前提となるため、F2以降の出荷実績を漏れなく取得する必要があります。また、システムエラーや顧客の操作ミスによる「同日内の複数注文（出荷）」が発生すると、特典タイミングの判定がずれるリスクがあります。

Gift eligibility depends on tracking continued shipments after F1. System errors or operational mistakes can cause multiple same-day orders, which risks misaligning the gift-timing sequence if left undetected.

### 解決策 / Solution

顧客ごとの最古出荷日（F1）を`INNER JOIN`の時系列条件（`ship_date > ship_date_f1`）として使うことで、厳密に「F1より後」のデータのみを抽出します。さらに `COUNT() OVER` と `LISTAGG() OVER` を用いて同日複数出荷を検知し、警告フラグと対象注文IDの一覧を付与することで、この回数の扱いを後続の [05_int_customer_gift_journey_timeline](../05_int_customer_gift_journey_timeline/) に安全に引き渡せるようにしています（同ファイルで「1回として合算」する方式に解決済みです）。

By using the per-customer earliest shipment date as a strict `INNER JOIN` time-series filter, only genuinely post-F1 records are extracted. Same-day multiple shipments are then surfaced via window functions as an explicit warning, safely handed off to [05_int_customer_gift_journey_timeline](../05_int_customer_gift_journey_timeline/), which resolves them by consolidating into a single representative order.

---

## 処理ステップ / Processing Steps

### 1. F1 Anchor Identification
確定済みF1リストから顧客ごとの起点出荷日を取得。

### 2. F2+ Actuals Extraction
起点より後に発生した定期購入明細の抽出。

### 3. Aggregation & Same-Day Flagging
注文単位への集約と同日複数出荷の警告フラグ付与。

### 4. Final Output Generation
チェックカテゴリを付与して最終データ生成。

---

## データ構造 / Input Data Structure

### Staging Tables
- `stg_gift_eligible_order_confirmed` : 前工程（02）の出力（F1アンカー取得元）
- `raw_gift_eligible_purchases` : 特典対象商品ラインの購入明細抽出

### Master / Reference Tables
- `map_gift_manual_exceptions` : 手動対応リスト（`exception_type = 'DELETE_BY_ORDER'`）

---

## データパイプライン内の位置 / Architecture Position（補足）

本SQLはデータパイプラインの **Staging Layer** に位置し、次工程（04・05）でF1・定期予定と統合されます。

---

## 運用と保守 / Operations & Maintenance

### 同日出荷アラートの活用
`同日出荷チェック_大分類` にフラグが立っている場合、同日に別々の注文として商品が出荷されていることを意味します。この回数の扱い（1回として合算するか、注意喚起のみとするか）は、後続の [05_int_customer_gift_journey_timeline](../05_int_customer_gift_journey_timeline/) で、返品状況を踏まえた代表注文の特定・属性伝播により「1回として合算」する方式で解決されています。
