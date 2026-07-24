# 概要 / Overview

特典の配布条件を満たした顧客の確定リストに対し、実際にメール配信を行うための「個人情報（氏名・メールアドレス）」および「デジタルギフトコード情報」を結合するSQLの設計例です。

以下のセキュリティ設計を含みます。
- ギフトコードを「過去・現在」の対象者にのみ結合し、「未来」の対象者には絶対に紐付けない（JOIN条件による安全制御）
- 管理リストとコードマスタ間のシリアルナンバー不一致検知

Example SQL that joins confirmed gift-eligible customers with PII and gift codes for the actual email send, using a join condition (not a filter) to guarantee that gift codes — sensitive as cash-equivalent vouchers — are never assigned to "future" recipients before they've actually qualified.

---

## データパイプライン内の位置 / Architecture Position

[13_int_email_delivery_status_integration](../13_int_email_delivery_status_integration/) の出力に、ギフトコードマスタと顧客PIIマスタを結合します。

Joins the output of [13_int_email_delivery_status_integration](../13_int_email_delivery_status_integration/) with the gift code master and customer PII master.

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern
JOIN条件によるタイムライン制限セキュリティ設計
Timeline-Restricted JOIN Condition as a Security Control

### 課題 / Problem

デジタルギフトコードは金券と同等の機密情報です。もし未来の配信予定者（まだ条件を確定的に満たしていない、あるいは事後にキャンセル・返品する可能性がある顧客）に対して事前にコードを割り当ててしまうと、情報漏洩や誤配信のリスクが高まります。

Digital gift codes are as sensitive as cash vouchers. Pre-assigning a code to a "future" recipient — whose eligibility isn't yet finalized and could still be cancelled or returned — risks leakage or misdelivery.

### 解決策 / Solution

`LEFT JOIN` の**結合条件**（`ON`句）に `a.time_line IN ('過去', '現在')` を含めることで、未来の対象者に対してはコード側のマスタが一切マッチせず、結果が常にNULLになることを保証します。フィルタ（`WHERE`）ではなく結合条件でこれを制御することで、未来の行自体は出力から消えず、コードだけが安全にマスクされます。

By embedding the timeline restriction inside the `LEFT JOIN`'s `ON` clause rather than a `WHERE` filter, future-timeline rows are preserved in the output (for visibility/planning purposes) while the sensitive code column is guaranteed to remain NULL for them — a structural, not incidental, security guarantee.

---

## 処理ステップ / Processing Steps

### 1. Confirmed Target List Retrieval
確定対象者リストの取得と配信ステータスフラグの生成。

### 2-3. Master Data Retrieval
ギフトコードマスタと顧客PIIマスタの取得。

### 4. Secure Join
タイムライン制限付きの安全な結合。

### 5. Final Output Generation

---

## データ構造 / Input Data Structure

### Intermediate Tables
- `int_email_delivery_status_integration` : 配信ステータス統合済リスト（13）

### Master Tables
- `map_gift_code_inventory` : デジタルギフトコード在庫一覧
- `dim_customers_pii` : 顧客属性マスタ（個人情報）

---

## 運用と保守 / Operations & Maintenance

### セキュリティ条件の維持
Step 4の `a.time_line IN ('過去', '現在')` は情報漏洩を防ぐ非常に重要な結合条件です。安易に削除・変更しないでください。

### シリアルナンバー不一致のエスカレーション
`シリアルナンバー不一致チェック` に値が入っているデータは、付与マスタの取り込みミスの可能性があるため、配信前に必ず運用担当者にエスカレーションしてください。
