# 概要 / Overview

対象化粧品（定期購入美容液）の顧客ごとに、初回購入(F1)から4回目購入(F4)までの購入・出荷実績を1行（横持ち）に集約し、LTV分析・残存率分析の土台となるデータマートを作成するSQLの設計例です。F2以降で発生した返品を完全に除外し、残った正常な注文だけを繰り上げて再採番する、純粋なLTV・残存率モデル（F2〜返品考慮版）です。

以下の設計を含みます。
- [01_int_ltv_cohort_base_all](../01_int_ltv_cohort_base_all/)と同一のF1確定ロジックを共有する姉妹クエリ設計
- F2以降の返品注文を除外し、残った注文を`DENSE_RANK`で前に詰めて再採番する仕組み
- 前回出荷から30日経過していない顧客を評価対象から除外する「30日ルール」

Example SQL that builds the same horizontal F1–F4 mart as its sibling query, but fully excludes returned F2+ orders and re-numbers the remaining valid orders, producing a "pure" repeat-rate model unaffected by return noise.

---

## データパイプライン内の位置 / Architecture Position

[01_int_ltv_cohort_base_all](../01_int_ltv_cohort_base_all/)と同一の`raw_order_line_ltv_base`を入力とする姉妹クエリです。本クエリの出力は、さらに後段のGUIパラメータ層で「特定プロモ・特定期間」に絞り込まれた上で[04_mart_ltv_cohort_summary_no_return](../04_mart_ltv_cohort_summary_no_return/)に接続されます。

A sibling query to [01_int_ltv_cohort_base_all](../01_int_ltv_cohort_base_all/), sharing the same `raw_order_line_ltv_base` input. This query's output is further filtered by a downstream GUI parameter layer (specific promo/date-range cohort) before feeding [04_mart_ltv_cohort_summary_no_return](../04_mart_ltv_cohort_summary_no_return/).

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern

返品除外後の再採番による「歯抜けのないリピート順」の再構築
Return-Exclusion with Re-Sequencing to Reconstruct a Gap-Free Repeat Order

### 課題 / Problem

F2〜F4の中に返品された注文が混在したまま「2回目」「3回目」と数えてしまうと、返品分がリピート実績として集計されてしまい、残存率・LTVの数値が実態より良く見えてしまいます。一方で、単純に返品注文を除外するだけだと、残った注文の順序に「歯抜け」（1回目・4回目のみ、など）が生じ、後続の横持ち結合（F2列にF4の注文が入らない）が破綻します。

If returned F2–F4 orders are counted as-is toward "2nd purchase," "3rd purchase," etc., return volume inflates repeat-rate and LTV metrics. But naively excluding returned orders leaves gaps in the sequence (e.g. only 1st and 4th remain), which breaks the downstream horizontal join (an order that was actually the 4th would never land in the "2nd" column).

### 解決策 / Solution

`extract_valid_orders_after_f1`で`is_return_no_refund <> 1`の注文のみを抽出した上で、`DENSE_RANK() OVER(PARTITION BY user_id ORDER BY ordered_date ASC) + 1`により、残った有効な注文だけで「歯抜けのない」新しい購入回数（`order_no_from_f2`）を振り直します。これにより、返品によって欠番になった回数を後続の正常注文が自動的に繰り上げて埋める、純粋なリピート順序が再構築されます。返品・キャンセルの詳細な設計思想、および全対象版との具体的な差異は[返品・キャンセルの取り扱いルール](../RETURN_CANCELLATION_RULES.md)を参照してください。

`extract_valid_orders_after_f1` first keeps only orders where `is_return_no_refund <> 1`, then re-numbers the remaining valid orders via `DENSE_RANK() OVER(PARTITION BY user_id ORDER BY ordered_date ASC) + 1` into a new, gap-free purchase number (`order_no_from_f2`). The next valid order automatically shifts up to fill the slot a returned order vacated, reconstructing a pure repeat sequence. See [返品・キャンセルの取り扱いルール](../RETURN_CANCELLATION_RULES.md) for the full design rationale and how this differs from the all-targets variant.

---

## 処理ステップ / Processing Steps

### 1. Target Start Date Preparation
分析起点対象フラグでの初回受注日時を顧客ごとに特定（[01](../01_int_ltv_cohort_base_all/)と同一ロジック）。

### 2-3. Duplicate Order Cleanup
起点日時以降への絞り込みと、同日内の不要な返品レコードの除外。

### 4-5. Sequencing and Attribute Propagation
購入回数の採番、代表注文の属性伝播、2点定期フラグの生成。

### 6. Subscription Schedule Retrieval
定期契約の次回・次々回出荷予定日の取得。

### 7. F1 Aggregation
返品を厳密に除外した、クリーンな初回購入(F1)情報の集約。

### 8. Return Exclusion and Re-Sequencing
F2以降の返品注文を完全に除外し、残った正常な注文だけを前に詰めて再採番。

### 9. Valid-Order Aggregation
再採番したF2以降の有効な購入情報を注文単位で集約。

### 10. Horizontal Join
顧客マスタを主軸にF1〜F4のデータを横結合。

### 11-12. Shipment Date Backfill and Evaluation Window
未出荷分の予定日補完と、30日ルールに基づく評価対象フラグの付与。

### 13. Final Output Generation

---

## データ構造 / Input Data Structure

### Raw Tables
- `raw_order_line_ltv_base` : 受注明細（GUIパラメータ層でカテゴリ・受注期間を限定済み。[01](../01_int_ltv_cohort_base_all/)と共通）

### Dimension Tables
- `dim_subscription_delivery_schedule` : 定期契約の出荷スケジュール

---

## 運用と保守 / Operations & Maintenance

### 姉妹クエリとの同期
本クエリのStep 1（F1起点特定ロジック）は、[01_int_ltv_cohort_base_all](../01_int_ltv_cohort_base_all/)と完全に同一の上流テーブル・列定義を参照します。Step 1を変更する際は、必ず両クエリを同時に確認・更新してください。片方だけを更新すると、全対象版と返品考慮版の間でF1起点が食い違うコホートを生成してしまいます。

### 出力に返品フラグ（F2〜F4）が存在しない理由
本クエリの最終出力には、[01](../01_int_ltv_cohort_base_all/)にある「2回目_返品(保証除く)フラグ」等のF2〜F4向け返品フラグ列が存在しません。これは仕様漏れではなく、Step 8で返品済みのF2〜F4注文をあらかじめ完全に除外しているため、返品フラグを持つレコードがそもそも存在しないことによる意図的な省略です。返品実績を確認したい場合は[01_int_ltv_cohort_base_all](../01_int_ltv_cohort_base_all/)を参照してください。

### 30日という日数の変更
`DATEADD(day, -30, ...)`の30日は、対象化粧品の「おすすめ利用周期＝1ヶ月」という業務仕様に基づく値です。変更する場合は商品担当・マーケティング担当への確認が必要です。詳細は[返品・キャンセルの取り扱いルール](../RETURN_CANCELLATION_RULES.md)を参照してください。
