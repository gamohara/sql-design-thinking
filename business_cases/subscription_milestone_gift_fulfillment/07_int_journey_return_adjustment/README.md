# 概要 / Overview

顧客の全購入ジャーニーに対し、特典条件に関わらないタイミングで発生した返品（連続返品含む）をタイムラインから除外し、有効な継続回数（注文番号）を繰り上げて再採番するSQLの設計例です。

以下の高度なアーキテクチャを含みます。
- 「島分割法（Island Method）」を応用した連続返品の一括除外
- コースごとに異なる返品除外ルール（追加特典対象者は例外扱い等）
- 特典付与が完了する回数以降のデータを切り捨てる軽量化処理

Example SQL that removes returns irrelevant to gift eligibility from a customer's purchase journey and renumbers the valid continuation count, using the Island Method to safely handle consecutive returns as a single block regardless of how many shipments they span.

---

## データパイプライン内の位置 / Architecture Position

[05](../05_int_customer_gift_journey_timeline/)（統合ジャーニー）と [06](../06_int_bonus_gift_upsell_detection/)（追加特典対象者フラグ）を結合します。

Combines [05](../05_int_customer_gift_journey_timeline/) (unified journey) with the bonus-gift eligibility flag from [06](../06_int_bonus_gift_upsell_detection/).

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern
島分割法による連続返品の安全な一括除外
Safe Consecutive-Return Exclusion via the Island Method

### 課題 / Problem

特典の付与タイミング（2回目、3回目など）に当たる出荷が返品された場合、単純に「その回を除外」するだけでは、「2回目も3回目も連続して返品した」ケースで3回目の返品分が履歴に残ってしまい、特典の採番がズレてしまいます。

Naively excluding just "the return at the milestone shipment" fails when returns occur consecutively (e.g., both the 2nd and 3rd shipments), leaving a stray record that misaligns the milestone numbering.

### 解決策 / Solution

返品状態（0⇔1）が切り替わるタイミングで累積和を取り、連続する同一状態のレコードを1つの「島」としてグループ化します（`advanced_sql_recipes` の Gaps and Islands パターンと同系統の手法）。これにより、「F1直後に発生した最初の返品の島」を、それが何回連続していようと一括で特典判定から除外できます。除外するかどうかはコース（初回1本→2本 / 初回1本→3本）ごとに異なる業務ルールで判定します。

By taking a running sum over state transitions (return vs. non-return), consecutive same-state records are grouped into a single "island" — the same technique demonstrated in this repository's `advanced_sql_recipes` gaps-and-islands examples. The first return island right after F1 can then be excluded as one block regardless of its length.

---

## 処理ステップ / Processing Steps

### 1. Flag Join
ジャーニーと追加特典対象者フラグの結合。

### 2. Return Islands (Island Method)
返品状態による島分割。

### 3. First Return Island Identification
「最初の返品の島」の特定。

### 4. Exclusion & Renumbering
コースごとのルールに基づく除外と、有効回数の再採番。

### 5. Final Output Generation
特典対象期間内のデータへの絞り込みと最終データ生成。

---

## データ構造 / Input Data Structure

### Intermediate Tables
- `int_customer_gift_journey_timeline` : 統合ジャーニー（05）
- `int_bonus_gift_upsell_detection` : 追加特典対象者フラグ（06）

---

## 運用と保守 / Operations & Maintenance

### 除外ロジックの重要性
Step 4のWHERE句による除外ロジックは業務ルールの中核です。「初回1本→2本コース」は追加特典対象者になっている場合は返品を除外しない、「初回1本→3本コース」は3回目からの付与のため無条件で除外する、といった条件を変更する際は、特典付与回数のビジネスルールと整合させてください。

