# 概要 / Overview

対象品（定期購入美容液）の顧客ごとに、初回購入(F1)から4回目購入(F4)までの購入・出荷実績を1行（横持ち）に集約し、LTV分析・残存率分析の土台となるデータマートを作成するSQLの設計例です。返品も含めて「実際に何が起きたか」をそのまま記録する、実績監査モデル（全対象版）です。

以下の設計を含みます。
- 同日複数注文の合算と代表属性の伝播による、プロモコード等の混在防止
- F1時点の返品・キャンセルの厳密な除外と、F2〜F4の返品を保持したまま可視化する二層構造の返品ルール
- 前回出荷から30日経過していない顧客を評価対象から除外する「30日ルール」

Example SQL that consolidates a customer's 1st-through-4th purchase and shipment history into a single wide row as the foundation for LTV/retention analysis, preserving (rather than excluding) F2–F4 returns for audit visibility.

---

## データパイプライン内の位置 / Architecture Position

前工程のGUIパラメータ層で「対象カテゴリの商品への限定」「対象期間の開始日以降への限定」等の絞り込みが行われた`raw_order_line_ltv_base`を入力とする、本ケースの起点クエリです。本クエリの出力は、さらに後段のGUIパラメータ層で「特定プロモ・特定期間」に絞り込まれた上で[02_mart_ltv_cohort_summary](../02_mart_ltv_cohort_summary/)に接続されます。

The entry point of this case. Takes `raw_order_line_ltv_base` — pre-filtered by an upstream GUI parameter layer to the target product category and date range — as input. This query's output is further filtered by a downstream GUI parameter layer (specific promo/date-range cohort) before feeding [02_mart_ltv_cohort_summary](../02_mart_ltv_cohort_summary/).

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern

同日注文の合算整理と、返品の二層的取り扱いによる実績監査モデル
Same-Day Order Consolidation with Two-Tier Return Handling for Audit-Grade Reporting

### 課題 / Problem

1注文に複数商品が含まれたり同日に複数回注文が発生したりする実データでは、単純な行カウントでは「購入回数」を正しく数えられません。また、返品の扱いを一律に決めると、「F1時点の異常値をLTV起点から除外したい」というニーズと、「F2以降の返品実績を監査したい」というニーズを同時に満たせません。

Real order data has multiple products per order and multiple same-day orders, so naive row counting cannot correctly determine "which purchase number" a row represents. A single uniform return-handling rule also cannot satisfy both "exclude anomalies from the LTV cohort anchor (F1)" and "audit actual F2+ return volume" at the same time.

### 解決策 / Solution

同日注文を`DENSE_RANK`で1つの購入回数にまとめ、`ROW_NUMBER`で特定した「代表注文」の属性をウィンドウ関数で同日の全レコードに伝播させることで、媒体・プロモ情報の混在を防ぎます。返品については、F1確定用の`purchase_1st`では`is_return_no_refund <> 1`で厳密に除外する一方、F2〜F4集計用の`agg_base_table_filtered_purchase_1st`では返品を除外せずに集約し、`max_is_return_no_refund`として個別に出力することで、起点の健全性と実績の網羅性を両立しています。返品・キャンセルの詳細な設計思想は[ケース全体README](../README.md#返品キャンセルの取り扱いと30日ルール--return-cancellation-handling--the-30-day-rule)を参照してください。

Same-day orders are consolidated into a single purchase number via `DENSE_RANK`, and the attributes of a "representative order" (identified via `ROW_NUMBER`) are propagated to every same-day record via a window function, preventing media/promo attribution from mixing. For returns, `purchase_1st` (which finalizes F1) strictly excludes `is_return_no_refund = 1`, while `agg_base_table_filtered_purchase_1st` (which aggregates F2–F4) keeps returned orders and surfaces them separately as `max_is_return_no_refund` — reconciling cohort-anchor integrity with full audit visibility. See the [case-level README](../README.md#返品キャンセルの取り扱いと30日ルール--return-cancellation-handling--the-30-day-rule) for the full design rationale.

---

## 処理ステップ / Processing Steps

### 1. Target Start Date Preparation
分析起点対象フラグでの初回受注日時を顧客ごとに特定。

### 2-3. Duplicate Order Cleanup
起点日時以降への絞り込みと、同日内の不要な返品レコードの除外。

### 4-5. Sequencing and Attribute Propagation
購入回数の採番、代表注文の属性伝播、複数点定期フラグの生成。

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

## 返品考慮版にする場合 / Building the Return-Excluded Variant

本クエリは「返品も含めて実際に何が起きたかをそのまま記録する」実績監査モデル（全対象版）です。これに対し、「返品ノイズを除いた本当のリピート顧客だけ」を見たい場合は、以下の変更で返品考慮版（F2〜返品考慮モデル）に切り替えられます。

### a) 変更箇所と条件

Step 8（`agg_base_table_filtered_purchase_1st`）を、以下の2段階のCTEに差し替えます。

**変更前（全対象版・本クエリの実装）**
```sql
agg_base_table_filtered_purchase_1st AS (
    SELECT
        c.user_id,
        c.order_no,                                   -- Step 4で採番した「返品込みの」通し番号をそのまま使う
        MAX(c.daily_rep_order_type)                   AS agg_order_type,
        -- ... (集計列は同じ)
        MAX(c.is_return_no_refund)                    AS max_is_return_no_refund  -- 返品も残して監査用に出力
    FROM
        prepare_f1_aggregation c
    INNER JOIN
        purchase_1st d
    ON c.user_id = d.user_id
    GROUP BY
        c.user_id, c.order_no
)
```

**変更後（返品考慮版）**
```sql
extract_valid_orders_after_f1 AS (
    -- ★返品(is_return_no_refund = 1)を完全に除外した上で、
    --   残った有効な注文だけを前に詰めて再採番する
    SELECT
        c.user_id,
        DENSE_RANK() OVER(
            PARTITION BY c.user_id
            ORDER BY c.ordered_date ASC
        ) + 1 AS order_no_from_f2,                    -- 「歯抜けのない」新しい購入回数
        c.daily_rep_order_type,
        c.daily_rep_payment_method,
        c.ordered_date,
        c.shipment_date,
        c.quantity,
        c.discounted_amount_excl_point_excl_tax,
        c.is_subsc
    FROM
        prepare_f1_aggregation c
    INNER JOIN
        purchase_1st d
    ON c.user_id = d.user_id
    WHERE
        c.ordered_date > d.max_ordered_date
      AND c.is_return_no_refund <> 1                  -- ★F2以降の返品を完全に除外
),

agg_valid_orders_after_f1 AS (
    SELECT
        user_id,
        order_no_from_f2,
        MAX(order_no_from_f2) OVER(PARTITION BY user_id) AS order_count_from_f2,
        MAX(daily_rep_order_type)                        AS agg_order_type,
        MAX(daily_rep_payment_method)                    AS agg_payment_method,
        MAX(ordered_date)                                AS max_ordered_date,
        MAX(shipment_date)                                AS max_shipment_date,
        SUM(quantity)                                    AS total_quantity,
        SUM(discounted_amount_excl_point_excl_tax)       AS total_discounted_amount_excl_point_excl_tax,
        MAX(is_subsc)                                    AS max_is_subsc
    FROM
        extract_valid_orders_after_f1
    GROUP BY
        user_id, order_no_from_f2
)
```

あわせて、Step 9（`user_table_with_purchase_from_1st_to_4th`）のF2/F3/F4結合条件を、`agg_base_table_filtered_purchase_1st` × `order_no = 2/3/4` から `agg_valid_orders_after_f1` × `order_no_from_f2 = 2/3/4` に変更し、Step 12の最終出力から「2回目_返品(保証除く)フラグ」「3回目_返品(保証除く)フラグ」「4回目_返品(保証除く)フラグ」（F1分は残す）を削除します。

### b) 通常版（全対象版）との違い

例えば「F1正常購入 → F2正常購入 → F3が返品(保証除く) → F4正常購入」という顧客がいた場合、

| | 全対象版（本クエリ） | 返品考慮版 |
|---|---|---|
| F1〜F4の行数 | 4回分すべてを記録 | F3が除外され3回分のみ |
| F3の扱い | `order_no = 3` として結合し、返品フラグ=1を出力 | 存在しない（除外済み） |
| 元F4の扱い | `order_no = 4` として4回目に結合 | `order_no_from_f2 = 3` として繰り上がり、**3回目として**結合される |
| 返品フラグ列 | F2〜F4に出力あり | 出力なし（F2〜F4に返品データが存在しないため） |

つまり、両者の同じ顧客の「3回目」「4回目」の中身が食い違うことがある点に注意が必要です。

### c) 分析上の効果

返品考慮版に切り替えることで、返品による「歯抜け」を含んだまま集計してしまうことによる残存率・LTVの見かけ上の変動を排除し、「本当に継続してくれた顧客だけ」を対象にした純粋なリピート率・LTVを算出できます。一方、全対象版は返品も除外せず記録するため、実際の物流・返品発生状況を監査したい場合や、返品を含めた総受注ベースでビジネスの実態を把握したい場合に適しています。使い分けの詳細は[ケース全体README](../README.md#返品キャンセルの取り扱いと30日ルール--return-cancellation-handling--the-30-day-rule)を参照してください。

---

## 運用と保守 / Operations & Maintenance

### F1起点特定ロジックの変更方法
`is_cohort_anchor_target`（分析起点対象フラグ）は、SQL側では判定ロジックを持たず、前工程のGUIパラメータ層で「プロモ頭文字が対象パターンに一致 かつ 販促商品区分が対象コードに一致」のAND条件として作られています。対象コード・対象カテゴリを変更したい場合は、SQL側ではなく大元のGUIパラメータ条件を変更してください。

### 30日という日数の変更
`DATEADD(day, -30, ...)`の30日は、対象品の「おすすめ利用周期＝1ヶ月」という業務仕様に基づく値です。変更する場合は商品担当・マーケティング担当への確認が必要です。詳細は[ケース全体README](../README.md#返品キャンセルの取り扱いと30日ルール--return-cancellation-handling--the-30-day-rule)を参照してください。
