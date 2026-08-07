# 概要 / Overview

F1〜F4横持ち受注データ（特定プロモ・特定期間かつ返品考慮モデルに限定済み）と広告のアクセスデータ（クリック・CV）を結合し、「月別」「取引先別」「コード別」など様々な粒度でRollup（小計・合計）したダッシュボード表示用サマリーマートを作成するSQLの設計例です（F2〜返品考慮版）。

以下の高度な設計を含みます。
- [03_mart_ltv_cohort_summary_all](../03_mart_ltv_cohort_summary_all/)と共通のGROUPING SETS設計・JOIN爆発防止パターンを、返品考慮モデルの入力に適用
- 再帰CTEによるゼロ埋めカレンダー
- スプレッドシートへの「ベタ貼り」運用に対応した、表示ブロック順の絶対制御

Example SQL that applies the same `GROUPING SETS` rollup design and cross-join guarding as its sibling mart, but sourced from the return-excluded F2+ cohort instead of the all-targets cohort.

---

## データパイプライン内の位置 / Architecture Position

[02_int_ltv_cohort_base_no_return](../02_int_ltv_cohort_base_no_return/)の出力を、前工程のGUIパラメータ層で「1回目の受注プロモが対象パターンに一致 かつ 1回目の受注日が指定期間内」に絞り込んだ`stg_ltv_cohort_target_period_no_return`を入力とする、本ケースの最終分析レイヤーです。

Takes `stg_ltv_cohort_target_period_no_return` — a GUI parameter layer that filters the output of [02_int_ltv_cohort_base_no_return](../02_int_ltv_cohort_base_no_return/) to "1st-purchase promo matches the target pattern AND 1st-purchase date falls within a specific window" — as input. This is the final analytical layer of this case's return-excluded branch.

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern

ディメンション整合GROUPING SETSによる多重粒度ロールアップとJOIN爆発防止
Dimension-Aligned Multi-Grain Rollup via GROUPING SETS with Cross-Join Guarding

### 課題 / Problem

[03_mart_ltv_cohort_summary_all](../03_mart_ltv_cohort_summary_all/)と同様、BIツール側で複数粒度の集計・条件分岐を行わせると描画パフォーマンスが低下し、受注側とアクセス側の集計を後から結合する設計は結合キーの粒度が両側でズレるとクロス結合を起こしやすいという課題があります。本クエリはさらに、入力元が「返品を除外して繰り上げ再採番したF2〜F4」であるため、集計結果が[03](../03_mart_ltv_cohort_summary_all/)とは異なる母集団・回数構成になる点にも注意が必要です。

As with [03_mart_ltv_cohort_summary_all](../03_mart_ltv_cohort_summary_all/), letting the BI tool compute multiple rollup granularities hurts performance, and joining order-side and access-side aggregates after the fact is fragile against granularity drift. This query additionally draws from a return-excluded, re-sequenced F2–F4 population, so its results represent a different cohort composition than [03](../03_mart_ltv_cohort_summary_all/) even for the same customers.

### 解決策 / Solution

[03_mart_ltv_cohort_summary_all](../03_mart_ltv_cohort_summary_all/)と全く同じ設計（`GROUPING SETS`による6パターン一括集計、オファー／LP種別／媒体詳細を共通ディメンションとした7項目キーでのJOIN）を採用しています。両クエリはJOIN条件の構造を完全に共有しているため、片方の集計側（Step 4, Step 7）にディメンションを追加する際は、必ずもう一方のクエリも同時に確認・更新してください。

This query adopts the exact same design as [03_mart_ltv_cohort_summary_all](../03_mart_ltv_cohort_summary_all/) — a single-pass 6-pattern `GROUPING SETS` rollup joined on the same 7-key dimension set (offer / LP type / media detail). Because both queries share this join structure verbatim, any dimension added to one query's aggregation steps (Step 4, Step 7) must be mirrored in the other.

---

## 処理ステップ / Processing Steps

### 1. Base Metrics Extraction
対象期間限定済みの横持ちテーブル（返品考慮版）から受注・LTV指標を取得し、コース別・回数別にフラグを数値化。

### 2. Date Range Extraction
受注データの最古・最新受注日を取得（アクセスデータ絞り込みの基準値）。

### 3. Click/CV Metrics Extraction
広告アクセスデータを対象期間内に限定して取得し、受注側と同一のディメンション粒度に揃える。

### 4. Order Rollup (GROUPING SETS)
受注データを6パターンの粒度に集計。

### 5-6. Zero-Fill Calendar Application
再帰CTEで月軸を生成し、受注のない月もゼロ埋めで補完。

### 7. Click/CV Rollup (GROUPING SETS)
アクセスデータを受注側と同一のディメンション構成で集計。

### 8. Order/Access Integration
受注集計とアクセス集計を、7項目のキーを揃えて結合。

### 9-10. Report Block Arrangement
小計行の複製とブロック順（コード別→取引先別→合計）の絶対制御。

### 11. Final Output Generation

---

## データ構造 / Input Data Structure

### Staging Tables
- `stg_ltv_cohort_target_period_no_return` : [02](../02_int_ltv_cohort_base_no_return/)の出力を特定プロモ・特定期間に限定したもの（GUIパラメータ層）

### Raw Tables
- `raw_ad_click_cv_log` : 広告クリック・CV結果ログ（[03](../03_mart_ltv_cohort_summary_all/)と共通）

---

## 運用と保守 / Operations & Maintenance

### ★絶対に触ってはいけない箇所：`integrate_orders_and_clicks_cvs`のJOIN条件
[03_mart_ltv_cohort_summary_all](../03_mart_ltv_cohort_summary_all/)と同一の設計・同一の注意事項が適用されます。月なし系（f）・月あり系（g）のいずれのJOINも、コード・取引先・オファー・FV・BOT・アップセル・媒体詳細の7項目すべてを結合条件に含める必要があります。過去にこのキー構成が片側だけ更新され、クロス結合による実績値の増殖という重大な障害が発生しています。詳細は[03のREADME](../03_mart_ltv_cohort_summary_all/README.md#運用と保守--operations--maintenance)を参照してください。

### 「対象区分」列の意味
本クエリの最終出力では「対象区分」列に固定値`返品除外`を出力しています（[03](../03_mart_ltv_cohort_summary_all/)では`全対象`）。2つのマートの出力を`UNION ALL`等で結合してダッシュボードに投入する運用を想定した識別子です。

### 対象母集団の変更方法
本クエリの対象母集団は、前工程のGUIパラメータ層（`stg_ltv_cohort_target_period_no_return`）により「特定プロモ かつ 特定期間の初回受注」に限定されています。対象条件を変更したい場合は、SQL側ではなく大元のGUIパラメータ条件を変更してください。
