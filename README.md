# sql-design-thinking
初見データの構造理解とビジネス分析に向けた、SQL設計例と構造化思考のメモ集。  
A collection of SQL design examples and notes on structured thinking for dataset understanding and business analysis.

## このリポジトリについて

本リポジトリでは、初見データを構造的に理解し、
ビジネス分析へとつなげるためのSQL設計アプローチを整理しています。

---

## 1. 初見データを30分で理解するための視点

- データ粒度の確認
- 主キー・ユニーク性の確認
- NULL・異常値の確認
- テーブル関係性の把握

---

## 2. SQL設計パターン

- CTEによる構造分解
- 粒度統一の考え方
- 集計前の前処理設計

---

## 3. 異常検知アプローチ

- 前年同月比による変動検知
- Zスコアによる外れ値検出
- 比率異常の検出

---

## 4. 設計思想メモ

- なぜそのCTE構造にしたのか
- なぜその粒度に揃えたのか
- パフォーマンスと可読性のバランス
