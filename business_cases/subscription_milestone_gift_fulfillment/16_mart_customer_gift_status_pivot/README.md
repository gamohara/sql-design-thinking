# 概要 / Overview

特典対象者の「配信ステータス（1回目、2回目、追加分）」を、1人の顧客（1コース）につき1行で横並びに見れるように変換（ピボット）するSQLの設計例です。

以下の処理を含みます。
- ウィンドウ関数を用いた疑似PIVOT処理（タイミング別の横展開）
- 複数回のエラー履歴を時系列でスラッシュ区切りに結合する備考カラムの生成
- 正常配信された顧客とエラー保留となった顧客を同じ形式で確認できる統合ビュー

Example SQL that pivots a customer's vertically-stacked gift delivery history (1st, 2nd, bonus) into a single row per customer/course using a window-function pivot pattern, giving support staff a one-glance view spanning both successful deliveries and error holds.

---

## データパイプライン内の位置 / Architecture Position

[15](../15_mart_delivery_status_summary/)（統合ステータス表）と [02](../02_stg_gift_eligible_order_confirmed/)（F1コース情報）を統合します。

Combines [15](../15_mart_delivery_status_summary/) (consolidated status report) with F1 course information from [02](../02_stg_gift_eligible_order_confirmed/).

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern
ウィンドウ関数による疑似PIVOTと履歴の時系列テキスト集約
Window-Function Pivot & Time-Ordered History Aggregation

### 課題 / Problem

運用やCSの現場では、特定のお客様から問い合わせがあった際「このお客様は、いつ、どの特典をもらっていて、次はいつ貰える予定なのか」というジャーニー全体像を一目で把握する必要があります。縦積みのデータのままでは、この確認作業のたびに複数行を目で追う必要があり非効率です。

Support staff need an at-a-glance view of a customer's full gift journey. A vertically-stacked layout forces them to scan multiple rows every time, which is inefficient for real-time customer support.

### 解決策 / Solution

`MAX(CASE WHEN present_timing_char = 'X回目' THEN ... END) OVER(PARTITION BY user_id)` というウィンドウ関数のパターンを用いて、タイミングごとにカラムを分けてデータを横展開（疑似PIVOT）します。将来的にタイミングが増えた場合（例：3回目の追加等）は、このCASE文のブロックをコピペして追加するだけで拡張可能です。また、`LISTAGG` で日付プレフィックス付きの備考を時系列順にスラッシュ区切り結合することで、複数回エラーを起こした顧客の履歴を1つのセルで確認できます。

The window-function pivot pattern (`MAX(CASE WHEN timing = 'X' THEN ... END) OVER(PARTITION BY user_id)`) unpacks the vertical timing dimension into columns without a native `PIVOT` operator, and extends trivially when a new timing is added. `LISTAGG` with a date prefix concatenates multiple error events into one time-ordered, human-readable cell.

---

## 処理ステップ / Processing Steps

### 1. Pivot by Timing
タイミング別のステータス横持ち化。

### 2. F1 Course Info Retrieval
F1対象者とコース区分の取得。

### 3. Pivot Aggregation
横展開結果の1行化。

### 4. Status & F1 Attribute Combination
ステータスとF1属性の統合。

### 5. Final Output Generation
ダッシュボード用表示の整形。

---

## データ構造 / Input Data Structure

### Marts Tables
- `mart_delivery_status_summary` : 統合ステータス表（15）

### Staging Tables
- `stg_gift_eligible_order_confirmed` : F1確定リスト（02）

### Dimension Tables
- `dim_customers_pii` : 顧客属性マスタ（個人情報）

---

## 運用と保守 / Operations & Maintenance

### タイミング拡張の方法
今後プレゼントのタイミング（例：3回目など）が増えた場合は、Step 1のCASE文ブロックをコピペして追加するだけで拡張可能です。

### メール未登録フラグのフェイルセーフ
`is_null_email`（メール未登録フラグ_現在）は、顧客マスタにデータが存在しない（システム統合等で消えた）場合、安全のため強制的に「1（未登録）」を返すフェイルセーフ仕様です。
