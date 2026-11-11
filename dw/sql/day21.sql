-- Day 21: Week 3 assessment and instructor update
-- Goal: answer 15 questions on warehousing (concepts, queries, modelling) and report the week to my instructor.
-- Database: AdventureWorksDW2022 and AWPractice on SQL Server Express. Run one step at a time in SSMS (select it, press F5).
-- Every step, with its result screenshot and explanation: https://noortayyababatool-spec.github.io/sql-syllabus/day21/

-- ============================================================================
-- Assessment queries (questions 9 to 13)
-- ============================================================================

-- Step 1. Q9. Revenue by product category by calendar year, years as columns
-- Takeaway: Pivot = GROUP BY two attributes, then spread one of them across columns.
USE AdventureWorksDW2022;
SELECT Category, [2010], [2011], [2012], [2013], [2014]
FROM (SELECT pc.EnglishProductCategoryName AS Category, d.CalendarYear, f.SalesAmount
      FROM FactInternetSales f
      JOIN DimDate d                ON d.DateKey = f.OrderDateKey
      JOIN DimProduct p             ON p.ProductKey = f.ProductKey
      JOIN DimProductSubcategory ps ON ps.ProductSubcategoryKey = p.ProductSubcategoryKey
      JOIN DimProductCategory pc    ON pc.ProductCategoryKey = ps.ProductCategoryKey) AS src
PIVOT (SUM(SalesAmount) FOR CalendarYear IN ([2010], [2011], [2012], [2013], [2014])) AS pv
ORDER BY Category;
GO

-- Step 2. Q10. Top 5 cities by internet sales revenue
-- Takeaway: Group by enough columns to identify the thing, not just its name.
SELECT TOP 5 g.City, g.StateProvinceName, g.EnglishCountryRegionName AS Country, SUM(f.SalesAmount) AS Revenue
FROM FactInternetSales f
JOIN DimCustomer c  ON c.CustomerKey = f.CustomerKey
JOIN DimGeography g ON g.GeographyKey = c.GeographyKey
GROUP BY g.City, g.StateProvinceName, g.EnglishCountryRegionName
ORDER BY Revenue DESC;
GO

-- Step 3. Q11. Average order value by education level and gender
-- Takeaway: Ratios are computed from additive totals, never averaged from rows.
SELECT c.EnglishEducation AS Education, c.Gender,
       COUNT(DISTINCT f.SalesOrderNumber) AS Orders, SUM(f.SalesAmount) AS Revenue,
       SUM(f.SalesAmount) / COUNT(DISTINCT f.SalesOrderNumber) AS AvgOrderValue
FROM FactInternetSales f JOIN DimCustomer c ON c.CustomerKey = f.CustomerKey
GROUP BY c.EnglishEducation, c.Gender
ORDER BY Education, c.Gender;
GO

-- Step 4. Q12. Reseller vs internet revenue per quarter, in one result set
-- Takeaway: Two facts: aggregate each to the shared grain first, then join on the conformed dimension.
WITH i AS (SELECT d.CalendarYear, d.CalendarQuarter, SUM(f.SalesAmount) AS Internet
           FROM FactInternetSales f JOIN DimDate d ON d.DateKey = f.OrderDateKey
           GROUP BY d.CalendarYear, d.CalendarQuarter),
     r AS (SELECT d.CalendarYear, d.CalendarQuarter, SUM(f.SalesAmount) AS Reseller
           FROM FactResellerSales f JOIN DimDate d ON d.DateKey = f.OrderDateKey
           GROUP BY d.CalendarYear, d.CalendarQuarter)
SELECT COALESCE(i.CalendarYear, r.CalendarYear) AS Year, COALESCE(i.CalendarQuarter, r.CalendarQuarter) AS Qtr,
       ISNULL(r.Reseller, 0) AS Reseller, ISNULL(i.Internet, 0) AS Internet
FROM i FULL JOIN r ON r.CalendarYear = i.CalendarYear AND r.CalendarQuarter = i.CalendarQuarter
ORDER BY Year, Qtr;
GO

-- Step 5. Q13. Product FR-M94B-38: revenue per price period (Type 2 rows)
-- Takeaway: Group by the surrogate key to report "per version" of a Type 2 dimension.
SELECT p.ProductKey, p.ListPrice, p.StartDate, p.Status,
       MIN(d.FullDateAlternateKey) AS FirstSale, MAX(d.FullDateAlternateKey) AS LastSale,
       COUNT(*) AS Lines, SUM(f.OrderQuantity) AS Units, SUM(f.SalesAmount) AS Revenue
FROM FactResellerSales f
JOIN DimProduct p ON p.ProductKey = f.ProductKey
JOIN DimDate d    ON d.DateKey = f.OrderDateKey
WHERE p.ProductAlternateKey = 'FR-M94B-38'
GROUP BY p.ProductKey, p.ListPrice, p.StartDate, p.Status
ORDER BY p.StartDate;
GO

-- ============================================================================
-- Modelling (questions 14 and 15): the hospital star, built as tables
-- ============================================================================

-- Step 6. Q14 and Q15. The hospital star schema in SQL
-- Takeaway: A star you can CREATE is a star whose keys and grain have been thought through.
USE AWPractice;
IF SCHEMA_ID('hosp') IS NULL EXEC('CREATE SCHEMA hosp');
DROP TABLE IF EXISTS hosp.FactVisitProcedure, hosp.DimPatient, hosp.DimDoctor, hosp.DimDiagnosis, hosp.DimProcedure, hosp.DimInsurance;
CREATE TABLE hosp.DimPatient   (PatientKey INT IDENTITY PRIMARY KEY, PatientID INT NOT NULL UNIQUE, PatientName VARCHAR(100), DateOfBirth DATE);
CREATE TABLE hosp.DimDoctor    (DoctorKey INT IDENTITY PRIMARY KEY, DoctorID INT NOT NULL, DoctorName VARCHAR(100), Department VARCHAR(50),
                                EffectiveFrom DATE NOT NULL, EffectiveTo DATE NULL, IsCurrent BIT NOT NULL DEFAULT 1);   -- Type 2
CREATE TABLE hosp.DimDiagnosis (DiagnosisKey INT IDENTITY PRIMARY KEY, DiagnosisCode VARCHAR(10) NOT NULL UNIQUE, DiagnosisDescription VARCHAR(200));
CREATE TABLE hosp.DimProcedure (ProcedureKey INT IDENTITY PRIMARY KEY, ProcedureCode VARCHAR(10) NOT NULL UNIQUE);
CREATE TABLE hosp.DimInsurance (InsuranceKey INT IDENTITY PRIMARY KEY, InsuranceProvider VARCHAR(100) NOT NULL UNIQUE);
CREATE TABLE hosp.FactVisitProcedure (
    VisitID INT NOT NULL,                          -- degenerate dimension: the visit number itself
    VisitDateKey INT NOT NULL,                     -- yyyymmdd, joins to the shared dbo.DimDate
    VisitHour TINYINT NOT NULL,
    PatientKey   INT NOT NULL REFERENCES hosp.DimPatient,
    DoctorKey    INT NOT NULL REFERENCES hosp.DimDoctor,
    DiagnosisKey INT NOT NULL REFERENCES hosp.DimDiagnosis,
    ProcedureKey INT NOT NULL REFERENCES hosp.DimProcedure,
    InsuranceKey INT NOT NULL REFERENCES hosp.DimInsurance,
    DurationMinutes INT, BillAmount DECIMAL(12, 2), PaidAmount DECIMAL(12, 2),
    PRIMARY KEY (VisitID, ProcedureKey));          -- the grain: one procedure in one visit
SELECT OBJECT_NAME(fk.parent_object_id) AS FromTable, OBJECT_NAME(fk.referenced_object_id) AS ToDimension
FROM sys.foreign_keys fk WHERE OBJECT_SCHEMA_NAME(fk.parent_object_id) = 'hosp' ORDER BY ToDimension;
GO

