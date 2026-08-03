# 概要 / Overview

システムが自動抽出した「特典の条件を確実に満たしている対象者」と、運用担当者が手動管理している「実際の配信リスト（CSV）」を突き合わせ、CSVへの登録漏れ（配信漏れ）を検知するアラート用SQLの設計例です。

以下の処理を含みます。
- 過去分・当日分それぞれの登録漏れ検知
- ハッシュキー比較によるメールアドレス更新の安全な検知（エラーからの復帰検知）
- 複数の復帰要因（出荷ステータス・入金ステータス・メールアドレス）を漏れなく文字列結合したアラート詳細の生成

Example SQL that catches gaps between the system's confirmed-eligible list and the operator's manual delivery CSV, and securely detects "recovery from error" (e.g., an email address was corrected) via salted hash-key comparison rather than comparing raw PII.

---

## データパイプライン内の位置 / Architecture Position

[10_int_predelivery_alert_check](../10_int_predelivery_alert_check/) の出力を、手動運用リストおよび配信停止台帳と突合します。

Reconciles the output of [10_int_predelivery_alert_check](../10_int_predelivery_alert_check/) against the manual operating list and the delivery-hold ledger.

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern
複合的リカバリー理由の生成とハッシュベースの安全な復帰検知
Composite Recovery-Reason Generation & Hash-Based Recovery Detection

### 課題 / Problem

システム上は条件を満たしているのに担当者のリスト更新忘れで配信漏れが発生するリスクがあります。また、一度エラーで保留された顧客が後日復帰した際、「なぜ今日になって対象に入ってきたのか」が分からないと、運用担当者が不審に感じて誤った対応をする恐れがあります。

Operator list-update oversights can cause eligible customers to be missed. When a previously-held customer recovers, without a clear reason, operators may distrust or mishandle the sudden reappearance.

### 解決策 / Solution

配信停止台帳（`map_delivery_hold_ledger`）に記録された「保留時点のスナップショット」と現在の状態を比較し、「出荷ステータスが更新されたか」「入金ステータスが更新されたか」「メールアドレスが更新されたか（ハッシュキーの不一致で検知）」を複合的に判定して、1つの文字列に結合します。片方だけが復帰した場合（例：出荷は完了したが未入金）の警告文も用意し、運用上セットで確認すべき項目の「片手落ち」を可視化しています。

By comparing the hold-time snapshot against current status across three independent dimensions (shipping, payment, email) and concatenating only the dimensions that actually changed, the query produces a precise, human-readable recovery reason — including partial-recovery warnings when only one of two related checks has cleared.

---

## 処理ステップ / Processing Steps

### 1-2. Source Retrieval
手動リストと、異常データ事前除外済みの自動抽出リストの取得。

### 3-4. Missing Detection (Past & Current)
過去・現在それぞれの登録漏れの検知。

### 5. Recovery Detection
過去に配信失敗した顧客のメールアドレス更新による復帰検知。

### 6. Alert Combination
すべての漏れ・復帰アラートの統合。

### 7. Recovery Reason Generation
配信停止リストとの突合による復帰理由の詳細付与。

### 8. Final Output Generation

---

## データ構造 / Input Data Structure

### Intermediate Tables
- `int_predelivery_alert_check` : 配信前アラート済リスト（10）

### Master / Reference Tables
- `map_gift_target_ledger` : 対象者リスト
- `stg_past_delivery_bounce` : 配信を試みた後に不達となった実績データ（配信前の事前チェックによる除外とは異なる）
- `map_delivery_hold_ledger` : 配信停止リスト（保留時点のスナップショットを保持）

---

## 運用と保守 / Operations & Maintenance

### 対応の緊急性
本クエリで出力された顧客は「条件を満たしているのにリストに入っていない人」です。早急に手動管理リストへ追加し、必要な配信処理を行ってください。

### 復帰判定のCASE文優先順位
「出荷」と「入金」はセットで確認すべき運用ルールのため、片方だけが復帰した場合の警告文も用意されています。判定ロジックを変更する際はCASE文の優先順位（WHENの順番）に注意してください。

### 拡張方法
今後もチェックルールを追加する場合は、Step 5に相当する抽出用CTEを新設し、Step 6のUNION ALLに追加するだけで拡張可能な設計になっています。
