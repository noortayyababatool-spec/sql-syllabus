-- Day 15: What a warehouse is: OLTP vs OLAP
-- Goal: explain in your own words why a company keeps two copies of its data in two different shapes.
-- Database: AdventureWorks2022 (OLTP) and AdventureWorksDW2022 (warehouse) on SQL Server Express. Run one step at a time in SSMS (select it, press F5).
-- Every step, with its result screenshot and explanation: https://noortayyababatool-spec.github.io/sql-syllabus/day15/

-- ============================================================================
-- Drill: see the difference
-- ============================================================================

-- Step 1. Count the tables in each database
-- Takeaway: Fewer tables is the point of a warehouse: the OLTP design splits data into many small tables so each fact is stored once; the warehouse merges them back into a few wide ones.
SELECT 'OLTP' AS Db, COUNT(*) AS Tables FROM AdventureWorks2022.INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE'
UNION ALL
SELECT 'DW', COUNT(*) FROM AdventureWorksDW2022.INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE';
GO

-- Step 2. List the warehouse tables: Dim and Fact
-- Takeaway: The naming is a promise: any Fact table holds numbers you add up and keys ending in Key; any Dim table holds text you filter and group by.
SELECT TABLE_NAME FROM AdventureWorksDW2022.INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME;
GO

-- Step 3. Same question, OLTP: revenue by territory and year
-- Takeaway: Wrapping a column in a function, like YEAR(OrderDate), also stops SQL Server from seeking an index on that column (Day 12). The warehouse avoids this by storing the year as its own column.
USE AdventureWorks2022;
SELECT t.Name AS Territory, YEAR(h.OrderDate) AS Yr, SUM(h.TotalDue) AS Revenue
FROM Sales.SalesOrderHeader h
JOIN Sales.SalesTerritory t ON h.TerritoryID = t.TerritoryID
GROUP BY t.Name, YEAR(h.OrderDate) ORDER BY Territory, Yr;
GO

-- Step 4. Same question, warehouse: revenue by territory and year
-- Takeaway: Same question, different answer. Before trusting any report, check what the source table contains: FactInternetSales holds online orders only, and SalesAmount excludes tax and freight.
USE AdventureWorksDW2022;
SELECT st.SalesTerritoryRegion AS Territory, d.CalendarYear AS Yr, SUM(f.SalesAmount) AS Revenue
FROM dbo.FactInternetSales f
JOIN dbo.DimSalesTerritory st ON f.SalesTerritoryKey = st.SalesTerritoryKey
JOIN dbo.DimDate d ON f.OrderDateKey = d.DateKey
GROUP BY st.SalesTerritoryRegion, d.CalendarYear ORDER BY Territory, Yr;
GO

-- Step 5. Why the two answers differ: reconcile the totals
-- Takeaway: A warehouse is a copy, so it must reconcile with its source. Matching the grand total exactly (and finding the date shift) is the kind of check a data engineer runs after every load.
SELECT 'OLTP: every order, TotalDue' AS Source, SUM(TotalDue) AS Revenue, MIN(OrderDate) AS FirstOrder, MAX(OrderDate) AS LastOrder
FROM AdventureWorks2022.Sales.SalesOrderHeader
UNION ALL
SELECT 'OLTP: online orders only, SubTotal', SUM(SubTotal), MIN(OrderDate), MAX(OrderDate)
FROM AdventureWorks2022.Sales.SalesOrderHeader WHERE OnlineOrderFlag = 1
UNION ALL
SELECT 'DW: FactInternetSales, SalesAmount', SUM(SalesAmount), MIN(OrderDate), MAX(OrderDate)
FROM AdventureWorksDW2022.dbo.FactInternetSales;
GO

-- Step 6. Customer with geography, OLTP: count the joins
-- Takeaway: Normalised means each fact is stored in exactly one place. It makes writes safe and cheap, and makes reads long.
USE AdventureWorks2022;
SELECT TOP 5 p.FirstName, p.LastName, a.City, sp.Name AS StateProvince, cr.Name AS Country
FROM Sales.Customer c
JOIN Person.Person p ON c.PersonID = p.BusinessEntityID
JOIN Person.BusinessEntityAddress bea ON p.BusinessEntityID = bea.BusinessEntityID
JOIN Person.Address a ON bea.AddressID = a.AddressID
JOIN Person.StateProvince sp ON a.StateProvinceID = sp.StateProvinceID
JOIN Person.CountryRegion cr ON sp.CountryRegionCode = cr.CountryRegionCode;
GO

-- Step 7. Customer with geography, warehouse: one join
-- Takeaway: Denormalising means copying descriptive data into fewer, wider tables so readers do not have to join. The warehouse pays the join cost once at load time instead of every time someone asks.
USE AdventureWorksDW2022;
SELECT TOP 5 c.FirstName, c.LastName, g.City, g.StateProvinceName, g.EnglishCountryRegionName
FROM dbo.DimCustomer c JOIN dbo.DimGeography g ON c.GeographyKey = g.GeographyKey;
GO

-- Step 8. Column count of a product: OLTP vs warehouse
-- Takeaway: Wider on purpose: DimProduct carries descriptions in eight languages, the model name, a photo and StartDate, EndDate and Status for price history, so a report never has to look anywhere else.
SELECT COUNT(*) AS OltpProductColumns FROM AdventureWorks2022.INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Product';
SELECT COUNT(*) AS DwProductColumns FROM AdventureWorksDW2022.INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'DimProduct';
GO

-- Step 9. What a wide dimension looks like
-- Takeaway: Day 16 explains the two keys: ProductKey is a surrogate key the warehouse invents, ProductAlternateKey is the natural key from the source.
SELECT TOP 3 * FROM AdventureWorksDW2022.dbo.DimProduct;
GO

-- ============================================================================
-- Self-test support
-- ============================================================================

-- Step 10. Matching table pairs: OLTP to warehouse
-- Takeaway: Equal row counts are a fast first test that a load copied everything. Where they differ, the difference should have a reason you can name.
SELECT 'Sales.SalesOrderDetail (online)' AS OltpTable, (SELECT COUNT(*) FROM AdventureWorks2022.Sales.SalesOrderDetail d
        JOIN AdventureWorks2022.Sales.SalesOrderHeader h ON h.SalesOrderID = d.SalesOrderID WHERE h.OnlineOrderFlag = 1) AS OltpRows,
       'FactInternetSales' AS DwTable, (SELECT COUNT(*) FROM AdventureWorksDW2022.dbo.FactInternetSales) AS DwRows
UNION ALL SELECT 'Production.Product', (SELECT COUNT(*) FROM AdventureWorks2022.Production.Product),
       'DimProduct', (SELECT COUNT(*) FROM AdventureWorksDW2022.dbo.DimProduct)
UNION ALL SELECT 'Sales.Customer (people)', (SELECT COUNT(*) FROM AdventureWorks2022.Sales.Customer WHERE PersonID IS NOT NULL AND StoreID IS NULL),
       'DimCustomer', (SELECT COUNT(*) FROM AdventureWorksDW2022.dbo.DimCustomer)
UNION ALL SELECT 'Sales.SalesTerritory', (SELECT COUNT(*) FROM AdventureWorks2022.Sales.SalesTerritory),
       'DimSalesTerritory', (SELECT COUNT(*) FROM AdventureWorksDW2022.dbo.DimSalesTerritory)
UNION ALL SELECT 'Sales.Store', (SELECT COUNT(*) FROM AdventureWorks2022.Sales.Store),
       'DimReseller', (SELECT COUNT(*) FROM AdventureWorksDW2022.dbo.DimReseller);
GO

