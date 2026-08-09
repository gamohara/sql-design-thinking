# 概要 / Overview

F1〜F4横持ち受注データ（特定プロモ・特定期間に限定済み）と広告のアクセスデータ（クリック・CV）を結合し、「月別」「取引先別」「コード別」など様々な粒度でRollup（小計・合計）したダッシュボード表示用サマリーマートを作成するSQLの設計例です（全対象版）。

以下の高度な設計を含みます。
- 再帰CTEによるゼロ埋めカレンダー（受注実績がない月も「0」として表示）
- GROUPING SETSによる6パターン粒度の一括集計と、ディメンションキーを揃えたクロス結合防止JOIN
- スプレッドシートへの「ベタ貼り」運用に対応した、表示ブロック順の絶対制御

Example SQL that unifies order-based F1–F4 metrics with ad click/CV data across six rollup granularities in a single pass using `GROUPING SETS`, guarding the join between order and access aggregates against a cross-join explosion.

---

## データパイプライン内の位置 / Architecture Position

[01_int_ltv_cohort_base](../01_int_ltv_cohort_base/)の出力を、前工程のGUIパラメータ層で「1回目の受注プロモが対象パターンに一致 かつ 1回目の受注日が指定期間内」に絞り込んだ`stg_ltv_cohort_target_period`を入力とする、本ケースの最終分析レイヤーです。

Takes `stg_ltv_cohort_target_period` — a GUI parameter layer that filters the output of [01_int_ltv_cohort_base](../01_int_ltv_cohort_base/) to "1st-purchase promo matches the target pattern AND 1st-purchase date falls within a specific window" — as input. This is the final analytical layer of this case.

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern

ディメンション整合GROUPING SETSによる多重粒度ロールアップとJOIN爆発防止
Dimension-Aligned Multi-Grain Rollup via GROUPING SETS with Cross-Join Guarding

### 課題 / Problem

BIツール側で「月別」「取引先別」「コード別」など複数粒度の集計・条件分岐を行わせると、描画パフォーマンスが著しく低下します。また、受注側の集計とアクセス側（クリック・CV）の集計を後から結合する設計では、結合キーの粒度が両側でわずかにズレただけで、同一グループ内の行同士がクロス結合し、実績値（クリック数等）が本来の値の何倍にも増殖するという致命的なバグを起こしやすい構造になっています。

Letting the BI tool compute multiple rollup granularities and branch on them tanks rendering performance. Additionally, a design that joins order-side and access-side (click/CV) aggregates after the fact is fragile: if the join key's dimensional granularity drifts even slightly between the two sides, rows within the same group cross-join, multiplying metrics like click counts far beyond their true value.

### 解決策 / Solution

SQL側で`GROUPING SETS`を用いて「月/コード別」「取引先別」「全体合計」など6パターンの集計をUNION ALLなしの1パスで生成し、BIツールは「表示するだけ」の状態に仕上げます。受注側・アクセス側それぞれのGROUPING SETSに「オファー／LP種別（FV・BOT・アップセル）／媒体詳細」を共通ディメンションとして組み込み、統合ステップ（`integrate_orders_and_clicks_cvs`）のJOIN条件でも両者を完全に同じ7項目のキー構成で突き合わせることで、クロス結合を構造的に防止しています。過去にこのキー構成が片側だけ更新され、実際に重大な障害が発生したことがあります（詳細は下記「運用と保守」を参照）。

`GROUPING SETS` generates all six rollup patterns (e.g. "month × code," "vendor," "grand total") in a single pass without `UNION ALL`, leaving the BI tool to simply render the result. Both the order-side and access-side `GROUPING SETS` share the same dimensions (offer / LP type [FV/BOT/upsell] / media detail), and the integration step's join condition (`integrate_orders_and_clicks_cvs`) matches on the exact same 7-key combination on both sides — structurally preventing the cross-join explosion. This key set has previously drifted on one side only, causing a real production incident (see "Operations & Maintenance" below).

---

## 処理ステップ / Processing Steps

### 1. Base Metrics Extraction
対象期間限定済みの横持ちテーブルから受注・LTV指標を取得し、コース別・回数別にフラグを数値化。

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
- `stg_ltv_cohort_target_period` : [01](../01_int_ltv_cohort_base/)の出力を特定プロモ・特定期間に限定したもの（GUIパラメータ層）

### Raw Tables
- `raw_ad_click_cv_log` : 広告クリック・CV結果ログ

---

## 返品考慮版にする場合 / Building the Return-Excluded Variant

本クエリは、上流の[01_int_ltv_cohort_base](../01_int_ltv_cohort_base/)が全対象版（返品を含めた実績監査モデル）であることを前提に、その出力をそのまま集計しています。返品考慮版のサマリーを作りたい場合、本クエリ自体の集計ロジック（GROUPING SETS・JOIN構成）は一切変更する必要がありません。変更が必要なのは入力元と最終出力の識別ラベルのみです。

### a) 変更箇所と条件

Step 1（`extract_base_metrics_from_f1_to_f4`）のFROM句を、以下のように差し替えます。

```sql
FROM
    -- 変更前: 01を全対象版のまま通したGUIパラメータ層の出力
    -- stg_ltv_cohort_target_period

    -- 変更後: 01を返品考慮版（README「返品考慮版にする場合」参照）に差し替えた上で、
    --         同じGUIパラメータ条件（対象プロモ・対象期間）を通した出力
    stg_ltv_cohort_target_period_no_return
```

あわせて、最終出力（Step 11）の固定リテラルを変更します。

```sql
SELECT
    '全対象'    AS "対象区分",   -- 変更前
    -- '返品除外' AS "対象区分",   -- 変更後
    ...
```

### b) 通常版（全対象版）との違い

集計ロジック自体は同一のため、行や列の構造に違いは生じません。違いが出るのは、入力元となる横持ちデータの中身です。[01のREADME](../01_int_ltv_cohort_base/README.md#返品考慮版にする場合--building-the-return-excluded-variant)で説明している通り、返品考慮版ではF2〜F4の返品済み注文が除外され、後続の正常注文が繰り上がって集計対象になります。そのため「獲得件数」「複数定期件数」「◯回目_継続数」等の実数値が、全対象版よりも小さく（または回によっては配分が変わって）出力される可能性があります。

### c) 分析上の効果

返品による水増しを含んだまま月次・取引先別・コード別の実績を集計してしまうと、施策やベンダーの評価が実態より良く（あるいは物流トラブルの多いベンダーが実態より悪く）見えるリスクがあります。返品考慮版に切り替えることで、返品ノイズを除いた「本当のリピート実績」に基づいて媒体・取引先ごとの費用対効果（CPA等）を評価できます。一方、全対象版は返品も含めた総受注ベースの実績を追いたい場合や、物流実態の監査に適しています。

---

## 運用と保守 / Operations & Maintenance

### ★絶対に触ってはいけない箇所：`integrate_orders_and_clicks_cvs`のJOIN条件
月なし系（f: コード別／取引先別／合計）・月あり系（g: 月/コード別／月/取引先別／月小計）のいずれのJOINも、コード・取引先・オファー・FV・BOT・アップセル・媒体詳細の7項目すべてを`COALESCE(..., '-') = COALESCE(..., '-')`の形で結合条件に含める必要があります。

**過去の障害実績**: 受注側・アクセス側のGROUPING SETSに新しいディメンション（オファー等）を追加した際、f側（月なし系）の結合条件にはキーを追加したものの、g側（月あり系）への反映が漏れていました。その結果、「月/取引先別」の行が同一取引先内の全オファー・LP種別の組み合わせに対してクロス結合し、クリック数が他媒体の値も巻き込んで実際の数倍に増殖する重大バグが発生しました。今後、集計側（Step 4, Step 7）のGROUPING SETSにディメンションを追加する際は、必ずStep 8のf・g両方の結合条件に同じキーを反映してください。

### GROUPING SETSの「月のみ」「全体合計」タプルにディメンションを含めない理由
`agg_clicks_cvs_by_grouping_sets`のGROUPING SETSでは、月単独の集計`(ordered_month)`と全体合計`()`のタプルには、あえてオファー等の詳細ディメンションを含めていません。ここに詳細ディメンションを含めてしまうと「月小計」「合計」としての集計粒度が崩れるため、変更しないでください。

### 対象母集団の変更方法
本クエリの対象母集団は、前工程のGUIパラメータ層（`stg_ltv_cohort_target_period`）により「特定プロモ かつ 特定期間の初回受注」に限定されています。対象条件（期間や媒体条件）を変更したい場合は、SQL側ではなく大元のGUIパラメータ条件を変更してください。母集団が変わると本クエリの全ての集計結果に影響します。
