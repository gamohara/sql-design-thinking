# 概要 / Overview

顧客からデジタルギフト配信タイミングに関する問い合わせがあった際に、CSがアップロードする「配信タイミング変更リスト（CSV）」を読み込み、出荷からの経過日数に応じた割合（%）を用いて、安全かつ段階的に短縮された「特急プレゼント配信日」を算出・上書きするSQLの設計例です。

以下の処理を含みます。
- 出荷から配信までの全期間に対する「経過割合」の算出
- 経過割合に応じて残り日数をN分割して短縮する、独自の公平性アルゴリズム
- 自動調整フラグがない場合は手動入力日数をそのまま採用するフォールバック

Example SQL implementing a fairness-preserving algorithm that shortens a customer's remaining wait time for a gift delivery in proportion to how much of the standard waiting period has already elapsed, preventing complaints from customers who waited patiently before any expedited handling.

---

## データパイプライン内の位置 / Architecture Position

[07_int_journey_return_adjustment](../07_int_journey_return_adjustment/) の出力に、GUI（BIツール）パラメータ層で基礎リードタイム（7/12/15/30日、運用期間に応じて変動）を適用した `stg_gift_timing_base` を入力とします。

Takes as input `stg_gift_timing_base`, a GUI/BI-tool parameter layer that applies the base lead time (7/12/15/30 days, varying by operational period) to the output of [07_int_journey_return_adjustment](../07_int_journey_return_adjustment/).

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern
経過割合に基づく段階的前倒しアルゴリズム
Elapsed-Ratio Graduated Acceleration Algorithm

### 課題 / Problem

特典の配信期間が延長されたことに伴う問い合わせに対し、「連絡してきた人だけすぐに送る」運用をすると、延長前の期間から真面目に待ってくれているお客様との間で不公平（クレームの火種）が生じます。

Simply expediting delivery for whoever happens to contact support creates unfairness relative to customers who have already been waiting under the prior (shorter) schedule.

### 解決策 / Solution

「出荷日からどれくらいの日数が経過しているか（経過割合）」を計算し、その割合に応じて「残り日数を自動でN分割して短縮する」アルゴリズムを導入しています。経過が浅いほど分割数を多く（緩やかに短縮）、経過が深いほど分割数を少なく（大きく短縮）することで、待機期間に比例した公平な前倒し対応をシステム的に実現します。

By computing the proportion of the standard wait already elapsed and dividing the *remaining* days by a divisor that shrinks as the elapsed ratio grows, customers who have waited longer receive a proportionally larger acceleration — a graduated, fair alternative to a flat "first-come" expedite.

---

## 処理ステップ / Processing Steps

### 1. Base Journey Retrieval
基礎リードタイム適用済みの購入ジャーニーの読み込み。

### 2. Manual Timing Adjustment List Retrieval
CS担当者アップロードのCSVと基礎日数の計算。

### 3. Elapsed Ratio Calculation
出荷から配信までの全期間に対する経過割合の算出。

### 4. Shorten Days Calculation
経過割合に応じた前倒し日数の自動計算。

### 5. Override
調整済み予定日の上書き。

### 6. Final Output Generation

---

## データ構造 / Input Data Structure

### Staging Tables
- `stg_gift_timing_base` : 07の出力に基礎リードタイムを適用した出荷情報（GUIパラメータ層）

### Master / Reference Tables
- `map_gift_timing_adjustments` : 特典_配信タイミング変更リスト.csv

---

## 運用と保守 / Operations & Maintenance

### アルゴリズムの閾値調整
`calc_shorten_days` の閾値（0.20, 0.40, 0.60, 0.80, 0.95）や分割数（2.0, 3.0, 4.0, 5.0）は公平性を保つためのビジネスルールです。短縮のスピードを変更したい場合は、ここを調整してください。

### ゼロ日短縮の防止
`GREATEST(..., 1)` は、計算結果が0になって「短縮されない」というエラーを防ぐためのフェイルセーフ（最低でも1日は短縮する安全装置）です。削除しないでください。
