-- =====================================================================================
-- AWSupplyDW 08_queries.sql: ten analytical questions answered from the warehouse
-- Purchasing: Q1-Q6   Manufacturing: Q7-Q9   Inventory: Q10
-- "Spend" excludes rejected orders (DimPurchaseStatus.CountsAsSpend = 0).
-- =====================================================================================
USE AWSupplyDW;
GO

-- Q1. How does monthly spend develop, and how does each month compare with the same month a year earlier?
-- Purchasing has months with no orders at all (May-Nov 2011, for example). LAG(Spend, 12) counts ROWS,
-- so the months come from DimDate, not from the facts: every month gets a row, with 0 if nothing was bought.
WITH spend AS (
    SELECT f.OrderDateKey / 100 AS YM, SUM(f.LineAmount) AS Spend
    FROM dw.FactPurchaseLine f
    JOIN dw.DimPurchaseStatus st ON st.StatusKey = f.StatusKey
    WHERE st.CountsAsSpend = 1
    GROUP BY f.OrderDateKey / 100),
m AS (
    SELECT DISTINCT d.[Year], d.MonthNo, d.YearMonth, ISNULL(s.Spend, 0) AS Spend
    FROM dw.DimDate d
    LEFT JOIN spend s ON s.YM = d.DateKey / 100
    WHERE d.DateKey BETWEEN 20110401 AND 20140930)          -- first to last month with purchases
SELECT YearMonth, Spend,
       SUM(Spend) OVER (PARTITION BY [Year] ORDER BY MonthNo)          AS SpendYearToDate,
       LAG(Spend, 12) OVER (ORDER BY [Year], MonthNo)                   AS SpendSameMonthLastYear,
       CAST(100.0 * (Spend - LAG(Spend, 12) OVER (ORDER BY [Year], MonthNo))
            / NULLIF(LAG(Spend, 12) OVER (ORDER BY [Year], MonthNo), 0) AS DECIMAL(8, 1)) AS GrowthPct
FROM m
ORDER BY [Year], MonthNo;
GO

-- Q2. Which vendors take most of the money? (Pareto: share and cumulative share of spend)
WITH v AS (
    SELECT cur.VendorName, SUM(f.LineAmount) AS Spend
    FROM dw.FactPurchaseLine f
    JOIN dw.DimVendor v          ON v.VendorKey = f.VendorKey
    JOIN dw.DimVendor cur        ON cur.VendorID = v.VendorID AND cur.IsCurrent = 1
    JOIN dw.DimPurchaseStatus st ON st.StatusKey = f.StatusKey
    WHERE st.CountsAsSpend = 1
    GROUP BY cur.VendorName)
SELECT TOP (15) RANK() OVER (ORDER BY Spend DESC) AS SpendRank, VendorName, Spend,
       CAST(100.0 * Spend / SUM(Spend) OVER () AS DECIMAL(5, 2)) AS SharePct,
       CAST(100.0 * SUM(Spend) OVER (ORDER BY Spend DESC ROWS UNBOUNDED PRECEDING) / SUM(Spend) OVER () AS DECIMAL(5, 2)) AS CumulativePct,
       (SELECT COUNT(*) FROM v) AS VendorsUsed
FROM v
ORDER BY Spend DESC;
GO

-- Q3. Which vendors deliver the worst quality? Rejection rate, for vendors with at least 1,000 units received
SELECT TOP (10) VendorName, CreditRatingName, PreferredVendor, Lines, UnitsReceived, UnitsRejected, RejectPct, ShortLinePct
FROM rpt.vVendorScorecard
WHERE UnitsReceived >= 1000
ORDER BY RejectPct DESC, UnitsRejected DESC;
GO

-- Q4. Does a vendor's credit rating or preferred status predict delivery quality?
SELECT v.CreditRatingName, v.PreferredVendor,
       COUNT(DISTINCT v.VendorID)                                                     AS Vendors,
       COUNT(*)                                                                       AS Lines,
       SUM(f.ReceivedQty)                                                             AS UnitsReceived,
       CAST(100.0 * SUM(f.RejectedQty) / NULLIF(SUM(f.ReceivedQty), 0) AS DECIMAL(5, 2)) AS RejectPct,
       CAST(100.0 * SUM(CASE WHEN f.RejectedQty > 0 THEN 1 ELSE 0 END) / COUNT(*) AS DECIMAL(5, 2)) AS LinesWithRejectsPct
FROM dw.FactPurchaseLine f
JOIN dw.DimVendor v ON v.VendorKey = f.VendorKey
GROUP BY v.CreditRating, v.CreditRatingName, v.PreferredVendor
ORDER BY v.CreditRating, v.PreferredVendor DESC;
GO

-- Q5. Products bought from several vendors: how far apart are the prices, and who is cheapest?
WITH vp AS (
    SELECT p.ProductID, p.ProductName, v.VendorName,
           SUM(f.LineAmount) / SUM(f.OrderQty) AS AvgUnitPrice, SUM(f.OrderQty) AS Units
    FROM dw.FactPurchaseLine f
    JOIN dw.DimProduct p ON p.ProductKey = f.ProductKey
    JOIN dw.DimVendor v  ON v.VendorKey = f.VendorKey
    GROUP BY p.ProductID, p.ProductName, v.VendorName),
ranked AS (
    SELECT *, COUNT(*) OVER (PARTITION BY ProductID) AS Vendors,
           MIN(AvgUnitPrice) OVER (PARTITION BY ProductID) AS Cheapest,
           MAX(AvgUnitPrice) OVER (PARTITION BY ProductID) AS Dearest,
           ROW_NUMBER() OVER (PARTITION BY ProductID ORDER BY AvgUnitPrice) AS PriceRank
    FROM vp)
SELECT TOP (10) ProductName, Vendors, VendorName AS CheapestVendor,
       CAST(Cheapest AS DECIMAL(10, 2)) AS CheapestPrice, CAST(Dearest AS DECIMAL(10, 2)) AS DearestPrice,
       CAST(100.0 * (Dearest - Cheapest) / Cheapest AS DECIMAL(6, 1)) AS SpreadPct
FROM ranked
WHERE PriceRank = 1 AND Vendors > 1
ORDER BY SpreadPct DESC, ProductName;
GO

-- Q6. Buyer workload: the top three buyers by spend in each fiscal year, with their share of the year
WITH b AS (
    SELECT d.FiscalYear, e.EmployeeName AS Buyer, e.JobTitle,
           COUNT(DISTINCT f.PurchaseOrderID) AS Orders,
           SUM(f.LineAmount)                 AS Spend,
           CAST(SUM(f.LineAmount) / COUNT(DISTINCT f.PurchaseOrderID) AS DECIMAL(12, 2)) AS AvgOrderValue,
           CAST(100.0 * SUM(f.LineAmount) / SUM(SUM(f.LineAmount)) OVER (PARTITION BY d.FiscalYear) AS DECIMAL(5, 1)) AS ShareOfYearPct,
           RANK() OVER (PARTITION BY d.FiscalYear ORDER BY SUM(f.LineAmount) DESC) AS RankInYear,
           COUNT(*) OVER (PARTITION BY d.FiscalYear) AS BuyersInYear
    FROM dw.FactPurchaseLine f
    JOIN dw.DimDate d            ON d.DateKey = f.OrderDateKey
    JOIN dw.DimEmployee e        ON e.EmployeeKey = f.EmployeeKey
    JOIN dw.DimPurchaseStatus st ON st.StatusKey = f.StatusKey
    WHERE st.CountsAsSpend = 1
    GROUP BY d.FiscalYear, e.EmployeeName, e.JobTitle)
SELECT FiscalYear, RankInYear, Buyer, JobTitle, Orders, Spend, AvgOrderValue, ShareOfYearPct, BuyersInYear
FROM b
WHERE RankInYear <= 3
ORDER BY FiscalYear, RankInYear;
GO

-- Q7. Where does scrap come from? Scrap rate and cost by category, and each reason's share within the category
WITH s AS (
    SELECT p.Category, r.ScrapReason, SUM(w.ScrappedQty) AS Scrapped, SUM(w.ScrapCost) AS ScrapCost
    FROM dw.FactWorkOrder w
    JOIN dw.DimProduct p     ON p.ProductKey = w.ProductKey
    JOIN dw.DimScrapReason r ON r.ScrapReasonKey = w.ScrapReasonKey
    WHERE w.ScrappedQty > 0
    GROUP BY p.Category, r.ScrapReason),
c AS (
    SELECT p.Category, SUM(w.OrderQty) AS Units, SUM(w.ScrappedQty) AS Scrapped
    FROM dw.FactWorkOrder w JOIN dw.DimProduct p ON p.ProductKey = w.ProductKey
    GROUP BY p.Category)
SELECT c.Category, c.Units, c.Scrapped, CAST(100.0 * c.Scrapped / c.Units AS DECIMAL(6, 3)) AS ScrapPct,
       s.ScrapReason AS TopReason, CAST(100.0 * s.Scrapped / c.Scrapped AS DECIMAL(5, 1)) AS ReasonSharePct,
       (SELECT SUM(ScrapCost) FROM s s2 WHERE s2.Category = c.Category) AS ScrapCost
FROM c
CROSS APPLY (SELECT TOP (1) * FROM s WHERE s.Category = c.Category ORDER BY s.Scrapped DESC) s
ORDER BY ScrapPct DESC;
GO

-- Q8. Late work orders: share finished after the due date, by subcategory and fiscal year
SELECT p.Subcategory,
       SUM(CASE WHEN d.FiscalYear = 2012 THEN 1 ELSE 0 END) AS Orders2012,
       CAST(100.0 * SUM(CASE WHEN d.FiscalYear = 2012 AND w.DaysLate > 0 THEN 1 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN d.FiscalYear = 2012 THEN 1 ELSE 0 END), 0) AS DECIMAL(5, 1)) AS LatePct2012,
       CAST(100.0 * SUM(CASE WHEN d.FiscalYear = 2013 AND w.DaysLate > 0 THEN 1 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN d.FiscalYear = 2013 THEN 1 ELSE 0 END), 0) AS DECIMAL(5, 1)) AS LatePct2013,
       CAST(100.0 * SUM(CASE WHEN d.FiscalYear = 2014 AND w.DaysLate > 0 THEN 1 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN d.FiscalYear = 2014 THEN 1 ELSE 0 END), 0) AS DECIMAL(5, 1)) AS LatePct2014,
       CAST(AVG(CASE WHEN w.DaysLate > 0 THEN 1.0 * w.DaysLate END) AS DECIMAL(5, 1)) AS AvgDaysLateWhenLate,
       COUNT(*) AS WorkOrders
FROM dw.FactWorkOrder w
JOIN dw.DimDate d    ON d.DateKey = w.StartDateKey
JOIN dw.DimProduct p ON p.ProductKey = w.ProductKey
GROUP BY p.Subcategory
HAVING COUNT(*) >= 1000
ORDER BY WorkOrders DESC;
GO

-- Q9. Work centre load: resource hours per location per quarter, and each location's share of the quarter
SELECT d.YearQuarter, l.LocationName, COUNT(*) AS Operations,
       SUM(o.ResourceHours) AS Hours,
       CAST(100.0 * SUM(o.ResourceHours) / SUM(SUM(o.ResourceHours)) OVER (PARTITION BY d.YearQuarter) AS DECIMAL(5, 1)) AS ShareOfQuarterPct,
       SUM(o.ActualCost) AS Cost,
       CAST(SUM(o.ActualCost) / NULLIF(SUM(o.ResourceHours), 0) AS DECIMAL(8, 2)) AS CostPerHour
FROM dw.FactWorkOrderOperation o
JOIN dw.DimDate d     ON d.DateKey = o.ActualStartDateKey
JOIN dw.DimLocation l ON l.LocationKey = o.LocationKey
WHERE d.[Year] = 2013
GROUP BY d.YearQuarter, l.LocationName
ORDER BY d.YearQuarter, Hours DESC;
GO

-- Q10. Inventory on the snapshot date: value by category and sourcing, and how many products need reordering
SELECT Category, Sourcing, COUNT(*) AS Products, SUM(Quantity) AS Units,
       SUM(InventoryValue) AS InventoryValue,
       CAST(100.0 * SUM(InventoryValue) / SUM(SUM(InventoryValue)) OVER () AS DECIMAL(5, 1)) AS ValueSharePct,
       SUM(CASE WHEN StockStatus <> 'OK' THEN 1 ELSE 0 END) AS ProductsToReorder,
       SUM(CASE WHEN CostBasis = 'Last purchase price' THEN 1 ELSE 0 END) AS ValuedAtLastPrice,
       MIN(SnapshotDate) AS SnapshotDate
FROM rpt.vInventoryPosition
GROUP BY Category, Sourcing
ORDER BY InventoryValue DESC;
GO
