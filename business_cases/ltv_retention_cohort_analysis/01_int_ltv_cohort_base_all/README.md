# 概要 / Overview

対象化粧品（定期購入美容液）の顧客ごとに、初回購入(F1)から4回目購入(F4)までの購入・出荷実績を1行（横持ち）に集約し、LTV分析・残存率分析の土台となるデータマートを作成するSQLの設計例です。返品も含めて「実際に何が起きたか」をそのまま記録する、実績監査モデル（全対象版）です。

以下の設計を含みます。
- 同日複数注文の合算と代表属性の伝播による、プロモコード等の混在防止
- F1時点の返品・キャンセルの厳密な除外と、F2〜F4の返品を保持したまま可視化する二層構造の返品ルール
- 前回出荷から30日経過していない顧客を評価対象から除外する「30日ルール」

Example SQL that consolidates a customer's 1st-through-4th purchase and shipment history into a single wide row as the foundation for LTV/retention analysis, preserving (rather than excluding) F2–F4 returns for audit visibility.

---

## データパイプライン内の位置 / Architecture Position

前工程のGUIパラメータ層で「対象カテゴリの商品への限定」「対象期間の開始日以降への限定」等の絞り込みが行われた`raw_order_line_ltv_base`を入力とする、本ケースの起点クエリです。本クエリの出力は、さらに後段のGUIパラメータ層で「特定プロモ・特定期間」に絞り込まれた上で[03_mart_ltv_cohort_summary_all](../03_mart_ltv_cohort_summary_all/)に接続されます。

The entry point of this case. Takes `raw_order_line_ltv_base` — pre-filtered by an upstream GUI parameter layer to the target product category and date range — as input. This query's output is further filtered by a downstream GUI parameter layer (specific promo/date-range cohort) before feeding [03_mart_ltv_cohort_summary_all](../03_mart_ltv_cohort_summary_all/).

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern

同日注文の合算整理と、返品の二層的取り扱いによる実績監査モデル
Same-Day Order Consolidation with Two-Tier Return Handling for Audit-Grade Reporting

### 課題 / Problem

1注文に複数商品が含まれたり同日に複数回注文が発生したりする実データでは、単純な行カウントでは「購入回数」を正しく数えられません。また、返品の扱いを一律に決めると、「F1時点の異常値をLTV起点から除外したい」というニーズと、「F2以降の返品実績を監査したい」というニーズを同時に満たせません。

Real order data has multiple products per order and multiple same-day orders, so naive row counting cannot correctly determine "which purchase number" a row represents. A single uniform return-handling rule also cannot satisfy both "exclude anomalies from the LTV cohort anchor (F1)" and "audit actual F2+ return volume" at the same time.

### 解決策 / Solution

同日注文を`DENSE_RANK`で1つの購入回数にまとめ、`ROW_NUMBER`で特定した「代表注文」の属性をウィンドウ関数で同日の全レコードに伝播させることで、媒体・プロモ情報の混在を防ぎます。返品については、F1確定用の`purchase_1st`では`is_return_no_refund <> 1`で厳密に除外する一方、F2〜F4集計用の`agg_base_table_filtered_purchase_1st`では返品を除外せずに集約し、`max_is_return_no_refund`として個別に出力することで、起点の健全性と実績の網羅性を両立しています。返品・キャンセルの詳細な設計思想は[返品・キャンセルの取り扱いルール](../RETURN_CANCELLATION_RULES.md)を参照してください。

Same-day orders are consolidated into a single purchase number via `DENSE_RANK`, and the attributes of a "representative order" (identified via `ROW_NUMBER`) are propagated to every same-day record via a window function, preventing media/promo attribution from mixing. For returns, `purchase_1st` (which finalizes F1) strictly excludes `is_return_no_refund = 1`, while `agg_base_table_filtered_purchase_1st` (which aggregates F2–F4) keeps returned orders and surfaces them separately as `max_is_return_no_refund` — reconciling cohort-anchor integrity with full audit visibility. See [返品・キャンセルの取り扱いルール](../RETURN_CANCELLATION_RULES.md) for the full design rationale.

---

## 処理ステップ / Processing Steps

### 1. Target Start Date Preparation
分析起点対象フラグでの初回受注日時を顧客ごとに特定。

### 2-3. Duplicate Order Cleanup
起点日時以降への絞り込みと、同日内の不要な返品レコードの除外。

### 4-5. Sequencing and Attribute Propagation
購入回数の採番、代表注文の属性伝播、2点定期フラグの生成。

### 6. Subscription Schedule Retrieval
定期契約の次回・次々回出荷予定日の取得。

### 7. F1 Aggregation
返品を厳密に除外した、クリーンな初回購入(F1)情報の集約。

### 8. F2-F4 Aggregation (Return-Inclusive)
返品を除外せず、注文単位でF2〜F4の情報を集約。

### 9. Horizontal Join
顧客マスタを主軸にF1〜F4のデータを横結合。

### 10-11. Shipment Date Backfill and Evaluation Window
未出荷分の予定日補完と、30日ルールに基づく評価対象フラグの付与。

### 12. Final Output Generation

---

## データ構造 / Input Data Structure

### Raw Tables
- `raw_order_line_ltv_base` : 受注明細（GUIパラメータ層でカテゴリ・受注期間を限定済み）

### Dimension Tables
- `dim_subscription_delivery_schedule` : 定期契約の出荷スケジュール

---

## 運用と保守 / Operations & Maintenance

### F1起点特定ロジックの変更方法
`is_cohort_anchor_target`（分析起点対象フラグ）は、SQL側では判定ロジックを持たず、前工程のGUIパラメータ層で「プロモ頭文字が対象パターンに一致 かつ 販促商品区分が対象コードに一致」のAND条件として作られています。対象コード・対象カテゴリを変更したい場合は、SQL側ではなく大元のGUIパラメータ条件を変更してください。

### 姉妹クエリとの同期
[02_int_ltv_cohort_base_no_return](../02_int_ltv_cohort_base_no_return/)は、F1起点特定ロジック（Step 1）について本クエリと同一の上流テーブルを参照する姉妹クエリです。Step 1の列定義やフラグの意味を変更する場合は、必ず両クエリを同時に確認・更新してください（片方だけの更新は、2つの版で異なるF1起点を持つコホートを生成してしまう不整合の原因になります）。

### 30日という日数の変更
`DATEADD(day, -30, ...)`の30日は、対象化粧品の「おすすめ利用周期＝1ヶ月」という業務仕様に基づく値です。変更する場合は商品担当・マーケティング担当への確認が必要です。詳細は[返品・キャンセルの取り扱いルール](../RETURN_CANCELLATION_RULES.md)を参照してください。
