# 概要 / Overview

デジタルギフト特典の「配信予定日」ごとの対象者数（予測件数・予定件数）を出力し、ギフトコード総在庫からの累積シミュレーションで「在庫切れXデー」を自動検知するSQLの設計例です。

以下の処理を含みます。
- カレンダーテーブルの自動生成によるゼロ埋め補完（対象者0人の日でグラフが歯抜けにならない）
- カレンダー出力範囲の「月初〜月末」への丸め（BI表示の見栄え向上）
- 過去実績＋未来予測の累積和による在庫枯渇シミュレーション

Example SQL that outputs daily target counts per gift delivery date (zero-filled via a generated calendar so BI trend charts show no gaps) and runs a running-sum stock-out simulation against the total gift code inventory.

---

## データパイプライン内の位置 / Architecture Position

[10_int_predelivery_alert_check](../10_int_predelivery_alert_check/)（現在・未来の予測）と `map_gift_target_ledger`（過去の確定実績）を統合します。

Combines future/current projections from [10_int_predelivery_alert_check](../10_int_predelivery_alert_check/) with confirmed past actuals from `map_gift_target_ledger`.

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern
ギャップフリーカレンダー生成と累積和による在庫枯渇の自動検知
Gap-Free Calendar Generation & Cumulative-Sum Stock-Out Detection

### 課題 / Problem

単に実績がある期間だけを切り取ると、グラフの横軸が「中途半端な日付」になり月ごとのトレンドが見づらくなります。また、対象者が0人の日はデータが存在しないため、単純なLEFT JOINだけではグラフに歯抜けが生じます。ギフトコードの在庫切れも、目視でチェックしなければ検知が遅れます。

Simply slicing to the data's actual date range produces an awkward, mid-month axis and makes monthly trends hard to read. Days with zero targets have no rows at all, so a naive join leaves gaps in the chart. Stock depletion also goes undetected without manual monitoring.

### 解決策 / Solution

**【月次丸めとゼロ埋め】**
`DATE_TRUNC('MONTH', ...)` を用いて、実績の最小日を「月初」に、最大日を「月末」に丸めた範囲でカレンダーを生成し、`ROW_NUMBER() OVER (ORDER BY SEQ4())` により歯抜けのない連続日付を作成。実績をLEFT JOINし、NULLを0件に変換（ゼロ埋め）します。

**【累積和による在庫枯渇シミュレーション】**
過去の配信済み実績と未来予測を1本のタイムラインに統合し、日別配信数の累積和（`SUM() OVER(ORDER BY ...)`）をコード総在庫数から引き算します。この値が0以下になる最初の日付を「在庫切れXデー」として自動検知します。

By rounding the calendar range to whole months and generating a gap-free date sequence, zero-target days are guaranteed to appear in the output. By running a cumulative subtraction of the daily delivery count from total inventory across a unified past+future timeline, the first stock-out date is detected automatically without manual monitoring.

---

## 処理ステップ / Processing Steps

### 1-2. Target List Build & Daily Counting
過去実績と現在・未来予測の統合、日別対象者数のカウント。

### 3-4. Date Range Expansion
実績期間の取得と月初〜月末への拡張。

### 5-6. Calendar Generation & Zero-Fill
ギャップフリーカレンダーの生成と実績のゼロ埋め結合。

### 7-8. Stock Simulation & Alert Detection
累積和による在庫シミュレーションと在庫切れ日の特定。

### 9. Final Output Generation

---

## データ構造 / Input Data Structure

### Intermediate Tables
- `int_predelivery_alert_check` : 現在・未来の予測対象者（10）

### Master Tables
- `map_gift_target_ledger` : 対象者リスト（過去の確定実績）
- `map_gift_code_inventory` : デジタルギフトコード在庫一覧（総在庫数の算出元）

---

## 運用と保守 / Operations & Maintenance

### 月末日算出ロジック
Step 4の月末日算出（「1ヵ月足した日付の月初から1日引く」）は、うるう年や月末日（28, 30, 31日）の変動を正確に吸収する堅牢な計算式です。変更しないでください。

### 連番生成のお作法
Step 5の `ROW_NUMBER() OVER (ORDER BY SEQ4())` は、Snowflake環境において絶対に歯抜けのない連番を生成するための必須のお作法です。

### 除外条件の非対称性について
`is_due_to_email_error`（メール不備）は現在・未来どちらの対象者にも適用される一方、`is_shipped_not_delivered`（出荷止まり）・`is_payment_pending`（未入金）は「現在」の対象者にのみ適用されます。これは、未入金・出荷止まりが時間の経過とともに自然に解消される可能性が高い一時的な状態であるのに対し、メールアドレスの不備（配信停止・誤登録等）は顧客自身が能動的に修正しない限り、配信予定日が来ても状況が変わらない可能性が高いためです。この違いを踏まえ、自然解消が見込める2条件は「まだ時間がある」未来分では判定を保留し、解消の見込みが薄いメール不備のみ未来分も含めて早期に除外しています。

While `is_due_to_email_error` (email issues) is applied to both "current" and "future" targets, `is_shipped_not_delivered` (shipment stalled) and `is_payment_pending` (payment pending) are applied only to "current" targets. This is because unpaid/stalled-shipment states are temporary and likely to resolve naturally over time, whereas an email address problem (bounced, mistyped, etc.) is unlikely to change by the delivery date unless the customer actively corrects it. Given this difference, the two naturally-resolving conditions are deferred for "future" targets (which still have time left), while the email-issue condition — unlikely to self-resolve — is excluded early, covering future targets too.
