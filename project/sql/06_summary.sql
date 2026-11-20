-- =====================================================================================
-- AWSupplyDW 06_summary.sql: the reporting layer (rpt schema)
-- Views are always current and cost nothing to store; summary TABLES are rebuilt by
-- the load, only after the quality gate passes, so a report never reads a bad load.
-- =====================================================================================
USE AWSupplyDW;
GO
---------------------------------------------------------------- flattened view for Power BI / Excel
CREATE OR ALTER VIEW rpt.vPurchaseLine
AS
SELECT f.PurchaseOrderID, f.PurchaseOrderDetailID, od.[Date] AS OrderDate, od.YearMonth, od.FiscalYear,
       v.VendorName, v.CreditRatingName, v.PreferredVendor, v.Country AS VendorCountry,
       p.ProductName, p.Category, p.Subcategory, e.EmployeeName AS Buyer, sm.ShipMethod, st.StatusName, st.CountsAsSpend,
       f.OrderQty, f.ReceivedQty, f.RejectedQty, f.StockedQty, f.UnitPrice, f.LineAmount, f.TaxAmount, f.FreightAmount,
       f.LineAmount + f.TaxAmount + f.FreightAmount AS TotalCost
FROM dw.FactPurchaseLine f
JOIN dw.DimDate od           ON od.DateKey = f.OrderDateKey
JOIN dw.DimVendor v          ON v.VendorKey = f.VendorKey
JOIN dw.DimProduct p         ON p.ProductKey = f.ProductKey
JOIN dw.DimEmployee e        ON e.EmployeeKey = f.EmployeeKey
JOIN dw.DimShipMethod sm     ON sm.ShipMethodKey = f.ShipMethodKey
JOIN dw.DimPurchaseStatus st ON st.StatusKey = f.StatusKey;
GO

---------------------------------------------------------------- vendor scorecard (view)
-- One row per vendor (all versions together): spend, quality and short deliveries
CREATE OR ALTER VIEW rpt.vVendorScorecard
AS
SELECT cur.VendorID, cur.VendorName, cur.CreditRatingName, cur.PreferredVendor, cur.ActiveStatus,
       COUNT(DISTINCT f.PurchaseOrderID)                                       AS Orders,
       COUNT(*)                                                                AS Lines,
       SUM(CASE WHEN st.CountsAsSpend = 1 THEN f.LineAmount ELSE 0 END)       AS Spend,
       SUM(f.ReceivedQty)                                                      AS UnitsReceived,
       SUM(f.RejectedQty)                                                      AS UnitsRejected,
       CAST(100.0 * SUM(f.RejectedQty) / NULLIF(SUM(f.ReceivedQty), 0) AS DECIMAL(5, 2))   AS RejectPct,
       CAST(100.0 * SUM(CASE WHEN f.ReceivedQty < f.OrderQty THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5, 2)) AS ShortLinePct
FROM dw.FactPurchaseLine f
JOIN dw.DimVendor v          ON v.VendorKey = f.VendorKey
JOIN dw.DimVendor cur        ON cur.VendorID = v.VendorID AND cur.IsCurrent = 1   -- report under today's name and rating
JOIN dw.DimPurchaseStatus st ON st.StatusKey = f.StatusKey
GROUP BY cur.VendorID, cur.VendorName, cur.CreditRatingName, cur.PreferredVendor, cur.ActiveStatus;
GO

---------------------------------------------------------------- work centre load (view)
CREATE OR ALTER VIEW rpt.vWorkCentreMonthly
AS
SELECT d.YearMonth, l.LocationName, COUNT(*) AS Operations, SUM(o.ResourceHours) AS ResourceHours,
       SUM(o.ActualCost) AS ActualCost,
       CAST(100.0 * SUM(CASE WHEN o.DaysLate > 0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5, 2)) AS LateOperationPct
FROM dw.FactWorkOrderOperation o
JOIN dw.DimDate d     ON d.DateKey = o.ActualStartDateKey
JOIN dw.DimLocation l ON l.LocationKey = o.LocationKey
GROUP BY d.YearMonth, l.LocationName;
GO

---------------------------------------------------------------- inventory position (view)
CREATE OR ALTER VIEW rpt.vInventoryPosition
AS
SELECT d.[Date] AS SnapshotDate, p.ProductID, p.ProductName, p.Category, p.Sourcing,
       SUM(s.Quantity) AS Quantity, SUM(s.InventoryValue) AS InventoryValue, MAX(s.CostBasis) AS CostBasis,
       p.SafetyStockLevel, p.ReorderPoint,
       CASE WHEN SUM(s.Quantity) < p.SafetyStockLevel THEN 'Below safety stock'
            WHEN SUM(s.Quantity) < p.ReorderPoint     THEN 'Reorder now'
            ELSE 'OK' END AS StockStatus
FROM dw.FactInventorySnapshot s
JOIN dw.DimDate d    ON d.DateKey = s.SnapshotDateKey
JOIN dw.DimProduct p ON p.ProductKey = s.ProductKey
WHERE s.SnapshotDateKey = (SELECT MAX(SnapshotDateKey) FROM dw.FactInventorySnapshot)
GROUP BY d.[Date], p.ProductID, p.ProductName, p.Category, p.Sourcing, p.SafetyStockLevel, p.ReorderPoint;
GO

---------------------------------------------------------------- summary tables
CREATE TABLE rpt.PurchaseMonthly (                 -- grain: month x vendor x category
    YearMonth     CHAR(7)       NOT NULL,
    VendorID      INT           NOT NULL,
    VendorName    NVARCHAR(50)  NOT NULL,
    Category      NVARCHAR(50)  NOT NULL,
    Orders        INT           NOT NULL,
    Lines         INT           NOT NULL,
    UnitsOrdered  INT           NOT NULL,
    UnitsRejected DECIMAL(11, 2) NOT NULL,
    Spend         DECIMAL(19, 4) NOT NULL,         -- excludes rejected orders
    Freight       DECIMAL(19, 4) NOT NULL,
    RunID         INT           NOT NULL,          -- the load that built this row
    CONSTRAINT PK_PurchaseMonthly PRIMARY KEY (YearMonth, VendorID, Category));

CREATE TABLE rpt.ProductionMonthly (               -- grain: month x subcategory
    YearMonth      CHAR(7)       NOT NULL,
    Category       NVARCHAR(50)  NOT NULL,
    Subcategory    NVARCHAR(50)  NOT NULL,
    WorkOrders     INT           NOT NULL,
    UnitsOrdered   INT           NOT NULL,
    UnitsScrapped  INT           NOT NULL,
    ScrapPct       DECIMAL(6, 3) NOT NULL,
    ScrapCost      DECIMAL(19, 4) NOT NULL,
    LateWorkOrders INT           NOT NULL,
    AvgDaysToBuild DECIMAL(6, 2) NOT NULL,
    RunID          INT           NOT NULL,
    CONSTRAINT PK_ProductionMonthly PRIMARY KEY (YearMonth, Subcategory));
GO

CREATE OR ALTER PROCEDURE etl.usp_BuildSummaries @RunID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @log INT, @rows INT = 0;
    EXEC etl.usp_StepStart @RunID, 'Publish rpt summary tables', @log OUTPUT;

    BEGIN TRANSACTION;                              -- readers see the old summary or the new one, never half
    TRUNCATE TABLE rpt.PurchaseMonthly;
    INSERT INTO rpt.PurchaseMonthly
    SELECT d.YearMonth, cur.VendorID, cur.VendorName, p.Category,
           COUNT(DISTINCT f.PurchaseOrderID), COUNT(*), SUM(f.OrderQty), SUM(f.RejectedQty),
           SUM(CASE WHEN st.CountsAsSpend = 1 THEN f.LineAmount ELSE 0 END), SUM(f.FreightAmount), @RunID
    FROM dw.FactPurchaseLine f
    JOIN dw.DimDate d            ON d.DateKey = f.OrderDateKey
    JOIN dw.DimVendor v          ON v.VendorKey = f.VendorKey
    JOIN dw.DimVendor cur        ON cur.VendorID = v.VendorID AND cur.IsCurrent = 1
    JOIN dw.DimProduct p         ON p.ProductKey = f.ProductKey
    JOIN dw.DimPurchaseStatus st ON st.StatusKey = f.StatusKey
    GROUP BY d.YearMonth, cur.VendorID, cur.VendorName, p.Category;
    SET @rows += @@ROWCOUNT;

    TRUNCATE TABLE rpt.ProductionMonthly;
    INSERT INTO rpt.ProductionMonthly
    SELECT d.YearMonth, p.Category, p.Subcategory, COUNT(*), SUM(w.OrderQty), SUM(w.ScrappedQty),
           CAST(100.0 * SUM(w.ScrappedQty) / SUM(w.OrderQty) AS DECIMAL(6, 3)), SUM(w.ScrapCost),
           SUM(CASE WHEN w.DaysLate > 0 THEN 1 ELSE 0 END), CAST(AVG(1.0 * w.DaysToBuild) AS DECIMAL(6, 2)), @RunID
    FROM dw.FactWorkOrder w
    JOIN dw.DimDate d    ON d.DateKey = w.StartDateKey
    JOIN dw.DimProduct p ON p.ProductKey = w.ProductKey
    GROUP BY d.YearMonth, p.Category, p.Subcategory;
    SET @rows += @@ROWCOUNT;
    COMMIT;

    EXEC etl.usp_StepEnd @log, @rows;
END
GO
