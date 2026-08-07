# 概要 / Overview

デジタルギフト特典の起点（F1）、それ以降の定期購入履歴（F2以降）、さらに未来の出荷予定日（次回・次々回）を1つのテーブルに縦結合（UNION ALL）し、顧客ごとの完全な購入ジャーニー（過去の実績〜未来の予定）を作成するSQLの設計例です。

以下の処理を含みます。
- F1が持つ「初期コースのフラグ」をF2以降の全レコードに伝播させるウィンドウ関数の活用
- 実績（出荷済み）と未来予定（定期マスタ由来）を同一タイムライン上に統合
- 同日複数注文の返品状況を踏まえた安全な代表注文の特定と属性伝播
- F1を起点とした継続回数（注文番号）の通し番号再採番

Example SQL that unions a customer's anchor purchase (F1), subsequent actuals (F2+), and future scheduled shipments into a single timeline, propagating F1-only course attributes to every row via window functions so downstream queries can evaluate eligibility from any single row.

---

## データパイプライン内の位置 / Architecture Position

[02](../02_stg_gift_eligible_order_confirmed/)（F1）・[03](../03_stg_subsequent_shipment_history/)（F2以降）・[04](../04_stg_subscription_future_schedule/)（未来予定）の3つの出力を統合する、パイプラインの中核ハブです。

The central hub of the pipeline, integrating the outputs of [02](../02_stg_gift_eligible_order_confirmed/) (F1), [03](../03_stg_subsequent_shipment_history/) (F2+), and [04](../04_stg_subscription_future_schedule/) (future schedule).

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern
属性伝播による統一タイムラインの構築
Unified Timeline Construction via Attribute Propagation

### 課題 / Problem

F2やF3の注文レコード単体を見ると「この人が初回にどのコースで始めたか」が分かりません。また、未来の特典予定を実績データと別々に扱うと、「次回出荷時に条件を満たす見込み客」の抽出が煩雑になります。同日内に複数注文が発生した場合、単純な合算では代表とすべき属性（媒体やプロモ等）が曖昧になります。

Individual F2/F3 records don't reveal which course the customer originally started under. Handling future schedules separately from actuals complicates identifying customers who will qualify on their next shipment. Same-day multiple orders also create ambiguity about which attributes should represent the day.

### 解決策 / Solution

**【属性伝播（Attribute Propagation）】**
F1のみが持つコースフラグを、`MAX() OVER(PARTITION BY user_id)` を用いて同一ユーザーの全レコード（F2以降・未来予定）にコピーします。これにより、どのレコードを見ても単独でコース条件を評価できます。

**【統一タイムライン（Unified Timeline）】**
実績（F1・F2以降）と未来予定を `UNION ALL` で縦結合し、共通のカラム構造に正規化。これにより「実績ベースか予定ベースか」を問わず同じロジックで特典タイミングを判定できます。

**【代表注文の伝播】**
同日内の複数注文を「返品状況」を踏まえて代表注文1件に絞り込み、その属性を同日内の全レコードに伝播させることで、マーケティング評価のブレを防ぎます。

By propagating F1-only attributes to every row and unifying actuals with future schedules into one timeline, downstream queries gain a single consistent data shape to evaluate gift eligibility against.

---

## 処理ステップ / Processing Steps

### 1. Source Retrieval
F1・未来予定・F2以降の各ソースの取得。

### 2. Same-Day Return Handling & Representative Order Selection
同日内の返品整理、代表注文の特定と属性伝播、1日1行化。

### 3. Timeline Union
F1・F2以降・未来予定の縦結合。

### 4. F1 Attribute Propagation
F1のコース属性を全履歴にウィンドウ関数でコピー。

### 5. Final Output Generation
継続回数（注文番号）の採番と最終データ生成。

---

## データ構造 / Input Data Structure

### Staging Tables
- `stg_gift_eligible_order_confirmed` : F1確定リスト（02）
- `stg_subsequent_shipment_history` : F2以降の実績（03）
- `stg_subscription_future_schedule` : 未来の出荷予定（04）

---

## 運用と保守 / Operations & Maintenance

### 注文番号の解釈について
最終出力の「注文番号」は、F1から始まる完全な連番（1, 2, 3...）です。この中には「実績」と「未来の予定」の連番が混在しているため、判定時は `order_type`（`F1_出荷` / `F2以降_出荷` / `定期_出荷予定`）で区別してください。

### 属性伝播ロジックの前提
Step 4の属性伝播は「F1のレコードだけがコースフラグ(1)を持っている」ことを前提としたスマートな設計です。上流でF1判定のロジックが変わる場合、この前提が崩れないか確認してください。
