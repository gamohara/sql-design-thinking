# 概要 / Overview

これまで作成した各データマートから、「人間による目視確認やイレギュラー対応が必要な注文（アラート）」のみを抽出し、1つのテーブルに統合して出力する品質モニタリング用SQLの設計例です。

以下の7種類のアラートを一元的に検知します。
1. 返品チェック（事後返品の悪質性判断・進行中の返品可能性）
2. 重複注文チェック
3. DM履歴なしチェック
4. 追加特典対象漏れチェック
5. 定期即解約チェック
6. 短期間発送チェック
7. 停止リストからの回復検知

Example SQL that consolidates every alert requiring human judgment across the entire pipeline into a single prioritized To-Do list, covering seven distinct check categories from post-gift-return abuse to recovery-from-hold detection.

---

## データパイプライン内の位置 / Architecture Position

パイプライン内の複数の中間・監査テーブル（02, 06, 09, 12）からアラートを集約します。

Aggregates alerts from multiple intermediate/audit tables across the pipeline (02, 06, 09, 12).

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern
拡張可能なアラート集約と責務分離されたミュート機能
Extensible Alert Aggregation with Separated Mute Responsibility

### 課題 / Problem

各種アラートが複数のテーブルに散らばっていると検知が遅れます。また、「運用担当者が確認済みのアラートを非表示にする（ミュート）」処理を同一クエリに含めると、アラート発生件数の推移（KPI）をそのまま追跡できなくなります。

Scattering alerts across many tables delays detection. Bundling "mute reviewed alerts" logic into the same query as raw fact aggregation would corrupt the alert-volume trend as a clean KPI.

### 解決策 / Solution

**【拡張可能な設計】**
新しいチェック項目を追加する場合は、抽出用のCTE（`alert_xxx`）を新設し、`combine_all_alerts` のUNION ALLに追加するだけで拡張できる設計にしています。

**【責務の分離】**
本クエリは「システム上で発生した生のアラート事実（Fact）」の集約に特化し、確認済みデータのミュート処理は次工程（20）に委譲しています。これにより本クエリの出力は「アラート発生件数の純粋な推移」としても活用可能です。

**【優先度に基づくカスタムソート】**
最もROIを悪化させる「悪質」フラグの顧客を`CASE`文で最優先に引き上げ、続いて対応期限（プレゼント予定日）が近い順にソートすることで、目視で最も緊急な対応から確認できます。

New check rules can be added by creating a new `alert_xxx` CTE and appending it to the `UNION ALL`. By deferring the mute logic to the next query, this query's output remains a clean, trackable fact stream. A custom sort surfaces the highest-risk "abuse" alerts first, then orders by delivery-deadline urgency.

---

## 処理ステップ / Processing Steps

### 1-7. Individual Alert Extraction
各データマートから、特定のアラート条件を満たすレコードの抽出。

### 8. Combine
各アラートをUNION ALLで縦に積み上げ。

### 9. Mute Flag Assignment
運用担当者が確認済み（残留指定）の注文にフラグを設定。

### 10. Final Output Generation
優先度・緊急度順のソートと出力。

---

## データ構造 / Input Data Structure

### Staging / Intermediate / Audit Tables
- `stg_gift_eligible_order_confirmed` : 重複・DM履歴チェック元（02）
- `int_bonus_gift_upsell_detection` : 追加特典対象漏れチェック元（06）
- `int_fraud_risk_detection` : 返品・即解約・短期出荷チェック元（09）
- `audit_missing_target_detection` : 回復検知チェック元（12）

### Master Tables
- `map_gift_manual_exceptions` : 手動対応リスト（`exception_type = 'PERSIST_BY_ORDER'`）

---

## 運用と保守 / Operations & Maintenance

### 新しいアラートルールの追加方法
抽出用のCTEを新設し、Step 8のUNION ALLに追加するだけで拡張可能です。`check_category`には「①」「②」などの番号を振ることで、最終出力のORDER BYでチェック内容ごとにまとめられます。

### DM履歴なしチェックのタイムラグバッファ
Step 3では `ship_date < 今日 - 5日` という条件を加えています。これは未来の出荷予定データやシステム連携のタイムラグが不要なエラーとして検知されるのを防ぐための処置です。
