# 概要 / Overview

顧客別ステータス横持ちデータを利用し、「初回受注月（コホート）」ごとの特典到達率・エラー率と、「実際の配信月」ごとの発生件数を1つのマトリクスに統合する分析用データマートのSQL設計例です。

以下の高度な設計を含みます。
- コホート軸（受注月・歩留まり評価）とカレンダー軸（配信月・コスト評価）という2つの異なる時間軸の統合
- コース別（初回3本／1本→2本／1本→3本）への到達率・エラー率のドリルダウン
- 「受注月」をカレンダーのY軸として再利用する高度な結合トリック

Example SQL that unifies two distinct time axes — order-month cohorts (for yield analysis) and delivery-month calendar actuals (for cost analysis) — into a single matrix, drilling down conversion and error rates by subscription course.

---

## データパイプライン内の位置 / Architecture Position

[16_mart_customer_gift_status_pivot](../16_mart_customer_gift_status_pivot/) の出力を土台にした、パイプラインの最終分析レイヤーです。

The final analytical layer of the pipeline, built on the output of [16_mart_customer_gift_status_pivot](../16_mart_customer_gift_status_pivot/).

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern
2つの時間軸の統合と結合キーの再利用トリック
Dual Time-Axis Integration via Join-Key Reuse

### 課題 / Problem

特典施策の全体像把握には「〇年〇月に受注した顧客の到達率」（コホート視点）と「今月に実際に配信された件数」（カレンダー視点、獲得時期を問わない）という、意味の異なる2つの時間軸が必要です。これらを別々のレポートで管理すると、部門ごとの要求（マーケティングと経理）に個別対応するコストが発生します。

Understanding the campaign requires two semantically different time axes: cohort-based yield (by acquisition month) and calendar-based cost (by delivery month, regardless of acquisition). Managing them as separate reports duplicates effort across departments (marketing vs. finance).

### 解決策 / Solution

`ordered_year_month_f1`（受注月）を、単なる「コホートの識別子」としてだけでなく、`amazon_pre_month_1st`（実際の配信月）との結合キーとしても再利用します。`ON a.ordered_year_month_f1 = b.gift_present_month_1st` という結合は、「Aさんの受注月とAさんの配信月」を繋いでいるのではなく、「2026年6月に受注した人たちの集計行」に対して「誰の受注かは問わず2026年6月に配信された件数」を横に並べる、YYYYMMを共通の座標軸として使うトリックです。

The join `ON a.ordered_year_month_f1 = b.gift_present_month_1st` does not link an individual customer's order month to their own delivery month — it uses YYYYMM as a shared coordinate axis, attaching "how many gifts went out in June 2026 (regardless of whose cohort)" onto the row representing "customers who ordered in June 2026."

---

## 処理ステップ / Processing Steps

### 1. Cohort Base Preparation
各特典回の配信有無・エラー有無・所要日数の計算とコース分類。

### 2. Cohort Aggregation
受注月×コース軸での歩留まり・エラー集計。

### 3. Calendar-Actuals Integration
カレンダー月別実績の横付けと各種率の計算。

### 4. Final Output Generation

---

## データ構造 / Input Data Structure

### Marts Tables
- `mart_customer_gift_status_pivot` : 顧客別ステータス横持ち表（16）

---

## 運用と保守 / Operations & Maintenance

### コホート軸の選択理由
コホート軸は「初回出荷月」ではなく「初回受注月」です。費用予測システムがF1獲得件数を受注日ベースで予測するため、起算点を一致させる必要があります。この前提を変更する場合は予測システム側との整合を確認してください。

### センサリング（打ち切り）への注意
直近のコホートは「まだ特典時期が到来していない」だけで到達率が構造的に低く出ます。予測パラメータとして率を利用する際は、観測期間が十分に経過したコホート（1回目：受注から約120日以上、2回目：約240日以上）に限定してください。

### コース細分化の再統合について
コース別（3分類）への細分化によりコホートあたりのサンプルサイズが薄くなります。係数が不安定な場合は「1本→2本」「1本→3本」を「1本→複数本」へ再統合する余地を残しています。
