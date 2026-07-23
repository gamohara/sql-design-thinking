# 概要 / Overview

特典配布対象者の「正常配信ステータス（配信済・不達等）」と、配信前に除外された「エラー保留ステータス」を統合し、外部システムや管理台帳にそのまま貼り付けて顧客情報を一括更新するための「最終ステータス更新リスト」を作成するSQLの設計例です。

以下の設計思想を含みます。
- 「最終的に届いたか」を基準にしたエラー判定思想（途中経過ではなく費用発生の有無で判定）
- 顧客×予定日の動的な「プレゼント回数」採番（手動調整の実付与日を優先）
- 未配信者の日付クリアによる、現実世界の状態との整合性維持

Example SQL producing the final "closing" report by unioning normal delivery outcomes with pre-excluded error targets, defining the error flag by whether the gift ultimately reached the customer (a cost-incurring event) rather than by intermediate processing status.

---

## データパイプライン内の位置 / Architecture Position

[10](../10_int_predelivery_alert_check/)（事前除外されたエラー対象者）と [13](../13_int_email_delivery_status_integration/)（正常配信対象者）の2つの出力を統合します。

Unions the pre-excluded error targets from [10](../10_int_predelivery_alert_check/) with the normally-processed targets from [13](../13_int_email_delivery_status_integration/).

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern
「最終到達」基準のエラー判定思想
"Ultimate Delivery" Error Definition

### 課題 / Problem

配信プロセスの途中経過（初回配信失敗など）だけでエラーを判定すると、後日「再配信」で無事届いた顧客まで誤ってエラー扱いしてしまい、費用予測システムの配信エラー率が実態より過大に算出されてしまいます。

Defining errors purely by intermediate outcomes (e.g., an initial send failure) would misclassify customers who were later successfully reached via resend, inflating the error rate used by downstream cost-forecasting.

### 解決策 / Solution

エラーフラグを「最終的に顧客へギフトが届いたか」という事実だけで判定します。
- メール不備による事前除外者（`gift_seq_no = 999999999`）は無条件でエラー
- 「未配信」（未来の予定）はエラーに含めない（未確定とエラーを分離）
- 初回が不達でも再配信で成功していればエラー扱いしない

By anchoring the error definition strictly to final delivery outcome — not intermediate steps — the flag remains an accurate cost/ROI signal for downstream forecasting.

---

## 処理ステップ / Processing Steps

### 1. Pre-Excluded Error Target Extraction
メール情報不備により事前除外された対象者の抽出。

### 2. Confirmed Delivery Target Retrieval
正常に処理が進んだ対象者の配信ステータス取得。

### 3. Union
縦結合による統合。

### 4. Final Output Generation
動的な特典タイミング採番とエラーフラグの付与。

---

## データ構造 / Input Data Structure

### Intermediate Tables
- `int_predelivery_alert_check` : 事前除外エラー対象者（10）
- `int_email_delivery_status_integration` : 正常配信対象者（13）

---

## 運用と保守 / Operations & Maintenance

### ダミーNoの意図
`gift_seq_no = 999999999` は、エラー除外者を区別するためのダミー番号です。最終出力でORDER BYした際、エラー者がリストの下部にまとまるように設計されています。

### 未配信者の日付クリア
メール配信ステータスが「未配信」の顧客は、手動調整された日付が存在していても『実際のプレゼント日』を強制的にNULLクリアしています。これは「現実世界でまだ送られていない」ことを明示し、運用上の誤認を防ぐためのフェイルセーフです。

### 費用予測システムとの連携
「メール配信エラーフラグ」「メール未登録フラグ」は費用予測システムが参照しています。判定条件を変更する際は、予測側の率算出への影響を確認してください。
