# 概要 / Overview

システムが自動抽出した対象者リストのステータスを監視し、特典付与の妨げとなるイレギュラー（配達遅延・直前解約・メール不備）を検知するアラート用SQLの設計例です。

以下の高度な設計を含みます。
- 休日跨ぎのデータ残留バグを防ぐ「出荷日基準10日プレチェック」の導入
- 個人情報保護のため、メールアドレスを直接出力せずソルト付きSHA256ハッシュキーで状態比較を可能にするセキュア設計

Example SQL that monitors an auto-extracted target list for delivery-blocking anomalies, introducing a shipment-date-based 10-day precheck to avoid a weekend-driven data-staleness bug, and using a salted SHA256 hash key instead of raw email addresses for secure state-change detection.

---

## データパイプライン内の位置 / Architecture Position

[09_int_fraud_risk_detection](../09_int_fraud_risk_detection/) の出力を受け取ります。本クエリの出力は後続の複数クエリ（11, 12, 15, 17, 20）から直接参照される、パイプラインの重要な分岐点です。

Receives the output of [09_int_fraud_risk_detection](../09_int_fraud_risk_detection/). Its output is a key branch point referenced directly by several downstream queries (11, 12, 15, 17, 20).

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern
出荷日基準の事前検知による休日ズレ防止とPII保護ハッシュキー
Shipment-Date Precheck for Holiday-Safety & PII-Safe Hash Keys

### 課題 / Problem

特典予定日の当日になって未入金や出荷遅延を検知しようとすると、手動CSVの更新が止まる「土日（休日）」に予定日を迎えた顧客が、システム上除外されているのに台帳に幽霊データとして残留し、翌日以降に採番ズレを起こすバグが発生します。また、メールアドレス更新の検知にPII（個人情報）を直接比較に使うのはセキュリティ上望ましくありません。

Checking for unpaid/delayed shipments only on the gift date itself fails on weekends (when manual CSV updates pause), causing stale "ghost" records to cause numbering drift. Comparing raw email addresses directly for change detection is also a PII exposure risk.

### 解決策 / Solution

**【出荷日基準の10日プレチェック】**
特典予定日ではなく「出荷日から10日以上経過しているか」を判定基準にすることで、付与日の数日前（平日）の時点で未入金・出荷遅延をあらかじめ検知し、休日中の採番ズレ事故を未然に防ぎます。

**【セキュアなハッシュキー】**
メールアドレスをユーザーIDでソルトした上でSHA256ハッシュ化し、生の個人情報を出力せずに「アドレスが変更されたか」を安全に差分検知できるようにしています。

Basing the precheck on shipment date (not gift date) catches issues on weekdays before any weekend freeze. Salting and hashing the email address (SHA256) enables secure change detection without ever exposing raw PII downstream.

---

## 処理ステップ / Processing Steps

### 1. Target List with Precheck & Timeline
10日プレチェック判定とタイムライン判定の付与。

### 2-4. Email Reference Data Retrieval
顧客PIIマスタ、配信不達リスト、購読解除リストの取得。

### 5. Email Status Integration & Hashing
メールエラー状態の統合とセキュアなハッシュキー生成。

### 6. Anomaly Detection
タイムラインとステータスを掛け合わせた異常検知。

### 7. Final Output Generation

---

## データ構造 / Input Data Structure

### Intermediate Tables
- `int_fraud_risk_detection` : リスク検知済ジャーニー（09）

### Dimension Tables
- `dim_customers_pii` : 顧客属性マスタ（個人情報）
- `raw_bounced_emails` : メール配信不達リスト
- `raw_unsubscribed_emails` : メール購読解除リスト

---

## 運用と保守 / Operations & Maintenance

### タイムゾーンの一貫性
日付の判定（過去・現在・未来）は、常に `CONVERT_TIMEZONE('Asia/Tokyo', CURRENT_TIMESTAMP)::DATE`（日本時間の今日）を基準にしています。タイムゾーンのズレによる誤検知を防ぐため、この基準は変更しないでください。

### JOIN爆発の防止
配信不達・購読解除テーブルへの `GROUP BY` は、同一アドレスの複数履歴による行の意図せぬ増殖を防ぐための必須処理です。外さないでください。
