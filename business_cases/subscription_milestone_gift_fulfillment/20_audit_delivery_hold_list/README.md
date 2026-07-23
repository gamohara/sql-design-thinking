# 概要 / Overview

当日配信予定であった特典対象者のうち、未配達・メール不備・未入金・過去の配信失敗実績といった条件に引っかかり、システムによって配信がストップ（保留）された顧客を抽出し、その原因を一覧化するSQLの設計例です。

以下の設計を含みます。
- 配信ストップ時の状態を記録する「証拠台帳」としての機能
- プレゼント予定日が「過去・現在」のもののみに絞り込む、運用負荷最小化のタイムライン制御
- CSV記録済み・配信成功済みのデータを除外する「ミュート機能」

Example SQL that produces a "hold ledger" recording why each customer's gift delivery was automatically stopped (delayed shipment, email issue, non-payment, or a confirmed past bounce), restricted to past/current timeline records to keep the operator's To-Do list free of unconfirmed future noise, with already-handled records muted from the output.

---

## データパイプライン内の位置 / Architecture Position

[10](../10_int_predelivery_alert_check/)（配信前アラート）と [14](../14_int_gift_code_pii_distribution/)（配信済み実績）を参照し、パイプラインの最終監査レイヤーとして機能します。

References [10](../10_int_predelivery_alert_check/) (pre-delivery alerts) and [14](../14_int_gift_code_pii_distribution/) (delivery actuals), serving as the pipeline's final audit layer.

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern
証拠台帳としてのスナップショット保存とミュート機能
Snapshot-as-Evidence Ledger with Mute Functionality

### 課題 / Problem

配信をストップした顧客のデータをただ削除して終わらせると、「なぜこの人に送られなかったのか」「後日ステータスが正常に戻った際、当時はなぜ止まっていたのか」を追跡できなくなり、顧客対応やシステム調査に支障をきたします。また、運用担当者が確認済みのアラートをそのまま出力し続けると、運用効率が低下します。

Simply discarding held-back customer data destroys the ability to answer "why wasn't this sent?" or "why was this stuck at the time?" during later investigation. Conversely, continuing to surface already-reviewed alerts wastes operator time.

### 解決策 / Solution

**【証拠台帳としての保存】**
配信ストップ時点の状態（出荷状況・メール状況・入金状況）をスナップショットとして記録し、事後確認やイレギュラー対応のための「配信保留台帳」として機能させます。

**【ミュート機能】**
運用担当者がCSV（配信停止リスト）に記録・対応済みのデータ、およびシステム上で既に「配信成功」となっているデータは、最終出力から除外します。これにより、出力結果は常に「新しく発生した未対応のエラー（To-Do）」のみとなります。

By persisting a snapshot of the hold-time state and muting already-recorded or already-succeeded targets from subsequent runs, the output stays both auditable and actionable — a live To-Do list rather than a growing pile of stale alerts.

---

## 処理ステップ / Processing Steps

### 1-4. Stop Reason Extraction
出荷止まり・メール不備・未入金・実績ベースの配信失敗、各ストップ理由の抽出。

### 5. Combine
縦結合による統合。

### 6. Mute Flag Assignment
記録済み・配信済みの対象者へのフラグ付与。

### 7. Final Output Generation

---

## データ構造 / Input Data Structure

### Intermediate Tables
- `int_predelivery_alert_check` : 配信前アラート済リスト（10）
- `int_gift_code_pii_distribution` : 配信実績（14）
- `stg_past_delivery_bounce` : 過去の配信失敗（不達）実績データ

### Master Tables
- `map_delivery_hold_ledger` : 特典_配信停止リスト.csv

---

## 運用と保守 / Operations & Maintenance

### タイムライン条件の維持
すべてのストップ理由のCTEのWHERE句には、必ず `time_line IN ('過去', '現在')` を含めてください。これを除外すると、未来の予定データまで保留台帳に出力されてしまい、現場の運用が混乱します。

### 新しいストップ理由の追加方法
配信直前でストップさせる新しいルールが追加された場合は、抽出用のCTE（`xxx_alert_list`）を新設し、Step 5のUNION ALLに追加してください。

### ハッシュ化キーの用途
出力される「ハッシュ化キー」は、メール不備の顧客が後日マイページ等でアドレスを更新した際に、「当時のエラー状態から復帰したか」をセキュアに差分検知するためのキーとして、後工程（12）で利用されます。
