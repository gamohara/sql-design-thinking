# 概要 / Overview

コールセンターのアウトバウンド（電話営業）によるコースアップセルに成功した顧客に対し、イレギュラーな「追加特典」を付与するための対象者抽出SQLの設計例です。

以下の処理を含みます。
- F1の重複購入履歴を時系列で比較する、本当の意味での「コース変更（アップセル・ダウンセル）」検知
- 同梱物印字履歴・CS応対メモという複数ファクトによる裏付け
- 手動対応リストとの突合による「対象漏れ」検知
- 運用ルールの歴史的変遷（発送から7日/12日/15日/30日）を反映した特典発送予定日の算出

Example SQL for identifying customers who qualify for an irregular bonus gift after a successful outbound upsell call, using time-series comparison of repeated F1 purchases to detect genuine course changes and avoid false positives from repeat buyers.

対象となるのは「初回1本→2本」コースのみです（「初回1本→3本」コースにはこのアウトバウンド運用はありません）。コース構成の全体像は、[ケース全体README「特典対象コースの詳細」](../README.md#特典対象コースの詳細--course-details)を参照してください。

This upsell flow applies only to the "1→2 bottle" course (the "1→3 bottle" course has no such outbound operation). See [the case-level README's "Course Details" section](../README.md#特典対象コースの詳細--course-details) for the full picture of both courses.

---

## データパイプライン内の位置 / Architecture Position

[01](../01_stg_gift_eligible_purchase_base/)（F1複数購入の履歴）と [05](../05_int_customer_gift_journey_timeline/)（F2実績）を参照します。

References [01](../01_stg_gift_eligible_purchase_base/) (full F1 purchase history) and [05](../05_int_customer_gift_journey_timeline/) (F2 actuals).

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern
時系列比較によるコース変更検知とアーキテクチャ依存関係
Time-Series Course-Change Detection & Upstream Architecture Dependency

### 課題 / Problem

単純に「顧客が現在2本コースのフラグを持っているか」だけを見ると、過去に買い直しでコースを変更した顧客を誤検知してしまいます。1人の顧客が何度も購入・解約を繰り返しているケースでは、「どの時点のF1で、どのコースを約束したか」を無視すると、本当のアップセル対象者を特定できません。

Simply checking whether a customer currently holds a "2-bottle course" flag misidentifies customers who changed courses through repeat purchases. Ignoring *when* each course promise was made (relative to repurchase timing) leads to incorrect eligibility.

### 解決策 / Solution

F1の各コースフラグが発生した出荷日を保持し、直近のF2出荷日（`ship_date_f1`）と比較することで、「その時点でどのコースが有効だったか」を厳密に判定します。

**★アーキテクチャ上の重要な依存関係**
本クエリの時系列比較ロジックは、上流工程（01, 02）が重複するF1データを安易に集約・削除しないことに依存しています。前工程がユーザー単位（01相当）と注文単位（02相当）に責務分割されているのは、この比較ロジックを成立させるための設計上の前提です。

By retaining the shipment date at which each course flag first occurred and comparing it against the current F2 shipment date, the query determines which course promise was in effect at that point in time — a comparison that depends on upstream queries never collapsing duplicate F1 records.

---

## 処理ステップ / Processing Steps

### 1. F2 Base Retrieval
F2（2回目）注文データの取得。

### 2. F1 Attribute History Retrieval
F1時点のコース属性データの取得（複数回購入対応）。

### 3-4. Fact Retrieval
定期継続ステータス、同梱物履歴、OB実施履歴の取得。

### 5. Course Change Detection
F1重複購入によるコース変更の検知。

### 6. Fact Aggregation & Manual List Reconciliation
ファクトの横付けと手動リストとの突合。

### 7. Final Output Generation
追加特典発送予定日の算出と最終データ生成。

---

## データ構造 / Input Data Structure

### Staging / Intermediate Tables
- `stg_gift_eligible_purchase_base` : F1複数購入履歴（01）
- `int_customer_gift_journey_timeline` : 統合ジャーニー（05）

### Dimension / Reference Tables
- `dim_subscription_status` : 現行の定期契約ステータス
- `raw_catalog_gift_markers` : 同梱物（明細書印字）データ
- `raw_cs_incident_notes` : CS応対メモ
- `map_bonus_gift_manual_targets` : 追加特典対象者リスト

---

## 運用と保守 / Operations & Maintenance

### 発送予定日の算出ルール
最終出力の「追加特典日」計算には、過去の運用ルールの変遷（7日→12日→15日→30日）がハードコードされています。今後ルールが変わる場合はここを更新してください。

### 上流の重複データ保持について
Step 5のコース変更検知は「最初のF1」と「その後の買い直しによるF1」のフラグの差分を、出荷日の前後関係を含めて厳密に比較します。前工程で重複F1データを安易に削除・集約すると、この比較ロジックが崩壊するため注意してください。
