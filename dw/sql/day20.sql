-- Day 20: Slowly changing dimensions, the date dimension, surrogate keys
-- Goal: the three things that separate a textbook star from one that survives a year of real data.
-- Database: AdventureWorksDW2022 and AWPractice on SQL Server Express. Run one step at a time in SSMS (select it, press F5).
-- Every step, with its result screenshot and explanation: https://noortayyababatool-spec.github.io/sql-syllabus/day20/

-- ============================================================================
-- Slowly changing dimensions: Type 2 in AdventureWorksDW
-- ============================================================================

-- Step 1. Type 2 in the wild: one product, three rows, three price periods
-- Takeaway: Same product, three rows: the warehouse kept every price it ever had.
USE AdventureWorksDW2022;
SELECT ProductKey, ProductAlternateKey, EnglishProductName, ListPrice, StartDate, EndDate, Status
FROM DimProduct WHERE ProductAlternateKey = 'FR-M94B-38' ORDER BY StartDate;
GO

-- Step 2. The current row only
-- Takeaway: Type 2 question one: what is true now? Filter on the open row.
SELECT * FROM DimProduct WHERE ProductAlternateKey = 'FR-M94B-38' AND EndDate IS NULL;
GO

-- Step 3. Each sale is joined to the price in force at the time
-- Takeaway: Type 2 question two: what was true then? The surrogate key in the fact already answers it.
SELECT p.ProductKey, p.ListPrice AS PriceAtTime, p.StartDate, p.EndDate, COUNT(*) AS Lines, SUM(f.SalesAmount) AS Revenue
FROM FactResellerSales f JOIN DimProduct p ON f.ProductKey = p.ProductKey
WHERE p.ProductAlternateKey = 'FR-M94B-38' GROUP BY p.ProductKey, p.ListPrice, p.StartDate, p.EndDate;
GO

-- Step 4. How much history does DimProduct keep?
-- Takeaway: Duplicates of the natural key in a dimension usually mean Type 2 history, not bad data.
SELECT COUNT(*) AS DimRows, COUNT(DISTINCT ProductAlternateKey) AS Products,
       SUM(CASE WHEN EndDate IS NULL THEN 1 ELSE 0 END) AS OpenRows,
       COUNT(*) - COUNT(DISTINCT ProductAlternateKey) AS ExtraHistoryRows
FROM DimProduct;
GO

-- ============================================================================
-- Build Type 2 yourself: the rider dimension in AWPractice
-- ============================================================================

-- Step 5. The syllabus script first: CREATE TABLE DimRider
-- Takeaway: Read the error, then adapt: the table is already there, so alter it rather than recreate it.
USE AWPractice;
CREATE TABLE DimRider (
    RiderKey INT IDENTITY PRIMARY KEY,        -- surrogate
    RiderPhone VARCHAR(20) NOT NULL,           -- natural key
    RiderName VARCHAR(50), RiderCity VARCHAR(50),
    EffectiveFrom DATE NOT NULL, EffectiveTo DATE NULL, IsCurrent BIT NOT NULL DEFAULT 1
);
GO

-- Step 6. Turn the existing DimRider into a Type 2 dimension
-- Takeaway: A Type 2 dimension needs three things: a valid-from date, a valid-to date and a current flag.
IF COL_LENGTH('dbo.DimRider', 'IsCurrent') IS NULL          -- only the first time (re-runnable)
    ALTER TABLE dbo.DimRider ADD
        EffectiveFrom DATE NOT NULL CONSTRAINT DF_DimRider_From DEFAULT '2026-01-01',
        EffectiveTo   DATE NULL,
        IsCurrent     BIT  NOT NULL CONSTRAINT DF_DimRider_Current DEFAULT 1;
SELECT * FROM DimRider;
GO

-- Step 7. Ayesha moves to Islamabad on 15 October: close the old row, add a new one
-- Takeaway: Making a dimension Type 2 changes its rules: the natural key is no longer unique.
SET XACT_ABORT ON;     -- any error cancels the whole transaction
IF NOT EXISTS (SELECT 1 FROM DimRider WHERE RiderPhone = '0300-1111111' AND RiderCity = 'Islamabad')
BEGIN
    BEGIN TRANSACTION;
    UPDATE DimRider SET EffectiveTo = '2026-10-14', IsCurrent = 0
    WHERE RiderPhone = '0300-1111111' AND IsCurrent = 1;
    INSERT INTO DimRider (RiderPhone, RiderName, RiderCity, EffectiveFrom)
    VALUES ('0300-1111111', 'Ayesha', 'Islamabad', '2026-10-15');
    COMMIT;
END
SELECT * FROM DimRider ORDER BY RiderPhone, EffectiveFrom;
GO

-- Step 8. Replace the rule: one CURRENT row per phone number
-- Takeaway: A Type 2 dimension's rule is "one current row per natural key", not "one row per natural key".
DECLARE @uq sysname = (SELECT name FROM sys.key_constraints
                       WHERE parent_object_id = OBJECT_ID('dbo.DimRider') AND type = 'UQ');
IF @uq IS NOT NULL EXEC('ALTER TABLE dbo.DimRider DROP CONSTRAINT ' + @uq);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_DimRider_CurrentPhone')
    CREATE UNIQUE INDEX UX_DimRider_CurrentPhone ON dbo.DimRider (RiderPhone) WHERE IsCurrent = 1;
SELECT name, type_desc, is_unique, filter_definition FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.DimRider');
GO

-- Step 9. The same change again: now it works
-- Takeaway: Type 2 change = UPDATE the old row to close it + INSERT a new row. Never overwrite.
SET XACT_ABORT ON;     -- any error cancels the whole transaction
IF NOT EXISTS (SELECT 1 FROM DimRider WHERE RiderPhone = '0300-1111111' AND RiderCity = 'Islamabad')
BEGIN
    BEGIN TRANSACTION;
    UPDATE DimRider SET EffectiveTo = '2026-10-14', IsCurrent = 0
    WHERE RiderPhone = '0300-1111111' AND IsCurrent = 1;
    INSERT INTO DimRider (RiderPhone, RiderName, RiderCity, EffectiveFrom)
    VALUES ('0300-1111111', 'Ayesha', 'Islamabad', '2026-10-15');
    COMMIT;
END
SELECT * FROM DimRider ORDER BY RiderPhone, EffectiveFrom;
GO

-- Step 10. Lookup at load time: which RiderKey does a new ride get?
-- Takeaway: Fact loads look up the surrogate key by natural key AND date.
SELECT r.RideDate, d.RiderKey, d.RiderCity
FROM (VALUES (CAST('2026-10-01' AS DATE)), ('2026-10-20')) AS r(RideDate)
JOIN DimRider d ON d.RiderPhone = '0300-1111111'
 AND r.RideDate BETWEEN d.EffectiveFrom AND ISNULL(d.EffectiveTo, '9999-12-31');
GO

-- Step 11. Her old rides keep her old city
-- Takeaway: Old facts point at old rows, so old reports stay correct.
SELECT f.RideID, f.PickupTime, r.RiderKey, r.RiderName, r.RiderCity, f.FareAmount
FROM FactRide f JOIN DimRider r ON r.RiderKey = f.RiderKey
WHERE r.RiderPhone = '0300-1111111';
GO

-- Step 12. What Type 1 would have done: rewrite history
-- Takeaway: Type 1 moves old facts to the new value. Fine for corrections, wrong for real changes.
SELECT f.RideID, f.PickupTime, r.RiderCity AS CityAtTimeOfRide, cur.RiderCity AS CityIfOverwritten
FROM FactRide f
JOIN DimRider r   ON r.RiderKey = f.RiderKey
JOIN DimRider cur ON cur.RiderPhone = r.RiderPhone AND cur.IsCurrent = 1
WHERE r.RiderPhone = '0300-1111111';
GO

-- Step 13. Type 1 for a correction: fix her name everywhere
-- Takeaway: Decide the type per column, not per table.
UPDATE DimRider SET RiderName = 'Ayesha Khan' WHERE RiderPhone = '0300-1111111';
SELECT RiderKey, RiderPhone, RiderName, RiderCity, EffectiveFrom, EffectiveTo, IsCurrent FROM DimRider;
GO

-- ============================================================================
-- The date dimension
-- ============================================================================

-- Step 14. Read the real one
-- Takeaway: Work done once, in the dimension, so no report ever has to compute it.
USE AdventureWorksDW2022;
SELECT TOP 5 * FROM DimDate WHERE CalendarYear = 2013 AND MonthNumberOfYear = 7;
GO

-- Step 15. How many days does it cover?
-- Takeaway: A date dimension has every day, not just the days with facts.
SELECT COUNT(*) AS Days, MIN(FullDateAlternateKey) AS FirstDay, MAX(FullDateAlternateKey) AS LastDay FROM DimDate;
GO

-- Step 16. Build my own for 2026 in AWPractice
-- Takeaway: Build it once with a script, keep the script, extend the years when needed.
USE AWPractice;
DROP TABLE IF EXISTS dbo.DimDate;
CREATE TABLE DimDate (
    DateKey INT PRIMARY KEY, FullDate DATE NOT NULL, Year INT, Quarter INT, Month INT, MonthName VARCHAR(10),
    Day INT, DayOfWeek INT, DayName VARCHAR(10), IsWeekend BIT, WeekOfYear INT, FiscalYear INT, FiscalQuarter INT
);
;WITH Dates AS (
    SELECT CAST('2026-01-01' AS DATE) AS d
    UNION ALL SELECT DATEADD(day, 1, d) FROM Dates WHERE d < '2026-12-31'
)
INSERT INTO DimDate
SELECT CONVERT(INT, FORMAT(d, 'yyyyMMdd')), d, YEAR(d), DATEPART(quarter, d), MONTH(d), DATENAME(month, d),
       DAY(d), DATEPART(weekday, d), DATENAME(weekday, d), CASE WHEN DATEPART(weekday, d) IN (1, 7) THEN 1 ELSE 0 END,
       DATEPART(week, d),
       CASE WHEN MONTH(d) >= 7 THEN YEAR(d) + 1 ELSE YEAR(d) END,            -- fiscal year starts July
       CASE WHEN MONTH(d) >= 7 THEN DATEPART(quarter, d) - 2 ELSE DATEPART(quarter, d) + 2 END
FROM Dates OPTION (MAXRECURSION 400);
SELECT COUNT(*) AS Days, MIN(FullDate) AS FirstDay, MAX(FullDate) AS LastDay FROM DimDate;
GO

-- Step 17. October 2026 in the new DimDate
-- Takeaway: Every attribute a report could want, ready to filter and group by.
SELECT * FROM DimDate WHERE Month = 10;
GO

-- Step 18. Check the fiscal columns: the first day of each month
-- Takeaway: Test generated columns against cases you can work out by hand.
SELECT Month, MonthName, FiscalYear, FiscalQuarter FROM DimDate WHERE Day = 1 ORDER BY DateKey;
GO

-- Step 19. Use it: rides by day, weekend flag and fiscal period
-- Takeaway: The fact stores a date key; everything about the date comes from the dimension.
SELECT d.FullDate, d.DayName, d.IsWeekend, d.FiscalYear, d.FiscalQuarter, COUNT(*) AS Rides, SUM(f.FareAmount) AS Fare
FROM FactRide f JOIN DimDate d ON d.DateKey = f.DateKey
GROUP BY d.FullDate, d.DayName, d.IsWeekend, d.FiscalYear, d.FiscalQuarter;
GO

-- ============================================================================
-- Surrogate keys: why the fact never stores the natural key
-- ============================================================================

-- Step 20. Join on the natural key instead of the surrogate
-- Takeaway: Facts store surrogate keys only; the natural key stays in the dimension for lookups.
USE AdventureWorksDW2022;
SELECT 'Surrogate key (ProductKey)' AS JoinedOn, COUNT(*) AS Lines, SUM(f.SalesAmount) AS Revenue
FROM FactResellerSales f JOIN DimProduct p ON p.ProductKey = f.ProductKey
WHERE p.ProductAlternateKey = 'FR-M94B-38'
UNION ALL
SELECT 'Natural key (ProductAlternateKey)', COUNT(*), SUM(f.SalesAmount)
FROM FactResellerSales f
JOIN DimProduct sold ON sold.ProductKey = f.ProductKey
JOIN DimProduct p    ON p.ProductAlternateKey = sold.ProductAlternateKey
WHERE p.ProductAlternateKey = 'FR-M94B-38';
GO

