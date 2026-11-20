-- Day 25: Data validation: checks, severities and a gate
-- Run in order on AWPractice after day24.sql.
-- https://noortayyababatool-spec.github.io/sql-syllabus/day25/

-- ==== Somewhere to record the results ====

-- 1. A run table and a results table
USE AWPractice;
DROP TABLE IF EXISTS etl.DQResult, etl.DQRun;
CREATE TABLE etl.DQRun (
    RunID     INT IDENTITY(1, 1) PRIMARY KEY,
    StartedAt DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    EndedAt   DATETIME2(0) NULL,
    Errors    INT NULL,
    Warnings  INT NULL);
CREATE TABLE etl.DQResult (
    ResultID   INT IDENTITY(1, 1) PRIMARY KEY,
    RunID      INT         NOT NULL REFERENCES etl.DQRun (RunID),
    CheckName  VARCHAR(60) NOT NULL,
    Category   VARCHAR(20) NOT NULL,
    Severity   VARCHAR(7)  NOT NULL CHECK (Severity IN ('Error', 'Warning')),
    FailedRows INT         NOT NULL,
    Status AS (CASE WHEN FailedRows = 0 THEN 'Pass' WHEN Severity = 'Error' THEN 'Fail' ELSE 'Warning' END),
    CheckedAt  DATETIME2(0) NOT NULL DEFAULT SYSDATETIME());
INSERT INTO etl.DQRun DEFAULT VALUES;     -- start run 1
SELECT RunID, StartedAt, EndedAt, Errors, Warnings FROM etl.DQRun;
GO

-- ==== Completeness and uniqueness ====

-- 2. Every order line reached the fact
DECLARE @run INT = (SELECT MAX(RunID) FROM etl.DQRun), @n INT;
DECLARE @stg INT = (SELECT COUNT(*) FROM stg.SalesOrderDetail), @fact INT = (SELECT COUNT(*) FROM dw.FactSales);
SET @n = ABS(@stg - @fact);
INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows) VALUES (@run, 'Order lines: staging = fact', 'Completeness', 'Error', @n);
SELECT @stg AS StagingLines, @fact AS FactLines, @n AS Difference;
GO

-- 3. Every cent reached the fact
DECLARE @run INT = (SELECT MAX(RunID) FROM etl.DQRun), @n INT;
DECLARE @stg DECIMAL(19, 4) = (SELECT SUM(CAST(LineTotal AS DECIMAL(19, 4))) FROM stg.SalesOrderDetail),
        @fact DECIMAL(19, 4) = (SELECT SUM(SalesAmount) FROM dw.FactSales);
SET @n = CASE WHEN @stg = @fact THEN 0 ELSE 1 END;
INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows) VALUES (@run, 'Revenue: staging = fact', 'Completeness', 'Error', @n);
SELECT @stg AS StagingRevenue, @fact AS FactRevenue, @fact - @stg AS Difference;
GO

-- 4. Staging still matches the source, column by column
DECLARE @run INT = (SELECT MAX(RunID) FROM etl.DQRun), @n INT;
DECLARE @a INT = (SELECT COUNT(*) FROM (SELECT ProductID, Name, ProductNumber, Color, StandardCost, ListPrice, ProductSubcategoryID FROM dbo.Product
                                       EXCEPT
                                       SELECT ProductID, Name, ProductNumber, Color, StandardCost, ListPrice, ProductSubcategoryID FROM stg.Product) x),
        @b INT = (SELECT COUNT(*) FROM (SELECT ProductID, Name, ProductNumber, Color, StandardCost, ListPrice, ProductSubcategoryID FROM stg.Product
                                       EXCEPT
                                       SELECT ProductID, Name, ProductNumber, Color, StandardCost, ListPrice, ProductSubcategoryID FROM dbo.Product) x);
SET @n = @a + @b;
INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows) VALUES (@run, 'Products: source = staging', 'Completeness', 'Error', @n);
SELECT (SELECT COUNT(*) FROM dbo.Product) AS SourceProducts, (SELECT COUNT(*) FROM stg.Product) AS StagingProducts,
       @a AS DifferentInSource, @b AS DifferentInStaging;
GO

-- 5. Keys are unique, and every product has exactly one current version
DECLARE @run INT = (SELECT MAX(RunID) FROM etl.DQRun), @n INT;
DECLARE @dupCust INT = (SELECT COUNT(*) FROM (SELECT CustomerID FROM dw.DimCustomer
                                              GROUP BY CustomerID HAVING COUNT(*) > 1) d),
        @badCurrent INT = (SELECT COUNT(*) FROM (SELECT ProductID FROM dw.DimProduct
                                                 GROUP BY ProductID HAVING SUM(CAST(IsCurrent AS INT)) <> 1) d),
        @dupFact INT = (SELECT COUNT(*) FROM (SELECT SalesOrderID, SalesOrderDetailID FROM dw.FactSales
                                              GROUP BY SalesOrderID, SalesOrderDetailID HAVING COUNT(*) > 1) d);
SET @n = @dupCust + @badCurrent + @dupFact;
INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows) VALUES (@run, 'Keys unique; one current version', 'Uniqueness', 'Error', @n);
SELECT @dupCust AS DuplicateCustomers, @badCurrent AS ProductsWithout1CurrentVersion, @dupFact AS DuplicateFactLines;
GO

-- ==== Validity and consistency ====

-- 6. Amounts add up on every line
DECLARE @run INT = (SELECT MAX(RunID) FROM etl.DQRun), @n INT;
SET @n = (SELECT COUNT(*) FROM dw.FactSales f
       JOIN stg.SalesOrderDetail d ON d.SalesOrderID = f.SalesOrderID AND d.SalesOrderDetailID = f.SalesOrderDetailID
       WHERE f.Quantity <= 0 OR f.UnitPrice < 0
          OR ABS(f.SalesAmount - f.Quantity * f.UnitPrice * (1 - d.UnitPriceDiscount)) > 0.01);
INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows) VALUES (@run, 'Amount = quantity x price x (1 - discount)', 'Validity', 'Error', @n);
SELECT COUNT(*) AS LinesChecked, @n AS LinesFailed FROM dw.FactSales;
GO

-- 7. Dates are in a possible order
DECLARE @run INT = (SELECT MAX(RunID) FROM etl.DQRun), @n INT;
SELECT @n = COUNT(*) FROM stg.SalesOrderHeader
WHERE OrderDate > SYSDATETIME() OR ShipDate < OrderDate OR DueDate < OrderDate;
INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows) VALUES (@run, 'Order dates possible', 'Validity', 'Error', @n);
SELECT COUNT(*) AS Orders,
       SUM(CASE WHEN OrderDate > SYSDATETIME() THEN 1 ELSE 0 END) AS InTheFuture,
       SUM(CASE WHEN ShipDate < OrderDate THEN 1 ELSE 0 END)      AS ShippedBeforeOrdered,
       SUM(CASE WHEN DueDate  < OrderDate THEN 1 ELSE 0 END)      AS DueBeforeOrdered,
       SUM(CASE WHEN ShipDate IS NULL THEN 1 ELSE 0 END)          AS NotShippedYet
FROM stg.SalesOrderHeader;
GO

-- 8. Type 2 history has no gaps and no overlaps
DECLARE @run INT = (SELECT MAX(RunID) FROM etl.DQRun), @n INT;
WITH v AS (
    SELECT ProductID, ValidFrom, ValidTo,
           LEAD(ValidFrom) OVER (PARTITION BY ProductID ORDER BY ValidFrom) AS NextFrom
    FROM dw.DimProduct)
SELECT @n = COUNT(*) FROM v
WHERE ValidFrom >= ValidTo                                  -- a version that ends before it starts
   OR (NextFrom IS NOT NULL AND NextFrom <> ValidTo)        -- a gap or an overlap before the next version
   OR (NextFrom IS NULL AND ValidTo <> '9999-12-31');       -- the last version is not open
INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows) VALUES (@run, 'Product versions touch, no gaps', 'Consistency', 'Error', @n);
SELECT (SELECT COUNT(*) FROM dw.DimProduct) AS Versions,
       (SELECT COUNT(DISTINCT ProductID) FROM dw.DimProduct) AS Products, @n AS BadVersions;
GO

-- 9. Facts still waiting on an Unknown member
DECLARE @run INT = (SELECT MAX(RunID) FROM etl.DQRun), @n INT;
SELECT @n = COUNT(*) FROM dw.FactSales WHERE CustomerKey = -1 OR ProductKey = -1;
INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows) VALUES (@run, 'Facts on Unknown members', 'Consistency', 'Warning', @n);
SELECT SUM(CASE WHEN CustomerKey = -1 THEN 1 ELSE 0 END) AS UnknownCustomer,
       SUM(CASE WHEN ProductKey  = -1 THEN 1 ELSE 0 END) AS UnknownProduct
FROM dw.FactSales;
GO

-- ==== Business rules and plausibility ====

-- 10. A product that is "not for sale" was sold
DECLARE @run INT = (SELECT MAX(RunID) FROM etl.DQRun), @n INT;
SELECT @n = COUNT(DISTINCT p.ProductID)
FROM dw.FactSales f JOIN dw.DimProduct p ON p.ProductKey = f.ProductKey
WHERE p.Category = 'Not for sale';
INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows) VALUES (@run, 'Sold products have a category', 'Business rule', 'Warning', @n);
SELECT p.ProductID, p.ProductName, p.Category, COUNT(*) AS Lines, SUM(f.SalesAmount) AS Revenue
FROM dw.FactSales f JOIN dw.DimProduct p ON p.ProductKey = f.ProductKey
WHERE p.Category = 'Not for sale'
GROUP BY p.ProductID, p.ProductName, p.Category;
GO

-- 11. Sold above its list price
DECLARE @run INT = (SELECT MAX(RunID) FROM etl.DQRun), @n INT;
SELECT @n = COUNT(*)
FROM dw.FactSales f JOIN dw.DimProduct p ON p.ProductKey = f.ProductKey
WHERE p.ProductKey > 0 AND f.UnitPrice > p.ListPrice;
INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows) VALUES (@run, 'Unit price not above list price', 'Plausibility', 'Warning', @n);
SELECT p.ProductID, p.ProductName, p.ListPrice AS ListPriceInWarehouse,
       MIN(f.UnitPrice) AS LowestSold, MAX(f.UnitPrice) AS HighestSold, COUNT(*) AS Lines,
       MIN(f.OrderDateKey) AS FirstSale, MAX(f.OrderDateKey) AS LastSale
FROM dw.FactSales f JOIN dw.DimProduct p ON p.ProductKey = f.ProductKey
WHERE p.ProductKey > 0 AND f.UnitPrice > p.ListPrice
GROUP BY p.ProductID, p.ProductName, p.ListPrice;
GO

-- 12. Following the warning back to the source
SELECT 'AdventureWorks2022 Product' AS WhereFrom, ListPrice, ModifiedDate
FROM AdventureWorks2022.Production.Product WHERE ProductID = 776
UNION ALL
SELECT 'AdventureWorks2022 price history ' + CONVERT(CHAR(10), StartDate, 23) + ' to ' + CONVERT(CHAR(10), EndDate, 23),
       ListPrice, ModifiedDate
FROM AdventureWorks2022.Production.ProductListPriceHistory WHERE ProductID = 776
UNION ALL
SELECT 'AWPractice dbo.Product (our source)', ListPrice, ModifiedDate FROM dbo.Product WHERE ProductID = 776;
GO

-- ==== Using the results ====

-- 13. The run, in one table
SELECT CheckName, Category, Severity, FailedRows, Status
FROM etl.DQResult WHERE RunID = (SELECT MAX(RunID) FROM etl.DQRun)
ORDER BY ResultID;
GO

-- 14. Test the tests: plant an error and see it caught
DECLARE @failsPlanted INT, @diffPlanted DECIMAL(19, 4), @failsAfter INT, @diffAfter DECIMAL(19, 4);
BEGIN TRANSACTION;
UPDATE dw.FactSales SET SalesAmount = SalesAmount + 100            -- one wrong amount, on purpose
WHERE SalesOrderID = 43659 AND SalesOrderDetailID = 1;
SET @failsPlanted = (SELECT COUNT(*) FROM dw.FactSales f
       JOIN stg.SalesOrderDetail d ON d.SalesOrderID = f.SalesOrderID AND d.SalesOrderDetailID = f.SalesOrderDetailID
       WHERE f.Quantity <= 0 OR f.UnitPrice < 0
          OR ABS(f.SalesAmount - f.Quantity * f.UnitPrice * (1 - d.UnitPriceDiscount)) > 0.01);
SET @diffPlanted = (SELECT SUM(SalesAmount) FROM dw.FactSales)
       - (SELECT SUM(CAST(LineTotal AS DECIMAL(19, 4))) FROM stg.SalesOrderDetail);
ROLLBACK;                                                           -- undo it
SET @failsAfter = (SELECT COUNT(*) FROM dw.FactSales f
       JOIN stg.SalesOrderDetail d ON d.SalesOrderID = f.SalesOrderID AND d.SalesOrderDetailID = f.SalesOrderDetailID
       WHERE f.Quantity <= 0 OR f.UnitPrice < 0
          OR ABS(f.SalesAmount - f.Quantity * f.UnitPrice * (1 - d.UnitPriceDiscount)) > 0.01);
SET @diffAfter = (SELECT SUM(SalesAmount) FROM dw.FactSales)
       - (SELECT SUM(CAST(LineTotal AS DECIMAL(19, 4))) FROM stg.SalesOrderDetail);
SELECT 'One error planted' AS State, @failsPlanted AS AmountCheckFails, @diffPlanted AS RevenueDifference
UNION ALL
SELECT 'After ROLLBACK', @failsAfter, @diffAfter;
GO

-- 15. The gate: may this load be published?
DECLARE @run INT = (SELECT MAX(RunID) FROM etl.DQRun);
DECLARE @errors INT   = (SELECT COUNT(*) FROM etl.DQResult WHERE RunID = @run AND Status = 'Fail'),
        @warnings INT = (SELECT COUNT(*) FROM etl.DQResult WHERE RunID = @run AND Status = 'Warning');
UPDATE etl.DQRun SET EndedAt = SYSDATETIME(), Errors = @errors, Warnings = @warnings WHERE RunID = @run;
IF @errors > 0
    THROW 50001, 'Data quality errors found: the load must not be published.', 1;
PRINT CONCAT('Run ', @run, ': ', @errors, ' errors, ', @warnings, ' warnings.');
PRINT 'The load can be published. The warnings go to the data owner to investigate.';
GO
