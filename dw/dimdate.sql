-- dimdate.sql: build a date dimension (one row per calendar day)
--
-- What it is: a table with one row for every day between @From and @To, with the
-- year, quarter, month, weekday, weekend flag and fiscal period already worked out.
-- Fact tables store an integer DateKey such as 20261030 and join to this table,
-- so no report has to calculate YEAR(), DATENAME() or fiscal periods itself.
--
-- How to use: pick a database, change @From and @To if you need other years, run the whole file.
-- It is re-runnable: it drops and rebuilds dbo.DimDate each time.
-- Built on Day 20: https://noortayyababatool-spec.github.io/sql-syllabus/day20/

USE AWPractice;
GO

DROP TABLE IF EXISTS dbo.DimDate;
CREATE TABLE dbo.DimDate (
    DateKey       INT         NOT NULL PRIMARY KEY,   -- yyyymmdd, e.g. 20261030
    FullDate      DATE        NOT NULL,
    Year          INT         NOT NULL,
    Quarter       INT         NOT NULL,               -- 1 to 4
    Month         INT         NOT NULL,               -- 1 to 12
    MonthName     VARCHAR(10) NOT NULL,               -- January
    Day           INT         NOT NULL,               -- day of the month
    DayOfWeek     INT         NOT NULL,               -- 1 = Sunday ... 7 = Saturday (us_english default)
    DayName       VARCHAR(10) NOT NULL,               -- Monday
    IsWeekend     BIT         NOT NULL,
    WeekOfYear    INT         NOT NULL,
    FiscalYear    INT         NOT NULL,               -- fiscal year starts 1 July and is named after the year it ends
    FiscalQuarter INT         NOT NULL                -- July to September = fiscal Q1
);
GO

DECLARE @From DATE = '2026-01-01';
DECLARE @To   DATE = '2026-12-31';

-- A recursive CTE produces one row per day; MAXRECURSION 0 removes the 100-level limit
-- so the range can be any length.
WITH Dates AS (
    SELECT @From AS d
    UNION ALL
    SELECT DATEADD(day, 1, d) FROM Dates WHERE d < @To
)
INSERT INTO dbo.DimDate
SELECT CONVERT(INT, FORMAT(d, 'yyyyMMdd')),
       d,
       YEAR(d),
       DATEPART(quarter, d),
       MONTH(d),
       DATENAME(month, d),
       DAY(d),
       DATEPART(weekday, d),
       DATENAME(weekday, d),
       CASE WHEN DATEPART(weekday, d) IN (1, 7) THEN 1 ELSE 0 END,     -- Sunday or Saturday
       DATEPART(week, d),
       CASE WHEN MONTH(d) >= 7 THEN YEAR(d) + 1 ELSE YEAR(d) END,
       CASE WHEN MONTH(d) >= 7 THEN DATEPART(quarter, d) - 2 ELSE DATEPART(quarter, d) + 2 END
FROM Dates
OPTION (MAXRECURSION 0);
GO

-- Checks: the right number of days, and fiscal periods on the first day of each month
SELECT COUNT(*) AS Days, MIN(FullDate) AS FirstDay, MAX(FullDate) AS LastDay FROM dbo.DimDate;
SELECT Month, MonthName, FiscalYear, FiscalQuarter FROM dbo.DimDate WHERE Day = 1 ORDER BY DateKey;
