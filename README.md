# SQL Foundations on AdventureWorks: 7-day drill set

A day-by-day record of learning T-SQL on Microsoft SQL Server during my Data Engineering internship at PITB. Every query was run in SQL Server Management Studio against the AdventureWorks2022 sample database, with a screenshot of the real result and a plain-English explanation.

**Live site:** https://noortayyababatool-spec.github.io/sql-syllabus/

## What each day covers

| Day | Topic | What it covers | Queries |
|---|---|---|---|
| [1](day1/) | SELECT, columns, DISTINCT, aliases | Every column vs chosen columns, DISTINCT on one and two columns, COUNT(DISTINCT), arithmetic, aliases, string concatenation and the NULL rule, reading error messages, `sp_help` and `INFORMATION_SCHEMA` | 25 |
| [2](day2/) | WHERE, operators, NULL, LIKE | Comparison operators, BETWEEN, IN / NOT IN, IS NULL, AND/OR precedence, LIKE wildcards and bracket patterns, implicit conversion, date columns with a time part | 44 |
| [3](day3/) | ORDER BY, TOP, OFFSET-FETCH, functions | Multi-column sorts, TOP and WITH TIES, paging, NULL ordering, string, date, maths and conversion functions | 33 |
| [4](day4/) | Aggregate functions | COUNT(*) vs COUNT(column), SUM, AVG and NULL, MIN/MAX on dates and text, conditional aggregation, integer division, STRING_AGG | 31 |
| [5](day5/) | Joins | INNER, LEFT, RIGHT, FULL, CROSS and self joins, anti-joins, ON vs WHERE filters, join duplication, predicting row counts | 28 |
| [6](day6/) | GROUP BY, HAVING, subqueries, CASE | Grouping and HAVING, the logical query order, EXISTS / NOT EXISTS / NOT IN, derived tables and CTEs, correlated subqueries, CASE labels, manual pivots, ROLLUP | 29 |
| [7](day7/) | Mock assessment | 20 timed questions covering the whole week, with two answer-key queries that return wrong rows and their corrected versions | 22 |

## Week 2: Reporting SQL

| Day | Topic | What it covers | Queries |
|---|---|---|---|
| [8](day8/) | Window functions | ROW_NUMBER, RANK, DENSE_RANK, top-N per group, running totals and frames, LAG/LEAD, percent of total, NTILE, FIRST_VALUE, moving averages, de-duplication, gap detection | 22 |
| [9](day9/) | INSERT, UPDATE, DELETE, MERGE, transactions | A practice database built with SELECT INTO, identity columns and IDENTITY_INSERT, INSERT from SELECT, UPDATE with a JOIN, DELETE vs TRUNCATE, BEGIN/ROLLBACK/COMMIT, OUTPUT, MERGE upserts, deleting duplicates | 24 |

## Findings worth knowing about AdventureWorks2022

- **The CEO's `OrganizationNode` is NULL**, so the textbook self join with `GetAncestor(1)` leaves 7 employees without a manager instead of 1. Days 5 and 7 show a fix with `OR` in the `ON` clause.
- **Every store customer that ordered has a contact `PersonID`.** The 701 customers with no person never placed an order, so INNER and LEFT joins from orders to Person both return 31,465 rows.
- **Grouping by name merges different people.** Group revenue by `CustomerID`, not by first and last name.

## Structure

```
index.html        home page
dayN/index.html   one page per day: query, explanation, screenshot
dayN/shots/       SSMS screenshots
assets/           stylesheet and script
```
