# SQL Design Patterns for Business Data Analysis

## 概要 / Overview

このリポジトリでは、ビジネスデータ分析において実際に使用される  
SQL設計パターンや分析用データセット作成の考え方をまとめています。

主に以下のテーマを中心に整理しています。

・複雑なビジネスロジックを整理するSQL設計  
・Window関数を活用したデータ計算  
・データ粒度（Grain）を意識したデータモデリング  
・初見データを短時間で理解するための思考プロセス  

実務で使用していたSQLをベースにしていますが、  
企業情報や機密情報を含まない形に抽象化して掲載しています。

---

This repository contains SQL design patterns and structured query examples  
for business data analysis.

The focus of this repository is:

- SQL design for complex business logic
- Window function based calculations
- Data modeling with clear data grain
- Structured thinking for understanding unfamiliar datasets

All queries are abstracted versions of real-world SQL used in business environments,  
with company-specific information removed.

---

# SQL Design Philosophy

SQLを書く際には、以下の順序で設計することを重視しています。

1. Business Purpose（何のためのデータか）
2. Data Grain（1行が何を表すか）
3. Primary Key（データの一意性）
4. Table Relationships（テーブル関係）
5. Calculation Logic（計算ロジック）
6. Data Quality Checks（データ品質確認）

このリポジトリでは、単なるSQLの書き方ではなく  
**ビジネス分析のためのSQL設計**を整理しています。

---

When designing SQL, the following structure is used:

1. Business Purpose
2. Data Grain
3. Primary Key
4. Table Relationships
5. Calculation Logic
6. Data Quality Checks

The goal is not just writing SQL, but designing queries  
for reliable business data analysis.

---

# Repository Structure
```text
business_cases/
└── subscription/
    ├── README.md
    └── subscription_point_allocation_logic.sql
  
Each directory contains a business case and the SQL used to solve it.
