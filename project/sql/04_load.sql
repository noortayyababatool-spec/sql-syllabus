-- =====================================================================================
-- AWSupplyDW 04_load.sql: one procedure per dimension or fact
-- Every procedure is safe to run again: a second run with no source change changes
-- nothing, and a source change is applied exactly once. Each writes one StepLog row.
-- =====================================================================================
USE AWSupplyDW;
GO
CREATE OR ALTER FUNCTION etl.fn_DateKey (@d DATETIME)
RETURNS INT
WITH SCHEMABINDING
AS
BEGIN
    RETURN ISNULL(CONVERT(INT, CONVERT(CHAR(8), @d, 112)), -1);   -- NULL date -> Unknown (-1)
END
GO

---------------------------------------------------------------- DimDate
-- Covers every whole year that appears in the staged transaction dates; adds only missing days.
CREATE OR ALTER PROCEDURE etl.usp_LoadDimDate @RunID INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @log INT, @from DATE, @to DATE;
    EXEC etl.usp_StepStart @RunID, 'Load dw.DimDate', @log OUTPUT;

    SELECT @from = DATEFROMPARTS(YEAR(MIN(d)), 1, 1), @to = DATEFROMPARTS(YEAR(MAX(d)), 12, 31)
    FROM (SELECT OrderDate AS d FROM stg.PurchaseOrderHeader UNION ALL SELECT ShipDate FROM stg.PurchaseOrderHeader
          UNION ALL SELECT DueDate FROM stg.PurchaseOrderDetail UNION ALL SELECT StartDate FROM stg.WorkOrder
          UNION ALL SELECT EndDate FROM stg.WorkOrder UNION ALL SELECT DueDate FROM stg.WorkOrder
          UNION ALL SELECT ScheduledStartDate FROM stg.WorkOrderRouting UNION ALL SELECT ActualEndDate FROM stg.WorkOrderRouting
          UNION ALL SELECT MAX(ModifiedDate) FROM stg.ProductInventory) x;

    IF NOT EXISTS (SELECT 1 FROM dw.DimDate WHERE DateKey = -1)
        INSERT INTO dw.DimDate VALUES (-1, '1900-01-01', 1900, 0, 'Unknown', 0, 'Unknown', 'Unknown', 'Unknown', 0, 1900);

    WITH n AS (SELECT TOP (DATEDIFF(DAY, @from, @to) + 1) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
               FROM sys.all_objects a CROSS JOIN sys.all_objects b),
         d AS (SELECT DATEADD(DAY, i, @from) AS dt FROM n)
    INSERT INTO dw.DimDate
    SELECT etl.fn_DateKey(dt), dt, YEAR(dt), DATEPART(QUARTER, dt),
           CONCAT(YEAR(dt), '-Q', DATEPART(QUARTER, dt)), MONTH(dt), DATENAME(MONTH, dt),
           CONVERT(CHAR(7), dt, 120), DATENAME(WEEKDAY, dt),
           CASE WHEN DATENAME(WEEKDAY, dt) IN ('Saturday', 'Sunday') THEN 1 ELSE 0 END,
           YEAR(dt) + CASE WHEN MONTH(dt) >= 7 THEN 1 ELSE 0 END          -- July 2013 is in fiscal year 2014
    FROM d
    WHERE NOT EXISTS (SELECT 1 FROM dw.DimDate x WHERE x.DateKey = etl.fn_DateKey(d.dt));

    EXEC etl.usp_StepEnd @log, @@ROWCOUNT;
END
GO

---------------------------------------------------------------- Type 1 dimensions
-- Employee, ship method, location, scrap reason: overwrite changes, add new members.
CREATE OR ALTER PROCEDURE etl.usp_LoadSmallDimensions @RunID INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @log INT, @rows INT = 0;
    EXEC etl.usp_StepStart @RunID, 'Load Type 1 dimensions', @log OUTPUT;

    MERGE dw.DimEmployee AS t
    USING (SELECT EmployeeID, EmployeeName, JobTitle, ISNULL(Department, 'Unknown') AS Department FROM stg.Employee) AS s
       ON t.EmployeeID = s.EmployeeID
    WHEN MATCHED AND EXISTS (SELECT t.EmployeeName, t.JobTitle, t.Department EXCEPT SELECT s.EmployeeName, s.JobTitle, s.Department)
        THEN UPDATE SET EmployeeName = s.EmployeeName, JobTitle = s.JobTitle, Department = s.Department
    WHEN NOT MATCHED THEN INSERT (EmployeeID, EmployeeName, JobTitle, Department)
                          VALUES (s.EmployeeID, s.EmployeeName, s.JobTitle, s.Department);
    SET @rows += @@ROWCOUNT;

    MERGE dw.DimShipMethod AS t
    USING stg.ShipMethod AS s ON t.ShipMethodID = s.ShipMethodID
    WHEN MATCHED AND EXISTS (SELECT t.ShipMethod, t.ShipBase, t.ShipRate EXCEPT SELECT s.ShipMethod, s.ShipBase, s.ShipRate)
        THEN UPDATE SET ShipMethod = s.ShipMethod, ShipBase = s.ShipBase, ShipRate = s.ShipRate
    WHEN NOT MATCHED THEN INSERT (ShipMethodID, ShipMethod, ShipBase, ShipRate) VALUES (s.ShipMethodID, s.ShipMethod, s.ShipBase, s.ShipRate);
    SET @rows += @@ROWCOUNT;

    MERGE dw.DimLocation AS t
    USING stg.Location AS s ON t.LocationID = s.LocationID
    WHEN MATCHED AND EXISTS (SELECT t.LocationName, t.CostRate, t.Availability EXCEPT SELECT s.LocationName, s.CostRate, s.Availability)
        THEN UPDATE SET LocationName = s.LocationName, CostRate = s.CostRate, Availability = s.Availability
    WHEN NOT MATCHED THEN INSERT (LocationID, LocationName, CostRate, Availability) VALUES (s.LocationID, s.LocationName, s.CostRate, s.Availability);
    SET @rows += @@ROWCOUNT;

    MERGE dw.DimScrapReason AS t
    USING stg.ScrapReason AS s ON t.ScrapReasonID = s.ScrapReasonID
    WHEN MATCHED AND t.ScrapReason <> s.ScrapReason THEN UPDATE SET ScrapReason = s.ScrapReason
    WHEN NOT MATCHED THEN INSERT (ScrapReasonID, ScrapReason) VALUES (s.ScrapReasonID, s.ScrapReason);
    SET @rows += @@ROWCOUNT;

    EXEC etl.usp_StepEnd @log, @rows;
END
GO

---------------------------------------------------------------- DimVendor (Type 2)
CREATE OR ALTER PROCEDURE etl.usp_LoadDimVendor @RunID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;                     -- a failure undoes the whole change, never half of it (Day 20)
    DECLARE @log INT, @rows INT = 0, @today DATE = CAST(SYSDATETIME() AS DATE);
    EXEC etl.usp_StepStart @RunID, 'Load dw.DimVendor (Type 2)', @log OUTPUT;

    SELECT VendorID, AccountNumber, VendorName, CreditRating,
           CASE CreditRating WHEN 1 THEN 'Superior' WHEN 2 THEN 'Excellent' WHEN 3 THEN 'Above average'
                             WHEN 4 THEN 'Average' WHEN 5 THEN 'Below average' ELSE 'Unknown' END AS CreditRatingName,
           CASE WHEN PreferredVendorStatus = 1 THEN 'Yes' ELSE 'No' END AS PreferredVendor,
           CASE WHEN ActiveFlag = 1 THEN 'Active' ELSE 'Inactive' END AS ActiveStatus,
           ISNULL(City, 'Unknown') AS City, ISNULL(StateProvince, 'Unknown') AS StateProvince, ISNULL(Country, 'Unknown') AS Country
    INTO #v FROM stg.Vendor;

    BEGIN TRANSACTION;
    -- Type 1 columns: correct every version
    UPDATE d SET VendorName = v.VendorName, AccountNumber = v.AccountNumber, City = v.City,
                 StateProvince = v.StateProvince, Country = v.Country
    FROM dw.DimVendor d JOIN #v v ON v.VendorID = d.VendorID
    WHERE EXISTS (SELECT d.VendorName, d.AccountNumber, d.City, d.StateProvince, d.Country
                  EXCEPT SELECT v.VendorName, v.AccountNumber, v.City, v.StateProvince, v.Country);
    SET @rows += @@ROWCOUNT;

    -- Type 2 columns: close the current version of every vendor whose rating, preference or status changed
    UPDATE d SET ValidTo = @today, IsCurrent = 0
    FROM dw.DimVendor d JOIN #v v ON v.VendorID = d.VendorID
    WHERE d.IsCurrent = 1
      AND EXISTS (SELECT d.CreditRating, d.PreferredVendor, d.ActiveStatus
                  EXCEPT SELECT v.CreditRating, v.PreferredVendor, v.ActiveStatus);
    SET @rows += @@ROWCOUNT;

    -- New vendors (first version valid from 1900: the source keeps no vendor history)
    -- and changed vendors (new version valid from today)
    INSERT INTO dw.DimVendor (VendorID, AccountNumber, VendorName, CreditRating, CreditRatingName, PreferredVendor,
                              ActiveStatus, City, StateProvince, Country, ValidFrom, ValidTo, IsCurrent)
    SELECT v.VendorID, v.AccountNumber, v.VendorName, v.CreditRating, v.CreditRatingName, v.PreferredVendor,
           v.ActiveStatus, v.City, v.StateProvince, v.Country,
           CASE WHEN EXISTS (SELECT 1 FROM dw.DimVendor o WHERE o.VendorID = v.VendorID) THEN @today ELSE '1900-01-01' END,
           '9999-12-31', 1
    FROM #v v
    WHERE NOT EXISTS (SELECT 1 FROM dw.DimVendor d WHERE d.VendorID = v.VendorID AND d.IsCurrent = 1);
    SET @rows += @@ROWCOUNT;
    COMMIT;

    EXEC etl.usp_StepEnd @log, @rows;
END
GO

---------------------------------------------------------------- DimProduct (Type 2, built from price history)
-- Day 25 showed what goes wrong when today's price is assumed to have always applied.
-- Here a product's versions come from the source's own cost and list price history:
-- a new version starts on every date either price changed. The first version is extended
-- back to 1900 with the EARLIEST recorded prices (the best estimate for older facts).
-- Products with no history get one version with their current prices.
CREATE OR ALTER PROCEDURE etl.usp_LoadDimProduct @RunID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @log INT, @rows INT = 0, @today DATE = CAST(SYSDATETIME() AS DATE);
    EXEC etl.usp_StepStart @RunID, 'Load dw.DimProduct (Type 2)', @log OUTPUT;

    SELECT ProductID, ProductName, ProductNumber,
           ISNULL(Category, 'Components and parts')  AS Category,      -- no subcategory: raw parts and subassemblies
           ISNULL(Subcategory, 'Components and parts') AS Subcategory,
           CASE WHEN MakeFlag = 1 THEN 'Manufactured' ELSE 'Purchased' END AS Sourcing,
           FinishedGoodsFlag AS IsFinishedGood, ISNULL(Color, 'None') AS Color,
           CASE ProductLine WHEN 'R' THEN 'Road' WHEN 'M' THEN 'Mountain' WHEN 'T' THEN 'Touring' WHEN 'S' THEN 'Standard' ELSE 'None' END AS ProductLine,
           SafetyStockLevel, ReorderPoint,
           CAST(StandardCost AS DECIMAL(19, 4)) AS StandardCost, CAST(ListPrice AS DECIMAL(19, 4)) AS ListPrice
    INTO #p FROM stg.Product;

    BEGIN TRANSACTION;
    -- Type 1 columns on every version
    UPDATE d SET ProductName = p.ProductName, ProductNumber = p.ProductNumber, Category = p.Category, Subcategory = p.Subcategory,
                 Sourcing = p.Sourcing, IsFinishedGood = p.IsFinishedGood, Color = p.Color, ProductLine = p.ProductLine,
                 SafetyStockLevel = p.SafetyStockLevel, ReorderPoint = p.ReorderPoint
    FROM dw.DimProduct d JOIN #p p ON p.ProductID = d.ProductID
    WHERE EXISTS (SELECT d.ProductName, d.ProductNumber, d.Category, d.Subcategory, d.Sourcing, d.IsFinishedGood, d.Color,
                         d.ProductLine, d.SafetyStockLevel, d.ReorderPoint
                  EXCEPT SELECT p.ProductName, p.ProductNumber, p.Category, p.Subcategory, p.Sourcing, p.IsFinishedGood, p.Color,
                         p.ProductLine, p.SafetyStockLevel, p.ReorderPoint);
    SET @rows += @@ROWCOUNT;

    -- Products already in the dimension whose cost or list price changed since the last run
    SELECT d.ProductKey, p.* INTO #changed
    FROM dw.DimProduct d JOIN #p p ON p.ProductID = d.ProductID
    WHERE d.IsCurrent = 1 AND (d.StandardCost <> p.StandardCost OR d.ListPrice <> p.ListPrice);

    UPDATE d SET ValidTo = @today, IsCurrent = 0
    FROM dw.DimProduct d JOIN #changed c ON c.ProductKey = d.ProductKey;
    SET @rows += @@ROWCOUNT;

    INSERT INTO dw.DimProduct (ProductID, ProductName, ProductNumber, Category, Subcategory, Sourcing, IsFinishedGood, Color,
                               ProductLine, SafetyStockLevel, ReorderPoint, StandardCost, ListPrice, ValidFrom, ValidTo, IsCurrent, HistorySource)
    SELECT ProductID, ProductName, ProductNumber, Category, Subcategory, Sourcing, IsFinishedGood, Color,
           ProductLine, SafetyStockLevel, ReorderPoint, StandardCost, ListPrice, @today, '9999-12-31', 1, 'Change seen'
    FROM #changed;
    SET @rows += @@ROWCOUNT;

    -- Products not yet in the dimension: one version per price change date in the history
    WITH pts AS (
        SELECT ProductID, CAST(StartDate AS DATE) AS d FROM stg.ProductCostHistory
        UNION
        SELECT ProductID, CAST(StartDate AS DATE) FROM stg.ProductListPriceHistory),
    v AS (
        SELECT ProductID, d AS ChangeDate,
               LEAD(d) OVER (PARTITION BY ProductID ORDER BY d) AS NextChange,
               ROW_NUMBER() OVER (PARTITION BY ProductID ORDER BY d) AS VersionNo
        FROM pts)
    INSERT INTO dw.DimProduct (ProductID, ProductName, ProductNumber, Category, Subcategory, Sourcing, IsFinishedGood, Color,
                               ProductLine, SafetyStockLevel, ReorderPoint, StandardCost, ListPrice, ValidFrom, ValidTo, IsCurrent, HistorySource)
    SELECT p.ProductID, p.ProductName, p.ProductNumber, p.Category, p.Subcategory, p.Sourcing, p.IsFinishedGood, p.Color,
           p.ProductLine, p.SafetyStockLevel, p.ReorderPoint,
           ISNULL(c.StandardCost, p.StandardCost), ISNULL(l.ListPrice, p.ListPrice),
           CASE WHEN v.VersionNo = 1 OR v.ProductID IS NULL THEN '1900-01-01' ELSE v.ChangeDate END,
           ISNULL(v.NextChange, '9999-12-31'),
           CASE WHEN v.NextChange IS NULL THEN 1 ELSE 0 END,
           CASE WHEN v.ProductID IS NULL THEN 'No history' WHEN v.VersionNo = 1 THEN 'Earliest history' ELSE 'Price history' END
    FROM #p p
    LEFT JOIN v ON v.ProductID = p.ProductID
    -- the price in force on the change date: the latest history row started by then, else the earliest one
    OUTER APPLY (SELECT TOP (1) CAST(h.StandardCost AS DECIMAL(19, 4)) AS StandardCost FROM stg.ProductCostHistory h
                 WHERE h.ProductID = p.ProductID
                 ORDER BY CASE WHEN h.StartDate <= v.ChangeDate THEN 0 ELSE 1 END,
                          CASE WHEN h.StartDate <= v.ChangeDate THEN h.StartDate END DESC, h.StartDate) c
    OUTER APPLY (SELECT TOP (1) CAST(h.ListPrice AS DECIMAL(19, 4)) AS ListPrice FROM stg.ProductListPriceHistory h
                 WHERE h.ProductID = p.ProductID
                 ORDER BY CASE WHEN h.StartDate <= v.ChangeDate THEN 0 ELSE 1 END,
                          CASE WHEN h.StartDate <= v.ChangeDate THEN h.StartDate END DESC, h.StartDate) l
    WHERE NOT EXISTS (SELECT 1 FROM dw.DimProduct d WHERE d.ProductID = p.ProductID);
    SET @rows += @@ROWCOUNT;
    COMMIT;

    EXEC etl.usp_StepEnd @log, @rows;
END
GO

---------------------------------------------------------------- FactPurchaseLine
-- MERGE, not insert-only: an order line changes after it is placed (goods are received,
-- rejected, the status moves from Pending to Complete), and the fact must follow.
CREATE OR ALTER PROCEDURE etl.usp_LoadFactPurchaseLine @RunID INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @log INT;
    EXEC etl.usp_StepStart @RunID, 'Load dw.FactPurchaseLine', @log OUTPUT;

    WITH line AS (
        SELECT d.PurchaseOrderID, d.PurchaseOrderDetailID, h.OrderDate, d.DueDate, h.ShipDate, h.VendorID, d.ProductID,
               h.EmployeeID, h.ShipMethodID, h.Status, d.OrderQty, d.ReceivedQty, d.RejectedQty, d.StockedQty,
               CAST(d.UnitPrice AS DECIMAL(19, 4)) AS UnitPrice, CAST(d.LineTotal AS DECIMAL(19, 4)) AS LineAmount,
               CAST(h.TaxAmt AS DECIMAL(19, 4)) AS OrderTax, CAST(h.Freight AS DECIMAL(19, 4)) AS OrderFreight,
               -- this line's share of the order, rounded to 4 decimals
               -- (all DECIMAL: MONEY arithmetic would round every intermediate result to 4 decimals)
               ROUND(CAST(h.TaxAmt AS DECIMAL(19, 4)) * CAST(d.LineTotal AS DECIMAL(19, 4))
                     / NULLIF(CAST(h.SubTotal AS DECIMAL(19, 4)), 0), 4) AS TaxShare,
               ROUND(CAST(h.Freight AS DECIMAL(19, 4)) * CAST(d.LineTotal AS DECIMAL(19, 4))
                     / NULLIF(CAST(h.SubTotal AS DECIMAL(19, 4)), 0), 4) AS FreightShare,
               ROW_NUMBER() OVER (PARTITION BY d.PurchaseOrderID ORDER BY d.LineTotal DESC, d.PurchaseOrderDetailID) AS SizeRank
        FROM stg.PurchaseOrderDetail d
        JOIN stg.PurchaseOrderHeader h ON h.PurchaseOrderID = d.PurchaseOrderID),
    alloc AS (
        -- the largest line absorbs the rounding remainder, so the lines add up to the order exactly
        SELECT *,
               CASE WHEN SizeRank = 1 THEN OrderTax - SUM(TaxShare) OVER (PARTITION BY PurchaseOrderID) + TaxShare ELSE TaxShare END AS TaxAmount,
               CASE WHEN SizeRank = 1 THEN OrderFreight - SUM(FreightShare) OVER (PARTITION BY PurchaseOrderID) + FreightShare ELSE FreightShare END AS FreightAmount
        FROM line),
    src AS (
        SELECT a.PurchaseOrderID, a.PurchaseOrderDetailID,
               etl.fn_DateKey(a.OrderDate) AS OrderDateKey, etl.fn_DateKey(a.DueDate) AS DueDateKey, etl.fn_DateKey(a.ShipDate) AS ShipDateKey,
               ISNULL(v.VendorKey, -1) AS VendorKey, ISNULL(p.ProductKey, -1) AS ProductKey,
               ISNULL(e.EmployeeKey, -1) AS EmployeeKey, ISNULL(sm.ShipMethodKey, -1) AS ShipMethodKey,
               ISNULL(st.StatusKey, 0) AS StatusKey,
               a.OrderQty, a.ReceivedQty, a.RejectedQty, a.StockedQty, a.UnitPrice, a.LineAmount, a.TaxAmount, a.FreightAmount
        FROM alloc a
        LEFT JOIN dw.DimVendor v  ON v.VendorID = a.VendorID
                                 AND v.ValidFrom <= CAST(a.OrderDate AS DATE) AND CAST(a.OrderDate AS DATE) < v.ValidTo
        LEFT JOIN dw.DimProduct p ON p.ProductID = a.ProductID
                                 AND p.ValidFrom <= CAST(a.OrderDate AS DATE) AND CAST(a.OrderDate AS DATE) < p.ValidTo
        LEFT JOIN dw.DimEmployee e        ON e.EmployeeID = a.EmployeeID
        LEFT JOIN dw.DimShipMethod sm     ON sm.ShipMethodID = a.ShipMethodID
        LEFT JOIN dw.DimPurchaseStatus st ON st.StatusKey = a.Status)
    MERGE dw.FactPurchaseLine AS t
    USING src AS s ON t.PurchaseOrderID = s.PurchaseOrderID AND t.PurchaseOrderDetailID = s.PurchaseOrderDetailID
    WHEN MATCHED AND EXISTS (
        SELECT t.OrderDateKey, t.DueDateKey, t.ShipDateKey, t.VendorKey, t.ProductKey, t.EmployeeKey, t.ShipMethodKey, t.StatusKey,
               t.OrderQty, t.ReceivedQty, t.RejectedQty, t.StockedQty, t.UnitPrice, t.LineAmount, t.TaxAmount, t.FreightAmount
        EXCEPT
        SELECT s.OrderDateKey, s.DueDateKey, s.ShipDateKey, s.VendorKey, s.ProductKey, s.EmployeeKey, s.ShipMethodKey, s.StatusKey,
               s.OrderQty, s.ReceivedQty, s.RejectedQty, s.StockedQty, s.UnitPrice, s.LineAmount, s.TaxAmount, s.FreightAmount)
        THEN UPDATE SET OrderDateKey = s.OrderDateKey, DueDateKey = s.DueDateKey, ShipDateKey = s.ShipDateKey,
                        VendorKey = s.VendorKey, ProductKey = s.ProductKey, EmployeeKey = s.EmployeeKey,
                        ShipMethodKey = s.ShipMethodKey, StatusKey = s.StatusKey, OrderQty = s.OrderQty,
                        ReceivedQty = s.ReceivedQty, RejectedQty = s.RejectedQty, StockedQty = s.StockedQty,
                        UnitPrice = s.UnitPrice, LineAmount = s.LineAmount, TaxAmount = s.TaxAmount, FreightAmount = s.FreightAmount
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (PurchaseOrderID, PurchaseOrderDetailID, OrderDateKey, DueDateKey, ShipDateKey, VendorKey, ProductKey, EmployeeKey,
                ShipMethodKey, StatusKey, OrderQty, ReceivedQty, RejectedQty, StockedQty, UnitPrice, LineAmount, TaxAmount, FreightAmount)
        VALUES (s.PurchaseOrderID, s.PurchaseOrderDetailID, s.OrderDateKey, s.DueDateKey, s.ShipDateKey, s.VendorKey, s.ProductKey, s.EmployeeKey,
                s.ShipMethodKey, s.StatusKey, s.OrderQty, s.ReceivedQty, s.RejectedQty, s.StockedQty, s.UnitPrice, s.LineAmount, s.TaxAmount, s.FreightAmount)
    WHEN NOT MATCHED BY SOURCE THEN DELETE;      -- a line deleted in the source leaves the warehouse too

    EXEC etl.usp_StepEnd @log, @@ROWCOUNT;
END
GO

---------------------------------------------------------------- FactWorkOrder
CREATE OR ALTER PROCEDURE etl.usp_LoadFactWorkOrder @RunID INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @log INT;
    EXEC etl.usp_StepStart @RunID, 'Load dw.FactWorkOrder', @log OUTPUT;

    WITH src AS (
        SELECT w.WorkOrderID, ISNULL(p.ProductKey, -1) AS ProductKey,
               etl.fn_DateKey(w.StartDate) AS StartDateKey, etl.fn_DateKey(w.EndDate) AS EndDateKey, etl.fn_DateKey(w.DueDate) AS DueDateKey,
               CASE WHEN w.ScrapReasonID IS NULL THEN 0 ELSE ISNULL(r.ScrapReasonKey, -1) END AS ScrapReasonKey,
               w.OrderQty, w.StockedQty, CAST(w.ScrappedQty AS INT) AS ScrappedQty,
               ISNULL(DATEDIFF(DAY, w.StartDate, w.EndDate), 0) AS DaysToBuild,
               CASE WHEN w.EndDate > w.DueDate THEN DATEDIFF(DAY, w.DueDate, w.EndDate) ELSE 0 END AS DaysLate,
               ISNULL(p.StandardCost, 0) AS StandardCostAtStart,
               CAST(w.ScrappedQty AS INT) * ISNULL(p.StandardCost, 0) AS ScrapCost
        FROM stg.WorkOrder w
        LEFT JOIN dw.DimProduct p ON p.ProductID = w.ProductID
                                 AND p.ValidFrom <= CAST(w.StartDate AS DATE) AND CAST(w.StartDate AS DATE) < p.ValidTo
        LEFT JOIN dw.DimScrapReason r ON r.ScrapReasonID = w.ScrapReasonID)
    MERGE dw.FactWorkOrder AS t
    USING src AS s ON t.WorkOrderID = s.WorkOrderID
    WHEN MATCHED AND EXISTS (
        SELECT t.ProductKey, t.StartDateKey, t.EndDateKey, t.DueDateKey, t.ScrapReasonKey, t.OrderQty, t.StockedQty,
               t.ScrappedQty, t.DaysToBuild, t.DaysLate, t.StandardCostAtStart, t.ScrapCost
        EXCEPT
        SELECT s.ProductKey, s.StartDateKey, s.EndDateKey, s.DueDateKey, s.ScrapReasonKey, s.OrderQty, s.StockedQty,
               s.ScrappedQty, s.DaysToBuild, s.DaysLate, s.StandardCostAtStart, s.ScrapCost)
        THEN UPDATE SET ProductKey = s.ProductKey, StartDateKey = s.StartDateKey, EndDateKey = s.EndDateKey, DueDateKey = s.DueDateKey,
                        ScrapReasonKey = s.ScrapReasonKey, OrderQty = s.OrderQty, StockedQty = s.StockedQty, ScrappedQty = s.ScrappedQty,
                        DaysToBuild = s.DaysToBuild, DaysLate = s.DaysLate, StandardCostAtStart = s.StandardCostAtStart, ScrapCost = s.ScrapCost
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (WorkOrderID, ProductKey, StartDateKey, EndDateKey, DueDateKey, ScrapReasonKey, OrderQty, StockedQty, ScrappedQty,
                DaysToBuild, DaysLate, StandardCostAtStart, ScrapCost)
        VALUES (s.WorkOrderID, s.ProductKey, s.StartDateKey, s.EndDateKey, s.DueDateKey, s.ScrapReasonKey, s.OrderQty, s.StockedQty,
                s.ScrappedQty, s.DaysToBuild, s.DaysLate, s.StandardCostAtStart, s.ScrapCost)
    WHEN NOT MATCHED BY SOURCE THEN DELETE;

    EXEC etl.usp_StepEnd @log, @@ROWCOUNT;
END
GO

---------------------------------------------------------------- FactWorkOrderOperation
CREATE OR ALTER PROCEDURE etl.usp_LoadFactWorkOrderOperation @RunID INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @log INT;
    EXEC etl.usp_StepStart @RunID, 'Load dw.FactWorkOrderOperation', @log OUTPUT;

    WITH src AS (
        SELECT r.WorkOrderID, r.OperationSequence, ISNULL(p.ProductKey, -1) AS ProductKey, ISNULL(l.LocationKey, -1) AS LocationKey,
               etl.fn_DateKey(r.ScheduledStartDate) AS ScheduledStartDateKey, etl.fn_DateKey(r.ActualStartDate) AS ActualStartDateKey,
               etl.fn_DateKey(r.ActualEndDate) AS ActualEndDateKey,
               ISNULL(r.ActualResourceHrs, 0) AS ResourceHours,
               CAST(r.PlannedCost AS DECIMAL(19, 4)) AS PlannedCost, CAST(ISNULL(r.ActualCost, 0) AS DECIMAL(19, 4)) AS ActualCost,
               CASE WHEN r.ActualEndDate > r.ScheduledEndDate THEN DATEDIFF(DAY, r.ScheduledEndDate, r.ActualEndDate) ELSE 0 END AS DaysLate
        FROM stg.WorkOrderRouting r
        LEFT JOIN dw.DimProduct p ON p.ProductID = r.ProductID
                                 AND p.ValidFrom <= CAST(r.ScheduledStartDate AS DATE) AND CAST(r.ScheduledStartDate AS DATE) < p.ValidTo
        LEFT JOIN dw.DimLocation l ON l.LocationID = r.LocationID)
    MERGE dw.FactWorkOrderOperation AS t
    USING src AS s ON t.WorkOrderID = s.WorkOrderID AND t.OperationSequence = s.OperationSequence
    WHEN MATCHED AND EXISTS (
        SELECT t.ProductKey, t.LocationKey, t.ScheduledStartDateKey, t.ActualStartDateKey, t.ActualEndDateKey,
               t.ResourceHours, t.PlannedCost, t.ActualCost, t.DaysLate
        EXCEPT
        SELECT s.ProductKey, s.LocationKey, s.ScheduledStartDateKey, s.ActualStartDateKey, s.ActualEndDateKey,
               s.ResourceHours, s.PlannedCost, s.ActualCost, s.DaysLate)
        THEN UPDATE SET ProductKey = s.ProductKey, LocationKey = s.LocationKey, ScheduledStartDateKey = s.ScheduledStartDateKey,
                        ActualStartDateKey = s.ActualStartDateKey, ActualEndDateKey = s.ActualEndDateKey,
                        ResourceHours = s.ResourceHours, PlannedCost = s.PlannedCost, ActualCost = s.ActualCost, DaysLate = s.DaysLate
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (WorkOrderID, OperationSequence, ProductKey, LocationKey, ScheduledStartDateKey, ActualStartDateKey, ActualEndDateKey,
                ResourceHours, PlannedCost, ActualCost, DaysLate)
        VALUES (s.WorkOrderID, s.OperationSequence, s.ProductKey, s.LocationKey, s.ScheduledStartDateKey, s.ActualStartDateKey,
                s.ActualEndDateKey, s.ResourceHours, s.PlannedCost, s.ActualCost, s.DaysLate)
    WHEN NOT MATCHED BY SOURCE THEN DELETE;

    EXEC etl.usp_StepEnd @log, @@ROWCOUNT;
END
GO

---------------------------------------------------------------- FactInventorySnapshot
-- The source keeps only today's stock, so each run takes a snapshot dated with the
-- source's last inventory change and replaces any earlier snapshot for that same date.
CREATE OR ALTER PROCEDURE etl.usp_LoadFactInventorySnapshot @RunID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @log INT, @rows INT, @snap INT = (SELECT etl.fn_DateKey(MAX(ModifiedDate)) FROM stg.ProductInventory);
    EXEC etl.usp_StepStart @RunID, 'Load dw.FactInventorySnapshot', @log OUTPUT;

    -- Unit cost: the standard cost, but most purchased raw parts have a standard cost of 0 in the
    -- source, which would value their stock at nothing. For those, use the last price paid.
    WITH lastPrice AS (
        SELECT d.ProductID, CAST(d.UnitPrice AS DECIMAL(19, 4)) AS UnitPrice,
               ROW_NUMBER() OVER (PARTITION BY d.ProductID ORDER BY h.OrderDate DESC, d.PurchaseOrderID DESC) AS rn
        FROM stg.PurchaseOrderDetail d JOIN stg.PurchaseOrderHeader h ON h.PurchaseOrderID = d.PurchaseOrderID
        WHERE h.Status <> 3)                                               -- not from a rejected order
    SELECT i.ProductID, i.LocationID, SUM(i.Quantity) AS Quantity,
           ISNULL(MAX(p.ProductKey), -1) AS ProductKey, ISNULL(MAX(l.LocationKey), -1) AS LocationKey,
           CASE WHEN MAX(p.StandardCost) > 0 THEN MAX(p.StandardCost) WHEN MAX(lp.UnitPrice) IS NOT NULL THEN MAX(lp.UnitPrice) ELSE 0 END AS UnitCost,
           CASE WHEN MAX(p.StandardCost) > 0 THEN 'Standard cost' WHEN MAX(lp.UnitPrice) IS NOT NULL THEN 'Last purchase price' ELSE 'No cost known' END AS CostBasis
    INTO #snap
    FROM stg.ProductInventory i
    LEFT JOIN dw.DimProduct p  ON p.ProductID = i.ProductID AND p.IsCurrent = 1
    LEFT JOIN dw.DimLocation l ON l.LocationID = i.LocationID
    LEFT JOIN lastPrice lp     ON lp.ProductID = i.ProductID AND lp.rn = 1
    GROUP BY i.ProductID, i.LocationID;                                    -- several shelves and bins add up to one location

    BEGIN TRANSACTION;
    DELETE FROM dw.FactInventorySnapshot WHERE SnapshotDateKey = @snap;
    INSERT INTO dw.FactInventorySnapshot (SnapshotDateKey, ProductKey, LocationKey, Quantity, UnitCost, InventoryValue, CostBasis)
    SELECT @snap, ProductKey, LocationKey, Quantity, UnitCost, Quantity * UnitCost, CostBasis
    FROM #snap;
    SET @rows = @@ROWCOUNT;
    COMMIT;

    EXEC etl.usp_StepEnd @log, @rows;
END
GO
