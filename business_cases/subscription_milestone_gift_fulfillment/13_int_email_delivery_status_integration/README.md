# 概要 / Overview

デジタルギフト特典対象者のリストに対し、「特典番号付きメールが正しく配信・開封されたか」の最新ステータスを、複数のデータソースから統合・判定して出力するSQLの設計例です。

以下の処理を含みます。
- MAツールの自動行動ログと運用CSVという2つのソースの優先順位付き統合
- 再配信履歴への開封有無ステータスの付与
- 手動リストと自動判定ステータスの不一致検知（システムと人間の認識ズレ防止）

Example SQL that reconciles email delivery status from two independent sources — an MA tool's automated activity log and an operator-managed CSV — via a priority ladder, and flags mismatches between the system's computed status and the manually recorded one as a data-quality feedback loop.

---

## データパイプライン内の位置 / Architecture Position

[11_int_target_list_reconciliation](../11_int_target_list_reconciliation/) の出力を、GUIパラメータ層で「本日から10日以内」に絞り込んだ `stg_gift_target_near_term` を入力とします。

Takes as input `stg_gift_target_near_term`, a GUI parameter layer that narrows the output of [11_int_target_list_reconciliation](../11_int_target_list_reconciliation/) to the near-term window (within 10 days).

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern
複数ログソースの優先順位付き統合
Priority-Ladder Reconciliation of Multi-Source Delivery Logs

### 課題 / Problem

メール配信のログは、MAツールの自動行動ログと運用担当者が管理するCSVファイルの2箇所に分散しており、単純にどちらかを信頼すると実態と異なるステータスを採用してしまうリスクがあります。また、エラーによる「再配信」が発生した場合、初回の失敗ログだけを見ると誤った判断につながります。

Email logs are split across an automated MA-tool log and a manually managed CSV; trusting either source blindly risks an inaccurate status. Resend attempts further complicate matters — looking only at the initial failure would misrepresent the outcome.

### 解決策 / Solution

7段階の優先順位ロジック（`integrate_mail_status` のCASE文）を用いて、両ログソースの整合性パターンごとに「どちらを信頼すべきか」を判定します（例：両方が「送信済」なら開封等の詳細が分かるシステムログを優先、CSVのみが「送信済」なら手動補正とみなしてCSVを優先）。さらに、システム判定ステータスと手動CSVの表記揺れを吸収してから比較することで、不一致アラートの精度を高めています。

A 7-tier priority ladder resolves each possible agreement/disagreement pattern between the two log sources (e.g., preferring the system log's richer detail when both agree, but preferring the manually-corrected CSV when it alone shows success). Wording variations between the system's computed status and the manual CSV's free-text status are normalized before comparison to keep the mismatch alert accurate.

---

## 処理ステップ / Processing Steps

### 1. Target List Retrieval
近接期間に絞り込まれた対象者リストの取得。

### 2-4. Multi-Source Log Retrieval
MAツールログ、運用CSV、再配信リストの取得。

### 5. Resend Status Enrichment
再配信履歴への開封有無ステータスの追加。

### 6. Priority-Based Status Integration
複数ログの競合解決と最終ステータス判定。

### 7. Final Output Generation
不一致アラートの付与と最終データ生成。

---

## データ構造 / Input Data Structure

### Staging Tables
- `stg_gift_target_near_term` : 11の出力を近接期間に絞り込んだ対象者リスト（GUIパラメータ層）

### Master / Reference Tables
- `raw_mail_activity_log` : MAツールのメール行動ログ
- `map_email_delivery_log` : メール配信ログ
- `map_email_resend_log` : メール再配信ログ

---

## 運用と保守 / Operations & Maintenance

### 優先順位ロジックの変更
`integrate_mail_status` のCASE文は運用ルールに基づいた「ログの優先順位付け」を行っています。運用フロー変更（新しい配信ツールの導入等）があった場合は、この条件分岐を見直してください。

### タイムゾーンの一貫性
MAツールのログはUTCで記録されているため、`CONVERT_TIMEZONE` で日本時間に変換しています。日付ズレを防ぐための必須処理です。

### 結合キーの注意点
ログ結合では、本来の特典予定日ではなく、手動調整を加味した `digital_gift_present_date_adjusted` をキーとしています。これにより、運用側で配信日をずらした顧客のログも正確に取得できます。
