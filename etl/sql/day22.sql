-- Day 22: ETL vs ELT, staging, full and incremental extract
-- Run in order on AWPractice (reads AdventureWorks2022 on the same server).
-- https://noortayyababatool-spec.github.io/sql-syllabus/day22/

-- ==== Set up the staging area ====

-- 1. Two new schemas: stg for raw copies, etl for bookkeeping
USE AWPractice;
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');   -- staging: raw copies of source tables
IF SCHEMA_ID('etl') IS NULL EXEC('CREATE SCHEMA etl');   -- load log and watermarks
SELECT name AS SchemaName, schema_id FROM sys.schemas WHERE name IN ('stg', 'etl', 'dw', 'reporting');
GO

-- 2. A load log: every extract writes one row
IF OBJECT_ID('etl.LoadLog') IS NULL
    CREATE TABLE etl.LoadLog (
        LogID        INT IDENTITY PRIMARY KEY,
        Step         VARCHAR(30)  NOT NULL,      -- 'Extract full', 'Extract incremental'
        TableName    VARCHAR(60)  NOT NULL,
        RowsAffected INT          NOT NULL,
        StartedAt    DATETIME2(3) NOT NULL,
        EndedAt      DATETIME2(3) NOT NULL
    );
SELECT * FROM etl.LoadLog;
GO

-- ==== Full extract: copy what the warehouse needs, nothing more ====

-- 3. Extract the order headers from AdventureWorks2022
DECLARE @t0 DATETIME2(3) = SYSDATETIME();
DROP TABLE IF EXISTS stg.SalesOrderHeader;
SELECT SalesOrderID, OrderDate, DueDate, ShipDate, Status, OnlineOrderFlag, CustomerID, SalesPersonID,
       TerritoryID, SubTotal, TaxAmt, Freight, TotalDue, ModifiedDate,
       SYSDATETIME() AS ExtractedAt                              -- when this copy was taken
INTO stg.SalesOrderHeader
FROM AdventureWorks2022.Sales.SalesOrderHeader;
DECLARE @n INT = @@ROWCOUNT;                                     -- read it immediately
INSERT INTO etl.LoadLog VALUES ('Extract full', 'stg.SalesOrderHeader', @n, @t0, SYSDATETIME());
SELECT * FROM etl.LoadLog WHERE LogID = SCOPE_IDENTITY();
GO

-- 4. Extract the order lines
DECLARE @t0 DATETIME2(3) = SYSDATETIME();
DROP TABLE IF EXISTS stg.SalesOrderDetail;
SELECT SalesOrderID, SalesOrderDetailID, ProductID, OrderQty, UnitPrice, UnitPriceDiscount, LineTotal, ModifiedDate,
       SYSDATETIME() AS ExtractedAt
INTO stg.SalesOrderDetail
FROM AdventureWorks2022.Sales.SalesOrderDetail;
DECLARE @n INT = @@ROWCOUNT;
INSERT INTO etl.LoadLog VALUES ('Extract full', 'stg.SalesOrderDetail', @n, @t0, SYSDATETIME());
SELECT * FROM etl.LoadLog WHERE LogID = SCOPE_IDENTITY();
GO

-- 5. Extract customers with their name and home city
DECLARE @t0 DATETIME2(3) = SYSDATETIME();
DROP TABLE IF EXISTS stg.Customer;
SELECT c.CustomerID, c.PersonID, c.StoreID, c.TerritoryID, p.FirstName, p.LastName,
       a.City, sp.CountryRegionCode, c.ModifiedDate, SYSDATETIME() AS ExtractedAt
INTO stg.Customer
FROM AdventureWorks2022.Sales.Customer c
LEFT JOIN AdventureWorks2022.Person.Person p ON p.BusinessEntityID = c.PersonID
LEFT JOIN AdventureWorks2022.Person.BusinessEntityAddress bea
       ON bea.BusinessEntityID = c.PersonID AND bea.AddressTypeID = 2          -- 2 = Home
LEFT JOIN AdventureWorks2022.Person.Address a        ON a.AddressID = bea.AddressID
LEFT JOIN AdventureWorks2022.Person.StateProvince sp ON sp.StateProvinceID = a.StateProvinceID;
DECLARE @n INT = @@ROWCOUNT;
INSERT INTO etl.LoadLog VALUES ('Extract full', 'stg.Customer', @n, @t0, SYSDATETIME());
SELECT * FROM etl.LoadLog WHERE LogID = SCOPE_IDENTITY();
GO

-- 6. Extract products from the practice copy (the "source system" this week)
DECLARE @t0 DATETIME2(3) = SYSDATETIME();
DROP TABLE IF EXISTS stg.Product;
SELECT ProductID, Name, ProductNumber, Color, StandardCost, ListPrice, ProductSubcategoryID, ModifiedDate,
       SYSDATETIME() AS ExtractedAt
INTO stg.Product
FROM dbo.Product;                                 -- AWPractice copy, so changes can be simulated safely
DECLARE @n INT = @@ROWCOUNT;
INSERT INTO etl.LoadLog VALUES ('Extract full', 'stg.Product', @n, @t0, SYSDATETIME());
SELECT * FROM etl.LoadLog WHERE LogID = SCOPE_IDENTITY();
GO

-- 7. Reconcile: does staging match the source?
SELECT 'SalesOrderHeader' AS TableName,
       (SELECT COUNT(*) FROM AdventureWorks2022.Sales.SalesOrderHeader) AS SourceRows,
       (SELECT COUNT(*) FROM stg.SalesOrderHeader) AS StagingRows,
       (SELECT SUM(TotalDue) FROM AdventureWorks2022.Sales.SalesOrderHeader) AS SourceTotal,
       (SELECT SUM(TotalDue) FROM stg.SalesOrderHeader) AS StagingTotal
UNION ALL
SELECT 'SalesOrderDetail', (SELECT COUNT(*) FROM AdventureWorks2022.Sales.SalesOrderDetail),
       (SELECT COUNT(*) FROM stg.SalesOrderDetail),
       (SELECT SUM(LineTotal) FROM AdventureWorks2022.Sales.SalesOrderDetail), (SELECT SUM(LineTotal) FROM stg.SalesOrderDetail)
UNION ALL
SELECT 'Customer', (SELECT COUNT(*) FROM AdventureWorks2022.Sales.Customer), (SELECT COUNT(*) FROM stg.Customer), NULL, NULL
UNION ALL
SELECT 'Product', (SELECT COUNT(*) FROM dbo.Product), (SELECT COUNT(*) FROM stg.Product),
       (SELECT SUM(ListPrice) FROM dbo.Product), (SELECT SUM(ListPrice) FROM stg.Product);
GO

-- 8. Read the log
SELECT LogID, Step, TableName, RowsAffected, StartedAt, EndedAt,
       DATEDIFF(millisecond, StartedAt, EndedAt) AS Ms
FROM etl.LoadLog ORDER BY LogID;
GO

-- ==== Incremental extract: only what changed since last time ====

-- 9. A watermark table, set to where the full extract finished
IF OBJECT_ID('etl.Watermark') IS NULL
    CREATE TABLE etl.Watermark (TableName VARCHAR(60) PRIMARY KEY, LastModified DATETIME NOT NULL);
DELETE FROM etl.Watermark WHERE TableName = 'dbo.Product';
INSERT INTO etl.Watermark SELECT 'dbo.Product', MAX(ModifiedDate) FROM stg.Product;
SELECT * FROM etl.Watermark;
GO

-- 10. What has changed since the watermark?
SELECT p.ProductID, p.Name, p.ListPrice, p.ModifiedDate
FROM dbo.Product p
WHERE p.ModifiedDate > (SELECT LastModified FROM etl.Watermark WHERE TableName = 'dbo.Product');
GO

-- 11. The source system changes: two new prices and one new product
UPDATE dbo.Product SET ListPrice = 1499.00, ModifiedDate = '2026-11-13 09:00' WHERE ProductID = 680;
UPDATE dbo.Product SET ListPrice = 6.49,    ModifiedDate = '2026-11-13 09:00' WHERE ProductID = 1001;
IF NOT EXISTS (SELECT 1 FROM dbo.Product WHERE ProductNumber = 'PR-1005')
    INSERT INTO dbo.Product (Name, ProductNumber, MakeFlag, FinishedGoodsFlag, SafetyStockLevel, ReorderPoint,
                             StandardCost, ListPrice, DaysToManufacture, SellStartDate, rowguid, ModifiedDate)
    VALUES ('Practice Light', 'PR-1005', 0, 1, 4, 3, 7.50, 17.99, 0, '2026-11-13', NEWID(), '2026-11-13 09:00');
SELECT ProductID, Name, ListPrice, ModifiedDate FROM dbo.Product WHERE ModifiedDate >= '2026-11-13';
GO

-- 12. Ask again: what has changed?
SELECT p.ProductID, p.Name, p.ListPrice, p.ModifiedDate
FROM dbo.Product p
WHERE p.ModifiedDate > (SELECT LastModified FROM etl.Watermark WHERE TableName = 'dbo.Product');
GO

-- 13. The incremental extract: copy the changes, then move the watermark
DECLARE @t0 DATETIME2(3) = SYSDATETIME();
DECLARE @wm DATETIME = (SELECT LastModified FROM etl.Watermark WHERE TableName = 'dbo.Product');
DROP TABLE IF EXISTS stg.ProductDelta;
SELECT ProductID, Name, ProductNumber, Color, StandardCost, ListPrice, ProductSubcategoryID, ModifiedDate,
       SYSDATETIME() AS ExtractedAt
INTO stg.ProductDelta
FROM dbo.Product WHERE ModifiedDate > @wm;
DECLARE @n INT = @@ROWCOUNT;
UPDATE etl.Watermark SET LastModified = ISNULL((SELECT MAX(ModifiedDate) FROM stg.ProductDelta), @wm)
WHERE TableName = 'dbo.Product';
INSERT INTO etl.LoadLog VALUES ('Extract incremental', 'stg.ProductDelta', @n, @t0, SYSDATETIME());
SELECT @wm AS OldWatermark, (SELECT LastModified FROM etl.Watermark WHERE TableName = 'dbo.Product') AS NewWatermark,
       @n AS RowsExtracted;
GO

-- 14. Run exactly the same extract again
DECLARE @t0 DATETIME2(3) = SYSDATETIME();
DECLARE @wm DATETIME = (SELECT LastModified FROM etl.Watermark WHERE TableName = 'dbo.Product');
DROP TABLE IF EXISTS stg.ProductDelta;
SELECT ProductID, Name, ProductNumber, Color, StandardCost, ListPrice, ProductSubcategoryID, ModifiedDate,
       SYSDATETIME() AS ExtractedAt
INTO stg.ProductDelta
FROM dbo.Product WHERE ModifiedDate > @wm;
DECLARE @n INT = @@ROWCOUNT;
UPDATE etl.Watermark SET LastModified = ISNULL((SELECT MAX(ModifiedDate) FROM stg.ProductDelta), @wm)
WHERE TableName = 'dbo.Product';
INSERT INTO etl.LoadLog VALUES ('Extract incremental', 'stg.ProductDelta', @n, @t0, SYSDATETIME());
SELECT @wm AS OldWatermark, (SELECT LastModified FROM etl.Watermark WHERE TableName = 'dbo.Product') AS NewWatermark,
       @n AS RowsExtracted;
GO

-- 15. Full vs incremental in the log
SELECT LogID, Step, TableName, RowsAffected, DATEDIFF(millisecond, StartedAt, EndedAt) AS Ms
FROM etl.LoadLog ORDER BY LogID;
GO

-- ==== Profile what was extracted (before cleaning it on Day 23) ====

-- 16. Profile the order headers
SELECT COUNT(*) AS Orders, COUNT(DISTINCT CustomerID) AS Customers,
       SUM(CASE WHEN SalesPersonID IS NULL THEN 1 ELSE 0 END) AS NoSalesPerson,
       SUM(CASE WHEN OnlineOrderFlag = 1 THEN 1 ELSE 0 END) AS OnlineOrders,
       SUM(CASE WHEN ShipDate IS NULL THEN 1 ELSE 0 END) AS NotShipped,
       MIN(OrderDate) AS FirstOrder, MAX(OrderDate) AS LastOrder
FROM stg.SalesOrderHeader;
GO

-- 17. Profile the customers: what is missing?
SELECT COUNT(*) AS Customers,
       SUM(CASE WHEN PersonID IS NULL THEN 1 ELSE 0 END)  AS NoPerson,
       SUM(CASE WHEN StoreID  IS NULL THEN 1 ELSE 0 END)  AS NoStore,
       SUM(CASE WHEN FirstName IS NULL THEN 1 ELSE 0 END) AS NoName,
       SUM(CASE WHEN City IS NULL THEN 1 ELSE 0 END)      AS NoCity,
       COUNT(DISTINCT City) AS Cities, COUNT(DISTINCT CountryRegionCode) AS Countries
FROM stg.Customer;
GO
