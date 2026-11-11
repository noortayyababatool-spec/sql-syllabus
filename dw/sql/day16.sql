-- Day 16: Fact tables vs dimension tables
-- Goal: look at any table and say which it is, what its grain is, and which columns are measures, keys and attributes.
-- Database: AdventureWorksDW2022 on SQL Server Express. Run one step at a time in SSMS (select it, press F5).
-- Every step, with its result screenshot and explanation: https://noortayyababatool-spec.github.io/sql-syllabus/day16/

-- ============================================================================
-- Drill
-- ============================================================================

-- Step 1. Anatomy of a fact table
-- Takeaway: You can recognise a fact table from its column list alone: integer keys, money and quantity columns, almost no text.
USE AdventureWorksDW2022;
SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'FactInternetSales' ORDER BY ORDINAL_POSITION;
GO

-- Step 2. Anatomy of a dimension table
-- Takeaway: A dimension is the list of words you can put in a report's slicer or row headers: colour, model, product line.
SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'DimProduct' ORDER BY ORDINAL_POSITION;
GO

-- Step 3. Row counts: facts are tall, dimensions are short
-- Takeaway: Facts grow with every event; dimensions grow only when something new appears to describe. In a real warehouse the gap is millions to thousands.
SELECT 'FactInternetSales' AS T, COUNT(*) AS Rows FROM FactInternetSales
UNION ALL SELECT 'FactResellerSales', COUNT(*) FROM FactResellerSales
UNION ALL SELECT 'DimProduct', COUNT(*) FROM DimProduct
UNION ALL SELECT 'DimCustomer', COUNT(*) FROM DimCustomer
UNION ALL SELECT 'DimDate', COUNT(*) FROM DimDate
UNION ALL SELECT 'DimSalesTerritory', COUNT(*) FROM DimSalesTerritory;
GO

-- Step 4. Prove the grain
-- Takeaway: State the grain first, then test it with exactly this GROUP BY ... HAVING COUNT(*) > 1 query. Duplicates at the grain are the most common way a fact load double-counts revenue.
SELECT SalesOrderNumber, SalesOrderLineNumber, COUNT(*)
FROM FactInternetSales
GROUP BY SalesOrderNumber, SalesOrderLineNumber
HAVING COUNT(*) > 1;
GO

-- Step 5. Surrogate key vs natural key
-- Takeaway: Surrogate keys are small, never change meaning, and belong to the warehouse. That last point matters in the next query.
SELECT ProductKey, ProductAlternateKey, EnglishProductName
FROM DimProduct
WHERE EnglishProductName LIKE 'Mountain-100%';
GO

-- Step 6. Why surrogate keys: one product, several rows
-- Takeaway: The source system has one row per product; the warehouse keeps a new row each time a tracked attribute (here, the price) changes. The natural key cannot be the primary key any more, so the warehouse needs its own: the surrogate key. Day 20 covers this in full as a slowly changing dimension.
SELECT ProductAlternateKey, COUNT(*)
FROM DimProduct
GROUP BY ProductAlternateKey
HAVING COUNT(*) > 1;
GO

-- Step 7. One product's history
-- Takeaway: Data quirk: the EndDate values (2007, 2008) are earlier than the StartDate values (2011, 2012). 200 of the 606 rows have this. The sample's dates were shifted when it was rebuilt, but not consistently; trust Status and NULL EndDate, not the date order.
SELECT ProductKey, ProductAlternateKey, EnglishProductName, ListPrice, StartDate, EndDate, Status
FROM DimProduct
WHERE ProductAlternateKey = 'CA-1098';
GO

-- Step 8. Every foreign key resolves: zero orphans
-- Takeaway: Run this check for every key in a fact table after every load. The 'NA' unknown member row seen in DimSalesTerritory exists so that facts with a missing value still have something to point at.
SELECT COUNT(*) AS Orphans
FROM FactInternetSales f
LEFT JOIN DimProduct p ON f.ProductKey = p.ProductKey
WHERE p.ProductKey IS NULL;
GO

-- Step 9. An additive measure: the total
-- Takeaway: Additive measures are the easy case and the most common: amounts, quantities, costs.
SELECT SUM(SalesAmount) AS Revenue FROM FactInternetSales;
GO

-- Step 10. Summed by product colour
-- Takeaway: Grouping by a dimension attribute is the standard warehouse query: one fact, one join, one GROUP BY.
SELECT p.Color, SUM(f.SalesAmount) AS Revenue
FROM FactInternetSales f
JOIN DimProduct p ON f.ProductKey = p.ProductKey
GROUP BY p.Color;
GO

-- Step 11. Summed by calendar year
-- Takeaway: By colour, by year, or in total, SUM(SalesAmount) is always right. That is what additive means.
SELECT d.CalendarYear, SUM(f.SalesAmount) AS Revenue
FROM FactInternetSales f
JOIN DimDate d ON f.OrderDateKey = d.DateKey
GROUP BY d.CalendarYear;
GO

-- Step 12. A non-additive measure: SUM(UnitPrice)
-- Takeaway: A wrong query can return a right-looking number. The next query uses the reseller table, where quantities vary, to show what SUM(UnitPrice) really does.
SELECT SUM(UnitPrice) AS SumUnitPrice FROM FactInternetSales;
SELECT SUM(SalesAmount) / SUM(OrderQuantity) AS WeightedAvgPrice FROM FactInternetSales;
GO

-- Step 13. The same test where quantities vary
-- Takeaway: For a non-additive measure, never SUM and be careful with AVG: recompute it from additive parts (SUM of revenue / SUM of units).
SELECT SUM(UnitPrice) AS SumUnitPrice, SUM(SalesAmount) AS Revenue, SUM(OrderQuantity) AS Units,
       SUM(SalesAmount) / SUM(OrderQuantity) AS WeightedAvgPrice, AVG(UnitPrice) AS SimpleAvgPrice
FROM FactResellerSales;
GO

-- Step 14. Semi-additive: inventory on hand
-- Takeaway: Semi-additive: you may sum a balance across products (total stock today), but across dates you take the last value (or an average), never the sum.
SELECT SUM(UnitsBalance) AS SumAcrossAllDates FROM FactProductInventory WHERE ProductKey = 1;
SELECT TOP 1 DateKey, UnitsBalance AS OnHandNow FROM FactProductInventory WHERE ProductKey = 1 ORDER BY DateKey DESC;
GO

-- Step 15. A fact table with a measure
-- Takeaway: Grain: one salesperson, one quarter, one target amount.
SELECT TOP 10 * FROM FactSalesQuota;
GO

-- Step 16. A factless fact table
-- Takeaway: A factless fact records that an event happened. You measure it by counting rows: COUNT(*) responses per subcategory, per month, per customer.
SELECT TOP 10 * FROM FactSurveyResponse;
SELECT COUNT(*) AS Responses FROM FactSurveyResponse;
GO

-- ============================================================================
-- Written exercise
-- ============================================================================

-- Step 17. FactResellerSales: every foreign key and its dimension
-- Takeaway: DimDate appears three times: one dimension playing three roles (order, due and ship date). This is called a role-playing dimension.
SELECT c.name AS ForeignKeyColumn, OBJECT_NAME(fk.referenced_object_id) AS PointsAt
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fc ON fc.constraint_object_id = fk.object_id
JOIN sys.columns c ON c.object_id = fc.parent_object_id AND c.column_id = fc.parent_column_id
WHERE fk.parent_object_id = OBJECT_ID('dbo.FactResellerSales')
ORDER BY c.name;
GO

-- Step 18. FactResellerSales: test the grain
-- Takeaway: Write the grain only after a query proves it.
SELECT SalesOrderNumber, SalesOrderLineNumber, COUNT(*)
FROM FactResellerSales
GROUP BY SalesOrderNumber, SalesOrderLineNumber
HAVING COUNT(*) > 1;
GO

-- Step 19. DimEmployee: which attributes are worth grouping by
-- Takeaway: A good grouping attribute has far fewer distinct values than the table has rows. Near-unique columns (email, phone, national ID) are for looking someone up, not for grouping.
SELECT COUNT(*) AS Employees, COUNT(DISTINCT DepartmentName) AS Departments, COUNT(DISTINCT Title) AS Titles,
       COUNT(DISTINCT SalesTerritoryKey) AS Territories, COUNT(DISTINCT Gender) AS Genders,
       COUNT(DISTINCT MaritalStatus) AS MaritalStatuses, COUNT(DISTINCT EmailAddress) AS Emails
FROM DimEmployee;
GO

