# 概要 / Overview

特典対象者の「現在の定期契約状況」を取得し、「次回出荷予定日」と「次々回出荷予定日」を1行ずつ（縦持ち）に展開して出力するSQLの設計例です。過去の実績（F1, F2...）と結合できる形にすることで、「いつ特典を発送すべきか」を実績・予定の両方から判定可能にします。

以下の処理を含みます。
- 定期マスタからの将来出荷予定日の取得
- 定期ID変更（解約・再開）に耐えるフェイルセーフ結合による、F1時点属性の伝播
- 横持ちの2カラム（次回・次々回）を縦持ちにアンピボットする処理

Example SQL for retrieving a customer's future scheduled shipments and unpivoting them into individual rows, with a fail-safe join design that survives subscription-ID changes caused by cancel/restart cycles.

---

## データパイプライン内の位置 / Architecture Position

[02_stg_gift_eligible_order_confirmed](../02_stg_gift_eligible_order_confirmed/) のF1リストと、定期マスタ（`dim_subscription_status`）を結合します。

Joins the F1 list from [02_stg_gift_eligible_order_confirmed](../02_stg_gift_eligible_order_confirmed/) with the subscription master (`dim_subscription_status`).

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern
2段構えのフェイルセーフ結合とアンピボットによる未来予定の統合
Two-Tier Fail-Safe Join & Unpivot for Future Schedule Integration

### 課題 / Problem

特典条件の判定には、過去の実績だけでは「まだ出荷されていない未来の特典予定日」が分かりません。また、顧客が定期を一度解約し、別の定期ID（subsc_id）で再開した場合、単純な定期IDでの結合ではF1時点のコース属性（初回3本等）を引き継げず、判定が崩壊します。

Eligibility judgment requires future scheduled dates, not just past actuals. Additionally, when a customer cancels and restarts under a new subscription ID, a simple ID-based join fails to carry forward the F1-time course attributes.

### 解決策 / Solution

**【2段構えのフェイルセーフ結合】**
まず定期IDでの厳密な結合を試み（Step 3）、それが失敗した顧客に限定してユーザーIDのみでの救済結合を行う（Step 4）2段構えとすることで、定期IDが変わってもF1属性を確実に引き継ぎます。

**【アンピボットによる統一フォーマット化】**
`UNION ALL` を用いて、横持ちの「次回」「次々回」出荷予定日を縦持ちの1行ずつに変換。これにより、後続クエリで過去実績データと全く同じ形式で扱うことができます。

A two-tier join (strict subscription-ID match, then a user-ID fallback for unmatched rows) guarantees F1 attributes survive subscription-ID changes. Unpivoting via `UNION ALL` normalizes the future schedule into the same shape as historical actuals.

---

## 処理ステップ / Processing Steps

### 1. F1 Anchor & Course Attribute Retrieval
起点(F1)データとコース属性の取得。

### 2. Current Subscription Status Retrieval
定期マスタから継続中の次回・次々回出荷予定日を取得。

### 3. Strict Subscription-ID Join
定期IDベースの厳密な属性紐付け。

### 4. Fail-Safe User-ID Join
定期ID変更に対応したユーザーIDベースの救済紐付け。

### 5. Future Schedule Unpivot
次回・次々回出荷予定日の縦積み展開。

### 6. Final Output Generation

---

## データ構造 / Input Data Structure

### Staging Tables
- `stg_gift_eligible_order_confirmed` : 前工程（02）の出力

### Dimension Tables
- `dim_subscription_status` : 現行の定期契約ステータス（次回・次々回出荷予定日等）

---

## 運用と保守 / Operations & Maintenance

### フェイルセーフ結合の維持
Step 3・Step 4の2段構え結合ロジックは、顧客が「途中で定期を一度解約し、別の定期IDで再開した」場合でもF1時のコース属性を落とさずに引き継ぐための重要な安全装置です。パフォーマンス改善等でこの2段構えを1段に簡略化することは避けてください。
