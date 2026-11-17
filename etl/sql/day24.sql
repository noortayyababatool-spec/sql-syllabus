-- Day 24: Load: dimensions, history and the fact table
-- Run in order on AWPractice after day23.sql.
-- https://noortayyababatool-spec.github.io/sql-syllabus/day24/

-- ==== The date and customer dimensions (Type 1) ====

-- 1. Create the dw schema and load a date dimension
USE AWPractice;
IF SCHEMA_ID('dw') IS NULL EXEC('CREATE SCHEMA dw');
DROP TABLE IF EXISTS dw.FactSales, dw.DimDate, dw.DimCustomer, dw.DimProduct;   -- fact first: it points at the others
CREATE TABLE dw.DimDate (
    DateKey   INT         NOT NULL PRIMARY KEY,      -- yyyymmdd, the same rule as etl.vSalesLine
    FullDate  DATE        NOT NULL,
    [Year]    SMALLINT    NOT NULL,
    [Quarter] TINYINT     NOT NULL,
    [Month]   TINYINT     NOT NULL,
    MonthName VARCHAR(10) NOT NULL,
    DayName   VARCHAR(10) NOT NULL,
    IsWeekend BIT         NOT NULL);
DECLARE @t0 DATETIME2(3) = SYSDATETIME(), @n INT;
WITH n AS (SELECT TOP (DATEDIFF(day, '2011-01-01', '2026-12-31') + 1)
                  ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
           FROM sys.all_objects a CROSS JOIN sys.all_objects b),
     d AS (SELECT DATEADD(day, i, CAST('2011-01-01' AS DATE)) AS FullDate FROM n)
INSERT INTO dw.DimDate
SELECT YEAR(FullDate) * 10000 + MONTH(FullDate) * 100 + DAY(FullDate), FullDate,
       YEAR(FullDate), DATEPART(quarter, FullDate), MONTH(FullDate),
       DATENAME(month, FullDate), DATENAME(weekday, FullDate),
       CASE WHEN DATENAME(weekday, FullDate) IN ('Saturday', 'Sunday') THEN 1 ELSE 0 END
FROM d;
SET @n = @@ROWCOUNT;
INSERT INTO etl.LoadLog VALUES ('Load full', 'dw.DimDate', @n, @t0, SYSDATETIME());
SELECT COUNT(*) AS Days, MIN(FullDate) AS FirstDay, MAX(FullDate) AS LastDay,
       SUM(CAST(IsWeekend AS INT)) AS WeekendDays FROM dw.DimDate;
GO

-- 2. The customer dimension: a surrogate key and an Unknown member
CREATE TABLE dw.DimCustomer (
    CustomerKey  INT IDENTITY(1, 1) NOT NULL PRIMARY KEY,   -- surrogate key: the warehouse's own number
    CustomerID   INT           NOT NULL UNIQUE,             -- business key: the source's number
    CustomerType VARCHAR(13)   NOT NULL,
    CustomerName NVARCHAR(101) NULL,
    StoreName    NVARCHAR(50)  NOT NULL,
    City         NVARCHAR(30)  NOT NULL,
    Country      VARCHAR(20)   NOT NULL,
    LoadedAt     DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
    UpdatedAt    DATETIME2(0)  NULL);
SET IDENTITY_INSERT dw.DimCustomer ON;
INSERT INTO dw.DimCustomer (CustomerKey, CustomerID, CustomerType, CustomerName, StoreName, City, Country)
VALUES (-1, -1, 'Unknown', 'Unknown customer', 'Unknown', 'Unknown', 'Unknown');
SET IDENTITY_INSERT dw.DimCustomer OFF;
SELECT CustomerKey, CustomerID, CustomerType, CustomerName, City FROM dw.DimCustomer;
GO

-- 3. First load: MERGE inserts every customer
DECLARE @t0 DATETIME2(3) = SYSDATETIME();
DECLARE @a TABLE (act NVARCHAR(10));
MERGE dw.DimCustomer AS t
USING etl.vCustomer AS s ON t.CustomerID = s.CustomerID
WHEN MATCHED AND (t.CustomerType <> s.CustomerType OR ISNULL(t.CustomerName, '') <> ISNULL(s.CustomerName, '')
               OR t.StoreName <> s.StoreName OR t.City <> s.City OR t.Country <> s.Country)
  THEN UPDATE SET CustomerType = s.CustomerType, CustomerName = s.CustomerName, StoreName = s.StoreName,
                  City = s.City, Country = s.Country, UpdatedAt = SYSDATETIME()       -- Type 1: overwrite
WHEN NOT MATCHED BY TARGET
  THEN INSERT (CustomerID, CustomerType, CustomerName, StoreName, City, Country)
       VALUES (s.CustomerID, s.CustomerType, s.CustomerName, s.StoreName, s.City, s.Country)
OUTPUT $action INTO @a;
INSERT INTO etl.LoadLog SELECT 'Load Type 1', 'dw.DimCustomer', COUNT(*), @t0, SYSDATETIME() FROM @a;
SELECT (SELECT COUNT(*) FROM @a WHERE act = 'INSERT') AS Inserted,
       (SELECT COUNT(*) FROM @a WHERE act = 'UPDATE') AS Updated,
       (SELECT COUNT(*) FROM dw.DimCustomer)          AS RowsInDimension;
GO

-- 4. Run the same load again: nothing changes
DECLARE @t0 DATETIME2(3) = SYSDATETIME();
DECLARE @a TABLE (act NVARCHAR(10));
MERGE dw.DimCustomer AS t
USING etl.vCustomer AS s ON t.CustomerID = s.CustomerID
WHEN MATCHED AND (t.CustomerType <> s.CustomerType OR ISNULL(t.CustomerName, '') <> ISNULL(s.CustomerName, '')
               OR t.StoreName <> s.StoreName OR t.City <> s.City OR t.Country <> s.Country)
  THEN UPDATE SET CustomerType = s.CustomerType, CustomerName = s.CustomerName, StoreName = s.StoreName,
                  City = s.City, Country = s.Country, UpdatedAt = SYSDATETIME()       -- Type 1: overwrite
WHEN NOT MATCHED BY TARGET
  THEN INSERT (CustomerID, CustomerType, CustomerName, StoreName, City, Country)
       VALUES (s.CustomerID, s.CustomerType, s.CustomerName, s.StoreName, s.City, s.Country)
OUTPUT $action INTO @a;
INSERT INTO etl.LoadLog SELECT 'Load Type 1', 'dw.DimCustomer', COUNT(*), @t0, SYSDATETIME() FROM @a;
SELECT (SELECT COUNT(*) FROM @a WHERE act = 'INSERT') AS Inserted,
       (SELECT COUNT(*) FROM @a WHERE act = 'UPDATE') AS Updated,
       (SELECT COUNT(*) FROM dw.DimCustomer)          AS RowsInDimension;
GO

-- 5. A customer moves: Type 1 overwrites the old city
DECLARE @old NVARCHAR(30) = (SELECT City FROM dw.DimCustomer WHERE CustomerID = 11000);   -- before
UPDATE stg.Customer SET City = 'Brisbane' WHERE CustomerID = 11000;   -- the next extract brings the new address
DECLARE @t0 DATETIME2(3) = SYSDATETIME();
DECLARE @a TABLE (act NVARCHAR(10));
MERGE dw.DimCustomer AS t
USING etl.vCustomer AS s ON t.CustomerID = s.CustomerID
WHEN MATCHED AND (t.CustomerType <> s.CustomerType OR ISNULL(t.CustomerName, '') <> ISNULL(s.CustomerName, '')
               OR t.StoreName <> s.StoreName OR t.City <> s.City OR t.Country <> s.Country)
  THEN UPDATE SET CustomerType = s.CustomerType, CustomerName = s.CustomerName, StoreName = s.StoreName,
                  City = s.City, Country = s.Country, UpdatedAt = SYSDATETIME()       -- Type 1: overwrite
WHEN NOT MATCHED BY TARGET
  THEN INSERT (CustomerID, CustomerType, CustomerName, StoreName, City, Country)
       VALUES (s.CustomerID, s.CustomerType, s.CustomerName, s.StoreName, s.City, s.Country)
OUTPUT $action INTO @a;
INSERT INTO etl.LoadLog SELECT 'Load Type 1', 'dw.DimCustomer', COUNT(*), @t0, SYSDATETIME() FROM @a;
SELECT CustomerKey, CustomerName, @old AS OldCity, City, UpdatedAt,
       (SELECT COUNT(*) FROM @a WHERE act = 'UPDATE') AS RowsUpdated
FROM dw.DimCustomer WHERE CustomerID = 11000;   -- after
GO

-- ==== The product dimension keeps history (Type 2) ====

-- 6. The product dimension: one row per version of a product
CREATE TABLE dw.DimProduct (
    ProductKey    INT IDENTITY(1, 1) NOT NULL PRIMARY KEY,
    ProductID     INT          NOT NULL,     -- business key: no longer unique, one row per version
    ProductNumber NVARCHAR(25) NOT NULL,
    ProductName   NVARCHAR(50) NOT NULL,
    Colour        NVARCHAR(15) NOT NULL,
    Subcategory   NVARCHAR(50) NOT NULL,
    Category      NVARCHAR(50) NOT NULL,
    ListPrice     MONEY        NOT NULL,
    PriceBand     VARCHAR(15)  NOT NULL,
    ValidFrom     DATETIME     NOT NULL,
    ValidTo       DATETIME     NOT NULL,     -- 9999-12-31 for the current version
    IsCurrent     BIT          NOT NULL);
CREATE UNIQUE INDEX UX_DimProduct_Current ON dw.DimProduct (ProductID) WHERE IsCurrent = 1;   -- one current version each
SET IDENTITY_INSERT dw.DimProduct ON;
INSERT INTO dw.DimProduct (ProductKey, ProductID, ProductNumber, ProductName, Colour, Subcategory, Category,
                           ListPrice, PriceBand, ValidFrom, ValidTo, IsCurrent)
VALUES (-1, -1, 'Unknown', 'Unknown product', 'Unknown', 'Unknown', 'Unknown', 0, 'Unknown', '1900-01-01', '9999-12-31', 1);
SET IDENTITY_INSERT dw.DimProduct OFF;
DECLARE @t0 DATETIME2(3) = SYSDATETIME(), @n INT;
INSERT INTO dw.DimProduct (ProductID, ProductNumber, ProductName, Colour, Subcategory, Category,
                           ListPrice, PriceBand, ValidFrom, ValidTo, IsCurrent)
SELECT ProductID, ProductNumber, ProductName, Colour, Subcategory, Category,
       ListPrice, PriceBand, '1900-01-01', '9999-12-31', 1          -- first version: valid for all past orders
FROM etl.vProduct;
SET @n = @@ROWCOUNT;
INSERT INTO etl.LoadLog VALUES ('Load full', 'dw.DimProduct', @n, @t0, SYSDATETIME());
SELECT ProductKey, ProductID, ProductName, ListPrice, PriceBand, ValidFrom, ValidTo, IsCurrent
FROM dw.DimProduct WHERE ProductID IN (-1, 680, 1001) ORDER BY ProductID;
GO

-- 7. The changes from Day 22 never arrived: rewind the watermark
-- Day 22's second incremental run replaced the 3 changed rows with 0 before anything loaded them.
UPDATE etl.Watermark SET LastModified = '2026-10-16 17:51:46.010'   -- exactly the Day 22 value
WHERE TableName = 'dbo.Product';
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

-- 8. Apply the changes to staging with MERGE
DECLARE @t0 DATETIME2(3) = SYSDATETIME(), @n INT;
SET IDENTITY_INSERT stg.Product ON;    -- SELECT INTO copied the IDENTITY property from the source
MERGE stg.Product AS t
USING stg.ProductDelta AS s ON t.ProductID = s.ProductID
WHEN MATCHED THEN
  UPDATE SET Name = s.Name, ProductNumber = s.ProductNumber, Color = s.Color, StandardCost = s.StandardCost,
             ListPrice = s.ListPrice, ProductSubcategoryID = s.ProductSubcategoryID,
             ModifiedDate = s.ModifiedDate, ExtractedAt = s.ExtractedAt
WHEN NOT MATCHED BY TARGET THEN
  INSERT (ProductID, Name, ProductNumber, Color, StandardCost, ListPrice, ProductSubcategoryID, ModifiedDate, ExtractedAt)
  VALUES (s.ProductID, s.Name, s.ProductNumber, s.Color, s.StandardCost, s.ListPrice, s.ProductSubcategoryID,
          s.ModifiedDate, s.ExtractedAt)
OUTPUT $action AS Action, inserted.ProductID, inserted.Name, deleted.ListPrice AS OldPrice, inserted.ListPrice AS NewPrice;
SET @n = @@ROWCOUNT;
SET IDENTITY_INSERT stg.Product OFF;
INSERT INTO etl.LoadLog VALUES ('Merge delta', 'stg.Product', @n, @t0, SYSDATETIME());
GO

-- 9. The Type 2 load: close the old version, add the new one
SET XACT_ABORT ON;    -- any error rolls back the whole transaction (Day 20)
DECLARE @t0 DATETIME2(3) = SYSDATETIME(), @closed INT, @added INT;
BEGIN TRANSACTION;
-- a) Close the current version of every product whose price has changed
UPDATE d SET ValidTo = s.ModifiedDate, IsCurrent = 0
FROM dw.DimProduct d
JOIN etl.vProduct s ON s.ProductID = d.ProductID
WHERE d.IsCurrent = 1 AND d.ListPrice <> s.ListPrice;
SET @closed = @@ROWCOUNT;
-- b) Add a current version for every product that now has none: changed products and new products
INSERT INTO dw.DimProduct (ProductID, ProductNumber, ProductName, Colour, Subcategory, Category,
                           ListPrice, PriceBand, ValidFrom, ValidTo, IsCurrent)
SELECT s.ProductID, s.ProductNumber, s.ProductName, s.Colour, s.Subcategory, s.Category,
       s.ListPrice, s.PriceBand, s.ModifiedDate, '9999-12-31', 1
FROM etl.vProduct s
WHERE NOT EXISTS (SELECT 1 FROM dw.DimProduct d WHERE d.ProductID = s.ProductID AND d.IsCurrent = 1);
SET @added = @@ROWCOUNT;
COMMIT;
INSERT INTO etl.LoadLog VALUES ('Load Type 2 close', 'dw.DimProduct', @closed, @t0, SYSDATETIME()),
                               ('Load Type 2 add',   'dw.DimProduct', @added,  @t0, SYSDATETIME());
SELECT @closed AS VersionsClosed, @added AS VersionsAdded, (SELECT COUNT(*) FROM dw.DimProduct) AS RowsInDimension;
GO

-- 10. One product, two versions
SELECT ProductKey, ProductID, ProductName, ListPrice, PriceBand, ValidFrom, ValidTo, IsCurrent
FROM dw.DimProduct WHERE ProductID IN (680, 1001, 1005) ORDER BY ProductID, ValidFrom;
GO

-- 11. Run the Type 2 load again: nothing changes
SET XACT_ABORT ON;    -- any error rolls back the whole transaction (Day 20)
DECLARE @t0 DATETIME2(3) = SYSDATETIME(), @closed INT, @added INT;
BEGIN TRANSACTION;
-- a) Close the current version of every product whose price has changed
UPDATE d SET ValidTo = s.ModifiedDate, IsCurrent = 0
FROM dw.DimProduct d
JOIN etl.vProduct s ON s.ProductID = d.ProductID
WHERE d.IsCurrent = 1 AND d.ListPrice <> s.ListPrice;
SET @closed = @@ROWCOUNT;
-- b) Add a current version for every product that now has none: changed products and new products
INSERT INTO dw.DimProduct (ProductID, ProductNumber, ProductName, Colour, Subcategory, Category,
                           ListPrice, PriceBand, ValidFrom, ValidTo, IsCurrent)
SELECT s.ProductID, s.ProductNumber, s.ProductName, s.Colour, s.Subcategory, s.Category,
       s.ListPrice, s.PriceBand, s.ModifiedDate, '9999-12-31', 1
FROM etl.vProduct s
WHERE NOT EXISTS (SELECT 1 FROM dw.DimProduct d WHERE d.ProductID = s.ProductID AND d.IsCurrent = 1);
SET @added = @@ROWCOUNT;
COMMIT;
INSERT INTO etl.LoadLog VALUES ('Load Type 2 close', 'dw.DimProduct', @closed, @t0, SYSDATETIME()),
                               ('Load Type 2 add',   'dw.DimProduct', @added,  @t0, SYSDATETIME());
SELECT @closed AS VersionsClosed, @added AS VersionsAdded, (SELECT COUNT(*) FROM dw.DimProduct) AS RowsInDimension;
GO

-- ==== The fact table: surrogate key lookups ====

-- 12. The fact table: keys to the dimensions, then the numbers
CREATE TABLE dw.FactSales (
    SalesOrderID       INT           NOT NULL,     -- degenerate dimension: the order number, no table of its own
    SalesOrderDetailID INT           NOT NULL,
    OrderDateKey       INT           NOT NULL REFERENCES dw.DimDate (DateKey),
    CustomerKey        INT           NOT NULL REFERENCES dw.DimCustomer (CustomerKey),
    ProductKey         INT           NOT NULL REFERENCES dw.DimProduct (ProductKey),
    SalesChannel       VARCHAR(8)    NOT NULL,
    Quantity           SMALLINT      NOT NULL,
    UnitPrice          MONEY         NOT NULL,
    SalesAmount        DECIMAL(19,4) NOT NULL,
    LoadedAt           DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_FactSales PRIMARY KEY (SalesOrderID, SalesOrderDetailID));
SELECT c.name AS ColumnName, TYPE_NAME(c.user_type_id) AS DataType,
       OBJECT_NAME(fkc.referenced_object_id) AS PointsTo
FROM sys.columns c
LEFT JOIN sys.foreign_key_columns fkc ON fkc.parent_object_id = c.object_id AND fkc.parent_column_id = c.column_id
WHERE c.object_id = OBJECT_ID('dw.FactSales') ORDER BY c.column_id;
GO

-- 13. Load the fact: swap business keys for surrogate keys
DECLARE @t0 DATETIME2(3) = SYSDATETIME(), @n INT;
INSERT INTO dw.FactSales (SalesOrderID, SalesOrderDetailID, OrderDateKey, CustomerKey, ProductKey,
                          SalesChannel, Quantity, UnitPrice, SalesAmount)
SELECT s.SalesOrderID, s.SalesOrderDetailID, s.OrderDateKey,
       ISNULL(c.CustomerKey, -1),                        -- not found: the Unknown member
       ISNULL(p.ProductKey, -1),
       s.SalesChannel, s.Quantity, s.UnitPrice, s.SalesAmount
FROM etl.vSalesLine s
JOIN dw.DimDate dd         ON dd.DateKey = s.OrderDateKey
LEFT JOIN dw.DimCustomer c ON c.CustomerID = s.CustomerID
LEFT JOIN dw.DimProduct p  ON p.ProductID = s.ProductID
                          AND dd.FullDate >= p.ValidFrom AND dd.FullDate < p.ValidTo   -- version valid on the order date
WHERE NOT EXISTS (SELECT 1 FROM dw.FactSales f
                  WHERE f.SalesOrderID = s.SalesOrderID AND f.SalesOrderDetailID = s.SalesOrderDetailID);
SET @n = @@ROWCOUNT;
INSERT INTO etl.LoadLog VALUES ('Load incremental', 'dw.FactSales', @n, @t0, SYSDATETIME());
SELECT @n AS RowsLoaded, (SELECT COUNT(*) FROM dw.FactSales) AS RowsInFact;
GO

-- 14. Did every line arrive, and did every key resolve?
SELECT COUNT(*) AS FactRows,
       (SELECT COUNT(*) FROM etl.vSalesLine)        AS SourceLines,
       SUM(SalesAmount)                             AS FactRevenue,
       (SELECT SUM(SalesAmount) FROM etl.vSalesLine) AS SourceRevenue,
       SUM(CASE WHEN CustomerKey = -1 THEN 1 ELSE 0 END) AS UnknownCustomer,
       SUM(CASE WHEN ProductKey  = -1 THEN 1 ELSE 0 END) AS UnknownProduct
FROM dw.FactSales;
GO

-- 15. A new order arrives before its customer does
-- Order 75124, 14 November 2026: customer 30119 is new and is not in the customer extract yet
SET IDENTITY_INSERT stg.SalesOrderHeader ON;     -- staging keeps the source numbers
INSERT INTO stg.SalesOrderHeader (SalesOrderID, OrderDate, DueDate, ShipDate, Status, OnlineOrderFlag, CustomerID,
            SalesPersonID, TerritoryID, SubTotal, TaxAmt, Freight, TotalDue, ModifiedDate, ExtractedAt)
VALUES (75124, '2026-11-14', '2026-11-21', NULL, 1, 1, 30119, NULL, 9, 1534.98, 122.80, 38.37, 1696.15,
        '2026-11-14', SYSDATETIME());
SET IDENTITY_INSERT stg.SalesOrderHeader OFF;
SET IDENTITY_INSERT stg.SalesOrderDetail ON;
INSERT INTO stg.SalesOrderDetail (SalesOrderID, SalesOrderDetailID, ProductID, OrderQty, UnitPrice,
            UnitPriceDiscount, LineTotal, ModifiedDate, ExtractedAt)
VALUES (75124, 121318, 680,  1, 1499.00, 0, 1499.00, '2026-11-14', SYSDATETIME()),
       (75124, 121319, 1005, 2,   17.99, 0,   35.98, '2026-11-14', SYSDATETIME());
SET IDENTITY_INSERT stg.SalesOrderDetail OFF;
DECLARE @t0 DATETIME2(3) = SYSDATETIME(), @n INT;
INSERT INTO dw.FactSales (SalesOrderID, SalesOrderDetailID, OrderDateKey, CustomerKey, ProductKey,
                          SalesChannel, Quantity, UnitPrice, SalesAmount)
SELECT s.SalesOrderID, s.SalesOrderDetailID, s.OrderDateKey,
       ISNULL(c.CustomerKey, -1),                        -- not found: the Unknown member
       ISNULL(p.ProductKey, -1),
       s.SalesChannel, s.Quantity, s.UnitPrice, s.SalesAmount
FROM etl.vSalesLine s
JOIN dw.DimDate dd         ON dd.DateKey = s.OrderDateKey
LEFT JOIN dw.DimCustomer c ON c.CustomerID = s.CustomerID
LEFT JOIN dw.DimProduct p  ON p.ProductID = s.ProductID
                          AND dd.FullDate >= p.ValidFrom AND dd.FullDate < p.ValidTo   -- version valid on the order date
WHERE NOT EXISTS (SELECT 1 FROM dw.FactSales f
                  WHERE f.SalesOrderID = s.SalesOrderID AND f.SalesOrderDetailID = s.SalesOrderDetailID);
SET @n = @@ROWCOUNT;
INSERT INTO etl.LoadLog VALUES ('Load incremental', 'dw.FactSales', @n, @t0, SYSDATETIME());
SELECT @n AS RowsLoaded, (SELECT COUNT(*) FROM dw.FactSales) AS RowsInFact;
GO

-- 16. Where did the new lines go?
SELECT f.SalesOrderDetailID, f.OrderDateKey, f.CustomerKey, c.CustomerName,
       f.ProductKey, p.ProductName, p.ListPrice, p.IsCurrent, f.Quantity, f.SalesAmount
FROM dw.FactSales f
JOIN dw.DimCustomer c ON c.CustomerKey = f.CustomerKey
JOIN dw.DimProduct p  ON p.ProductKey  = f.ProductKey
WHERE f.SalesOrderID = 75124;
GO

-- 17. Why LEFT JOIN: what an INNER JOIN would have lost
SELECT (SELECT COUNT(*) FROM etl.vSalesLine) AS LinesInSource,
       (SELECT COUNT(*) FROM etl.vSalesLine s
        JOIN dw.DimCustomer c ON c.CustomerID = s.CustomerID) AS LinesWithInnerJoin,
       (SELECT SUM(s.SalesAmount) FROM etl.vSalesLine s
        WHERE NOT EXISTS (SELECT 1 FROM dw.DimCustomer c WHERE c.CustomerID = s.CustomerID)) AS RevenueLost;
GO

-- 18. The customer arrives: load it and repair the fact
INSERT INTO stg.Customer (CustomerID, PersonID, StoreID, TerritoryID, FirstName, LastName, City,
                          CountryRegionCode, ModifiedDate, ExtractedAt)
VALUES (30119, 20778, NULL, 9, 'Sana', 'Iqbal', 'Sydney', 'AU', '2026-11-15', SYSDATETIME());
DECLARE @t0 DATETIME2(3) = SYSDATETIME();
DECLARE @a TABLE (act NVARCHAR(10));
MERGE dw.DimCustomer AS t
USING etl.vCustomer AS s ON t.CustomerID = s.CustomerID
WHEN MATCHED AND (t.CustomerType <> s.CustomerType OR ISNULL(t.CustomerName, '') <> ISNULL(s.CustomerName, '')
               OR t.StoreName <> s.StoreName OR t.City <> s.City OR t.Country <> s.Country)
  THEN UPDATE SET CustomerType = s.CustomerType, CustomerName = s.CustomerName, StoreName = s.StoreName,
                  City = s.City, Country = s.Country, UpdatedAt = SYSDATETIME()       -- Type 1: overwrite
WHEN NOT MATCHED BY TARGET
  THEN INSERT (CustomerID, CustomerType, CustomerName, StoreName, City, Country)
       VALUES (s.CustomerID, s.CustomerType, s.CustomerName, s.StoreName, s.City, s.Country)
OUTPUT $action INTO @a;
INSERT INTO etl.LoadLog SELECT 'Load Type 1', 'dw.DimCustomer', COUNT(*), @t0, SYSDATETIME() FROM @a;
UPDATE f SET CustomerKey = c.CustomerKey
FROM dw.FactSales f
JOIN stg.SalesOrderHeader h ON h.SalesOrderID = f.SalesOrderID
JOIN dw.DimCustomer c       ON c.CustomerID   = h.CustomerID
WHERE f.CustomerKey = -1;
SELECT f.SalesOrderDetailID, f.CustomerKey, c.CustomerName, c.City, f.SalesAmount,
       (SELECT COUNT(*) FROM @a WHERE act = 'INSERT') AS CustomersInserted
FROM dw.FactSales f JOIN dw.DimCustomer c ON c.CustomerKey = f.CustomerKey
WHERE f.SalesOrderID = 75124;
GO

-- 19. The star answers its first question
SELECT d.[Year], p.Category, COUNT(*) AS Lines, SUM(f.SalesAmount) AS Revenue
FROM dw.FactSales f
JOIN dw.DimDate d    ON d.DateKey    = f.OrderDateKey
JOIN dw.DimProduct p ON p.ProductKey = f.ProductKey
GROUP BY d.[Year], p.Category
ORDER BY d.[Year], Revenue DESC;
GO

-- 20. What the load did today
SELECT LogID, Step, TableName, RowsAffected FROM etl.LoadLog WHERE LogID > 9 ORDER BY LogID;
GO
