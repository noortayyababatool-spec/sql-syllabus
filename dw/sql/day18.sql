-- Day 18: Basic reporting queries on the warehouse
-- Goal: write the standard report shapes against a star schema and feel how much easier they are than on OLTP.
-- Database: AdventureWorksDW2022 on SQL Server Express. Run one step at a time in SSMS (select it, press F5).
-- Every step, with its result screenshot and explanation: https://noortayyababatool-spec.github.io/sql-syllabus/day18/

-- ============================================================================
-- Drill
-- ============================================================================

-- Step 1. Revenue by year and quarter
-- Takeaway: The first and last rows of any time series are often partial periods. Check the date range before comparing them.
USE AdventureWorksDW2022;
SELECT d.CalendarYear, d.CalendarQuarter, SUM(f.SalesAmount) AS Revenue
FROM FactInternetSales f JOIN DimDate d ON f.OrderDateKey = d.DateKey
GROUP BY d.CalendarYear, d.CalendarQuarter ORDER BY 1, 2;
GO

-- Step 2. Revenue by product category
-- Takeaway: Bikes are 96% of internet revenue. Reconcile category totals with the fact total to prove the joins dropped nothing.
SELECT pc.EnglishProductCategoryName AS Category, SUM(f.SalesAmount) AS Revenue
FROM FactInternetSales f
JOIN DimProduct p ON f.ProductKey = p.ProductKey
JOIN DimProductSubcategory ps ON p.ProductSubcategoryKey = ps.ProductSubcategoryKey
JOIN DimProductCategory pc ON ps.ProductCategoryKey = pc.ProductCategoryKey
GROUP BY pc.EnglishProductCategoryName ORDER BY Revenue DESC;
GO

-- Step 3. Revenue by country and year, as a pivot
-- Takeaway: A manual pivot only shows the years you typed. Add a total column or check the grand total so missing years are noticed.
SELECT g.EnglishCountryRegionName AS Country,
       SUM(CASE WHEN d.CalendarYear = 2012 THEN f.SalesAmount ELSE 0 END) AS Y2012,
       SUM(CASE WHEN d.CalendarYear = 2013 THEN f.SalesAmount ELSE 0 END) AS Y2013,
       SUM(CASE WHEN d.CalendarYear = 2014 THEN f.SalesAmount ELSE 0 END) AS Y2014
FROM FactInternetSales f
JOIN DimCustomer c ON f.CustomerKey = c.CustomerKey
JOIN DimGeography g ON c.GeographyKey = g.GeographyKey
JOIN DimDate d ON f.OrderDateKey = d.DateKey
GROUP BY g.EnglishCountryRegionName ORDER BY Country;
GO

-- Step 4. Customer demographics
-- Takeaway: One join for a demographic report. The hard work was done once, when DimCustomer was built.
SELECT c.Gender, c.MaritalStatus, c.EnglishEducation, COUNT(DISTINCT f.CustomerKey) AS Customers, SUM(f.SalesAmount) AS Revenue
FROM FactInternetSales f JOIN DimCustomer c ON f.CustomerKey = c.CustomerKey
GROUP BY c.Gender, c.MaritalStatus, c.EnglishEducation ORDER BY Revenue DESC;
GO

-- Step 5. Weekday vs weekend sales
-- Takeaway: Compare per-day averages, not totals: there are five weekdays and two weekend days. Check what 1 and 7 mean in your date table before you trust it.
SELECT CASE WHEN d.DayNumberOfWeek IN (1, 7) THEN 'Weekend' ELSE 'Weekday' END AS DayType, COUNT(*) AS Lines, SUM(f.SalesAmount) AS Revenue
FROM FactInternetSales f JOIN DimDate d ON f.OrderDateKey = d.DateKey
GROUP BY CASE WHEN d.DayNumberOfWeek IN (1, 7) THEN 'Weekend' ELSE 'Weekday' END;
GO

-- Step 6. Internet vs reseller: two facts, same dimension
-- Takeaway: Aggregate each fact to the shared grain, then combine. Never join two fact tables row to row.
SELECT 'Internet' AS Channel, d.CalendarYear, SUM(f.SalesAmount) AS Revenue
FROM FactInternetSales f JOIN DimDate d ON f.OrderDateKey = d.DateKey GROUP BY d.CalendarYear
UNION ALL
SELECT 'Reseller', d.CalendarYear, SUM(f.SalesAmount)
FROM FactResellerSales f JOIN DimDate d ON f.OrderDateKey = d.DateKey GROUP BY d.CalendarYear
ORDER BY CalendarYear, Channel;
GO

-- Step 7. Margin by product
-- Takeaway: Additive measures can be combined row by row; ratios must be rebuilt from the totals.
SELECT p.EnglishProductName, SUM(f.SalesAmount) AS Revenue, SUM(f.TotalProductCost) AS Cost,
       SUM(f.SalesAmount - f.TotalProductCost) AS Margin,
       SUM(f.SalesAmount - f.TotalProductCost) / SUM(f.SalesAmount) * 100 AS MarginPct
FROM FactInternetSales f JOIN DimProduct p ON f.ProductKey = p.ProductKey
GROUP BY p.EnglishProductName HAVING SUM(f.SalesAmount) > 100000 ORDER BY MarginPct DESC;
GO

-- Step 8. Role-playing dimension: DimDate three times
-- Takeaway: Same table, three aliases, three meanings. In Power BI only one relationship can be active, so you use USERELATIONSHIP or one date table per role.
SELECT TOP 10 f.SalesOrderNumber, od.FullDateAlternateKey AS Ordered, sd.FullDateAlternateKey AS Shipped, dd.FullDateAlternateKey AS Due,
       DATEDIFF(day, od.FullDateAlternateKey, sd.FullDateAlternateKey) AS DaysToShip
FROM FactInternetSales f
JOIN DimDate od ON f.OrderDateKey = od.DateKey
JOIN DimDate sd ON f.ShipDateKey = sd.DateKey
JOIN DimDate dd ON f.DueDateKey = dd.DateKey;
GO

-- Step 9. Year-over-year growth with LAG
-- Takeaway: Before quoting growth, check that both periods are complete. Partial years make huge, false percentages.
WITH Yearly AS (
    SELECT d.CalendarYear, SUM(f.SalesAmount) AS Revenue
    FROM FactInternetSales f JOIN DimDate d ON f.OrderDateKey = d.DateKey GROUP BY d.CalendarYear
)
SELECT CalendarYear, Revenue, LAG(Revenue) OVER (ORDER BY CalendarYear) AS PrevYear,
       (Revenue - LAG(Revenue) OVER (ORDER BY CalendarYear)) / LAG(Revenue) OVER (ORDER BY CalendarYear) * 100 AS GrowthPct
FROM Yearly;
GO

-- Step 10. 10a. Category revenue on the warehouse, with statistics
-- Takeaway: Three joins, no filter: everything the report needs is already in the fact and its dimensions.
SET STATISTICS IO ON; SET STATISTICS TIME ON;
SELECT pc.EnglishProductCategoryName AS Category, SUM(f.SalesAmount) AS Revenue
FROM FactInternetSales f
JOIN DimProduct p ON f.ProductKey = p.ProductKey
JOIN DimProductSubcategory ps ON p.ProductSubcategoryKey = ps.ProductSubcategoryKey
JOIN DimProductCategory pc ON ps.ProductCategoryKey = pc.ProductCategoryKey
GROUP BY pc.EnglishProductCategoryName ORDER BY Revenue DESC;
GO

-- Step 11. 10b. The same question on the OLTP database
-- Takeaway: The warehouse wins twice: less work for the server and fewer joins (and filters) for the person writing the query.
USE AdventureWorks2022;
SET STATISTICS IO ON; SET STATISTICS TIME ON;
SELECT pc.Name AS Category, SUM(d.LineTotal) AS Revenue
FROM Sales.SalesOrderDetail d
JOIN Production.Product p ON d.ProductID = p.ProductID
JOIN Production.ProductSubcategory ps ON p.ProductSubcategoryID = ps.ProductSubcategoryID
JOIN Production.ProductCategory pc ON ps.ProductCategoryID = pc.ProductCategoryID
JOIN Sales.SalesOrderHeader h ON d.SalesOrderID = h.SalesOrderID
WHERE h.OnlineOrderFlag = 1
GROUP BY pc.Name ORDER BY Revenue DESC;
GO

-- ============================================================================
-- Self-test
-- ============================================================================

-- Step 12. S1. Revenue by month for Bikes in Australia
-- Takeaway: Six joins, but every one is fact to dimension or dimension to dimension. The pattern does not change as the question grows.
USE AdventureWorksDW2022;
SELECT d.CalendarYear, d.MonthNumberOfYear, d.EnglishMonthName, SUM(f.SalesAmount) AS Revenue
FROM FactInternetSales f
JOIN DimDate d ON f.OrderDateKey = d.DateKey
JOIN DimProduct p ON f.ProductKey = p.ProductKey
JOIN DimProductSubcategory ps ON p.ProductSubcategoryKey = ps.ProductSubcategoryKey
JOIN DimProductCategory pc ON ps.ProductCategoryKey = pc.ProductCategoryKey
JOIN DimCustomer c ON f.CustomerKey = c.CustomerKey
JOIN DimGeography g ON c.GeographyKey = g.GeographyKey
WHERE pc.EnglishProductCategoryName = 'Bikes' AND g.EnglishCountryRegionName = 'Australia'
GROUP BY d.CalendarYear, d.MonthNumberOfYear, d.EnglishMonthName
ORDER BY d.CalendarYear, d.MonthNumberOfYear;
GO

-- Step 13. S2. Distinct customers per education level
-- Takeaway: "How many customers" needs COUNT(DISTINCT key) on a fact; COUNT(*) counts rows at the fact's grain.
SELECT c.EnglishEducation, COUNT(DISTINCT f.CustomerKey) AS Customers
FROM FactInternetSales f JOIN DimCustomer c ON f.CustomerKey = c.CustomerKey
GROUP BY c.EnglishEducation ORDER BY Customers DESC;
GO

-- Step 14. S3. Average days to ship per year
-- Takeaway: Sample data is often too regular. A real business would show a spread here, and you would report it with a median or a histogram too.
SELECT d.CalendarYear, AVG(CAST(DATEDIFF(day, od.FullDateAlternateKey, sd.FullDateAlternateKey) AS DECIMAL(5,2))) AS AvgDaysToShip, COUNT(*) AS Lines
FROM FactInternetSales f
JOIN DimDate od ON f.OrderDateKey = od.DateKey
JOIN DimDate sd ON f.ShipDateKey = sd.DateKey
JOIN DimDate d ON f.OrderDateKey = d.DateKey
GROUP BY d.CalendarYear ORDER BY d.CalendarYear;
GO

-- Step 15. S4. Which reseller business type buys the most
-- Takeaway: When a question says "most", show the total and the per-member average: they can rank differently.
SELECT r.BusinessType, COUNT(DISTINCT f.ResellerKey) AS Resellers, SUM(f.SalesAmount) AS Revenue,
       SUM(f.SalesAmount) / COUNT(DISTINCT f.ResellerKey) AS RevenuePerReseller
FROM FactResellerSales f JOIN DimReseller r ON f.ResellerKey = r.ResellerKey
GROUP BY r.BusinessType ORDER BY Revenue DESC;
GO

