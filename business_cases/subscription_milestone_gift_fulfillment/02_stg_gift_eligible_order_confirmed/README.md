# 概要 / Overview

前工程（ユーザー単位の例外対応済み）のF1候補者リストに対し、注文単位の手動除外を適用してF1（起点）の対象注文を確定させ、同一顧客による重複購入を可視化するSQLの設計例です。

以下の処理を含みます。
- 注文単位の手動除外リストとの突き合わせ
- ウィンドウ関数を用いた同一顧客の重複購入検知
- 重複時にどちらの注文を有効とするかの判断材料（商品ラインの組み合わせ等）の提供

Example SQL for finalizing the anchor (F1) qualifying orders by applying order-level manual exceptions, and for surfacing duplicate F1 purchases by the same customer for downstream adjudication.

---

## データパイプライン内の位置 / Architecture Position

[01_stg_gift_eligible_purchase_base](../01_stg_gift_eligible_purchase_base/) の出力を受け取り、注文単位の例外処理を完結させます。

Receives the output of [01_stg_gift_eligible_purchase_base](../01_stg_gift_eligible_purchase_base/) and completes order-level exception handling.

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern
責務分離された注文単位例外処理と重複購入の可視化
Separated Order-Level Exception Handling & Duplicate Purchase Visibility

### 課題 / Problem

初回購入（F1）の対象者抽出において、ユーザー単位の除外と注文単位の除外を同一クエリで同時に処理すると、データ粒度の不整合によるバグ（データ増殖や過剰な削除）が発生するリスクがあります。また、1人の顧客が複数回F1条件を満たしてしまうケース（重複）を放置すると、特典の重複付与や取り違えが発生します。

Handling user-level and order-level exceptions in the same query risks data-grain bugs. Left unaddressed, a customer qualifying for F1 multiple times can lead to duplicate or misattributed gift grants.

### 解決策 / Solution

**【責務の分離】**
前工程（01）でユーザー単位の除外・追加を完了させ、本クエリでは純粋に「注文単位の除外」のみを適用します。

**【重複の可視化】**
ウィンドウ関数（`COUNT() OVER`, `LISTAGG() OVER`）を用いて、同一ユーザー内の対象注文数と全注文IDの一覧を各行に付与。重複がある場合は「重複チェック」カラムに商品ラインの組み合わせも含めて可視化し、運用担当者が判断できるようにしています。

By separating order-level exception handling into its own query and surfacing duplicate purchases via window functions, the design avoids grain-mixing bugs and gives operators the evidence needed to resolve ambiguous cases.

---

## 処理ステップ / Processing Steps

### 1. Base Retrieval
前工程（ユーザー単位補正済み）の候補者リスト取得。

### 2. Order-Level Manual Exception Handling
手動運用リストと突き合わせ、注文単位の削除対象を除外。

### 3. Duplicate Detection
ウィンドウ関数を用いた同一顧客内の重複購入の検知。

### 4. Final Output Generation
重複チェック等のアラートカテゴリを付与して最終データ生成。

---

## データ構造 / Input Data Structure

### Staging Tables
- `stg_gift_eligible_purchase_base` : 前工程（01）の出力

### Master / Reference Tables
- `map_gift_manual_exceptions` : 特典_手動対応リスト.csv（`exception_type = 'DELETE_BY_ORDER'` のみ評価）

---

## データ品質チェック / Data Quality Strategy

### Duplicate Purchase Detection
`重複チェック_大分類`・`_中分類`・`_詳細_注文ID` の3段階のカラムにより、重複購入の有無・組み合わせ・対象注文IDを一目で確認できます。これは後続クエリで「1人1回」ルールを適用する際の重要な判断材料です。

---

## 運用と保守 / Operations & Maintenance

### 例外処理の粒度を混在させない
本クエリと前工程（01）はデータ粒度（ユーザー単位／注文単位）で明確に分割されています。将来的な改修でこの2クエリを統合することは、データ増殖・消失バグの再発リスクがあるため避けてください。
