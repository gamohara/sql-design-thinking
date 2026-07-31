# 概要 / Overview

システムが自動抽出した最新の対象者リストと、運用担当者が手動管理しているリスト（CSV）を突き合わせ、差異や漏れがないかを検証・モニタリングし、新しい対象者に一意の特典No（連番）を自動採番するSQLの設計例です。

以下の高度なアーキテクチャを含みます。
- 特典対象日を「過去・現在・未来」の3タイムラインに分割した検証
- 休日（土日）の手動更新停止による採番ズレを防ぐ「ベルトコンベア形式」のタイムライン制御
- FULL JOINが空振りしても採番が1にリセットされない、独立CTE + CROSS JOINによる安全な自動採番

Example SQL that reconciles a system-extracted target list against an operator-managed CSV across past/current/future timelines, using a "belt conveyor" holiday-safety mechanism to prevent numbering drift and an isolated CROSS JOIN design to avoid a sequence-reset vulnerability.

---

## データパイプライン内の位置 / Architecture Position

[10_int_predelivery_alert_check](../10_int_predelivery_alert_check/) の出力を土台に、手動運用リストとの突合を行います。

Reconciles the output of [10_int_predelivery_alert_check](../10_int_predelivery_alert_check/) against the operator-managed manual list.

リポジトリ全体のアーキテクチャは [トップレベルREADME](../../../README.md#overall-architecture--全体アーキテクチャ) を参照してください。

---

## SQL Design Pattern
休日対応ベルトコンベア制御と独立採番による脆弱性解消
Holiday-Aware Belt-Conveyor Control & Numbering-Vulnerability Elimination

### 課題 / Problem

対象者は時間の経過とともに「未来 → 現在 → 過去」へと自動で押し出されていきますが、土日などの休日は手動リストの更新が止まります。休日中にシステム側で自動的に削除・追加されたデータがそのまま過去に流れると、月曜日の自動採番で採番ズレという致命的なエラーを引き起こします。また、手動リストの「現在」や「未来」が0件のとき `FULL JOIN` が空振りすると、採番が1にリセットされてしまう脆弱性もあります。

Targets are automatically pushed from "future" through "current" to "past" over time, but manual CSV updates pause on weekends. If system-side additions/removals during a holiday flow straight into "past," Monday's auto-numbering suffers catastrophic drift. Separately, an empty "current"/"future" manual list can cause a `FULL JOIN` to silently reset numbering to 1.

### 解決策 / Solution

**【曜日マスタによるベルトコンベア制御】**
外部CSV（曜日別起動リスト）から「今日は手動更新が停止しているか（is_holiday）」を読み込み、休日の場合は『現在分』の離脱除外・新規追加を自動でブロック（完全固定）します。

### 曜日マスタによるベルトコンベア制御（実装詳細）
休日制御は、`is_excluded` と `is_included` それぞれの判定条件式に `is_holiday` を組み込むことで実現していますが、2つのフラグの働き方は非対称です。

`is_excluded`（離脱判定）は `is_holiday <> 1`（平日）の場合にのみ、実際にシステムから消えた顧客を検知して1が立ちます。休日は常にこの条件を満たさないため、`is_excluded` は0のまま、つまり離脱が検知されず「固定」されます。

`is_included`（新規追加判定）は `is_holiday = 1`（休日）の場合にのみ、新規に現れた顧客を検知して1が立ちます。この1は、後続の `WHERE is_excluded <> 1 AND is_included <> 1` によって弾かれるため、休日に新規で現れた対象者は最終リストに反映されず「固定」されます。

結果として、**平日は離脱・追加ともに通常通り検知・反映される**一方、**休日は「現在」分の離脱も追加も一切発生せず、リストがそのまま固定される**という挙動になります。2つの条件式は非対称ながら対になっているため、片方だけを修正すると休日制御が崩れます。変更する際は両方を同時に確認してください。

Holiday control is implemented by embedding `is_holiday` into the condition for both `is_excluded` and `is_included`, but the two flags behave asymmetrically. `is_excluded` (departure detection) is only set to 1 when `is_holiday <> 1` (a weekday) and a customer who has genuinely disappeared from the system is detected — on holidays this condition is never met, so departures stay "frozen" at 0. `is_included` (new-arrival detection) is only set to 1 when `is_holiday = 1` (a holiday) and a newly-appeared customer is detected; that 1 is then discarded by the downstream `WHERE is_excluded <> 1 AND is_included <> 1`, so a customer newly appearing on a holiday is also "frozen" out of the final list. As a result, **weekdays detect and reflect both departures and additions as normal**, while **holidays freeze the "current" timeline entirely — no departures and no additions occur.** The two conditions are asymmetric but paired; changing only one will break holiday handling, so always verify both together when modifying this logic.

### 運用上の柔軟性：CSVによる手動制御
この休日判定は自動化されていますが、`dim_weekday_calendar` の `is_holiday` 列に0（平日扱い）または1（休日扱い）を入れるだけで、システムの挙動そのものを切り替えられる設計にもなっています。例えば、通常の土日以外に臨時で更新を止めたい日があれば、コードを一切変更せず、このCSVの該当日を1に書き換えるだけで「現在分の離脱・新規追加をともに凍結する」状態を再現できます。カレンダーが単なる自動判定用のマスタであると同時に、運用担当者にとっての手動スイッチとしても機能する設計です。

Although holiday detection is automated, the design also lets operators switch the system's actual behavior just by setting `dim_weekday_calendar`'s `is_holiday` column to 0 (treat as a weekday) or 1 (treat as a holiday). For example, if there's an ad-hoc day beyond the usual weekend when updates need to pause, operators can reproduce the "freeze both departures and additions for the current timeline" behavior by flipping that day's value to 1 in the CSV — no code changes required. The calendar table therefore doubles as both an automatic-detection master and a manual override switch for operators.

**【独立CTEによる安全な採番】**
過去の最大採番Noを`past_max_present_no`という独立したCTEに保管し、採番時にあえて`CROSS JOIN`で結合します。これにより、手動リストが空でも過去の最大Noが消失せず、採番が1にリセットされる脆弱性を排除しています。

By freezing current-timeline changes on holidays (per an external weekday calendar) and isolating the "max past sequence number" in its own CTE joined via `CROSS JOIN`, the design eliminates both the weekend-drift bug and the empty-list reset vulnerability.

---

## 処理ステップ / Processing Steps

### 1-3. Source & Calendar Retrieval
手動リスト・自動抽出リスト・曜日マスタの取得。

### 4. Isolated Max Sequence Number
過去の最大採番Noの独立取得。

### 5-8. Timeline Reconciliation
過去・現在（休日ブロック判定含む）・未来分の突合検証。

### 9-10. Auto Numbering
新規対象者へのCROSS JOINによる安全な自動採番。

### 11-12. Final Union & Output
すべての検証済データの統合と最終出力。

---

## データ構造 / Input Data Structure

### Intermediate Tables
- `int_predelivery_alert_check` : 配信前アラート済リスト（10）

### Master / Reference Tables
- `map_gift_target_ledger` : 対象者リスト
- `dim_weekday_calendar` : 曜日別稼働カレンダー

---

## 運用と保守 / Operations & Maintenance

### 未来データの取り扱い
本クエリでは「遠すぎる未来の予定データ」をSQLレベルで除外しません。代わりに「本日からデジタルギフトまでの日数」を出力しているため、後続のBIツールのフィルター機能で表示範囲を柔軟に制御してください。

### 対象離脱の仕様
**原因（フラグが立つ条件）**: システム側の自動抽出リストには存在するが、突合先の比較リストには存在しない（＝返品等でシステムから消えた）現在・未来の対象者には、`is_excluded = 1` のフラグが立ち、`alert_status_main` に「対象離脱」という値が設定されます。

**最終フィルタ（除外の実行）**: 最終SELECTの `WHERE is_excluded <> 1` は、この `is_excluded = 1` の行そのものを最終リストから取り除くための条件です。つまり「対象離脱と判定された行」が「`is_excluded <> 1` という条件」によって除外されるのであり、この条件自体が対象離脱を引き起こすわけではありません。

この2段階の処理により、最終出力の「アラート_大分類」に「対象離脱」が表示されることは一切ありません。
