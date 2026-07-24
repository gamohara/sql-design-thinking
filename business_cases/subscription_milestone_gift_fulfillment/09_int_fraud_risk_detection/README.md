# 概要 / Overview

デジタルギフト特典の発送可否を最終判断するための「4つの防衛ライン（チェックロジック）」を追加し、アラートを出力するSQLの設計例です。

以下の4大リスクを検知します。
1. 事後返品（特典をもらった後に商品を返品する悪質行為）
2. 特典逃げ（特典をもらう直前・直後に定期を即解約する行為）
3. 短期過剰出荷（システムエラーや不正操作による異常に短いスパンでの連続購入）
4. 返品予定のすり抜け（返品連絡を受けて対応中なのに特典を送ってしまう）

Example SQL implementing four lines of defense against campaign-ROI-degrading fraud/abuse patterns: post-gift returns, "gift and cancel" abuse, abnormally short shipment intervals, and in-progress return requests that could slip through before system processing catches up.

---

## データパイプライン内の位置 / Architecture Position

[08_int_gift_timing_manual_override](../08_int_gift_timing_manual_override/) の出力を受け取り、リスク検知フラグを付与します。

Receives the output of [08_int_gift_timing_manual_override](../08_int_gift_timing_manual_override/) and adds risk-detection flags.

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern
自己結合によるペナルティの未来伝播
Self-Join Penalty Propagation to Future Orders

### 課題 / Problem

特典施策では、特典を受け取った後に商品を返品する「事後返品」が発生した場合、その顧客が次回以降も同じように特典を受け取ってしまうリスクがあります。単に当該注文にフラグを立てるだけでは、次回の特典判定には影響しません。

Once a customer commits post-gift-return abuse, simply flagging that single order does nothing to prevent them from receiving further gifts on subsequent qualifying shipments.

### 解決策 / Solution

Step 1で判定した「悪質実績」を、`order_no + 1` という未来のターゲットキーとともに保持し、Step 4で自己結合（Self-Join）することで「その次の出荷回（次の特典発送予定回）」へ警告を強制伝播させます。「過去の悪行のペナルティを未来の自分に押し付ける」ロジックにより、悪質顧客を確実に後続の特典対象から除外します。

By recording the target order number (`order_no + 1`) alongside each detected abuse event and self-joining on it, the query propagates a penalty flag forward to the customer's next qualifying shipment — ensuring past abuse blocks future gift eligibility.

---

## 処理ステップ / Processing Steps

### 1. Base Journey & Risk Factor Precomputation
ジャーニーの読み込みと事後返品（悪質）フラグの事前計算。

### 2-3. Reference Data Retrieval
現在の定期ステータスとCS応対メモからの返品予定候補の取得。

### 4. Self-Join Penalty Propagation
悪質フラグの次回出荷への自己結合伝播。

### 5. Subscription Cancellation Validation
特典逃げ（即解約）リスクの判定。

### 6. Return-Intent Validation
返品予定リスクの判定。

### 7. Final Output Generation
アラートメッセージの付与と最終データ生成。

---

## データ構造 / Input Data Structure

### Intermediate Tables
- `int_gift_timing_manual_override` : 配信タイミング調整済ジャーニー（08）

### Master / Reference Tables
- `map_gift_target_ledger` : 対象者リスト（配信済み実績の確認用）
- `dim_subscription_status` : 現行の定期契約ステータス
- `raw_cs_incident_notes` : CS応対メモ

---

## 運用と保守 / Operations & Maintenance

### 悪質判定の条件
`is_high_risk` は「返品完了日が特典発送日以降である」かつ「手動リスト（過去）に存在し、確実に配信されている」という2条件を満たした場合のみ立ちます。

### 応対メモ判定の保守
返品予定チェックのキーワード判定（「返品」「返送」「チャットより返品解約」等）は、CS運用の文言が変わった場合に更新が必要です。

### リードタイム閾値
出荷チェックはリードタイムが1〜3日の場合を異常としています。年末年始の繰り上げ発送対応等で運用ルールが変わった場合は、この条件式を調整してください。
