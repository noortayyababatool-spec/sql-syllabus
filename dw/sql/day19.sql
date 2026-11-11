-- Day 19: Star schema and snowflake schema
-- Goal: draw both, say when each is used, and recognise that AdventureWorksDW is a mix.
-- Database: AdventureWorksDW2022 and AWPractice on SQL Server Express. Run one step at a time in SSMS (select it, press F5).
-- Every step, with its result screenshot and explanation: https://noortayyababatool-spec.github.io/sql-syllabus/day19/

-- ============================================================================
-- Drill: find both in AdventureWorksDW
-- ============================================================================

-- Step 1. Every foreign key: the schema diagram as data
-- Takeaway: A database diagram is just this list drawn as boxes and lines.
USE AdventureWorksDW2022;
SELECT fk.name AS FK, OBJECT_NAME(fk.parent_object_id) AS FromTable, OBJECT_NAME(fk.referenced_object_id) AS ToTable
FROM sys.foreign_keys fk ORDER BY FromTable, ToTable;
GO

-- Step 2. The star part: what FactInternetSales joins to directly
-- Takeaway: Six points on the star; DimDate is used three times in different roles.
SELECT OBJECT_NAME(fk.referenced_object_id) AS Dimension
FROM sys.foreign_keys fk WHERE OBJECT_NAME(fk.parent_object_id) = 'FactInternetSales';
GO

-- Step 3. The snowflake part: dimensions that point at other dimensions
-- Takeaway: AdventureWorksDW is a star at the fact and a snowflake around product, geography and territory.
SELECT OBJECT_NAME(fk.parent_object_id) AS Dimension, OBJECT_NAME(fk.referenced_object_id) AS PointsTo
FROM sys.foreign_keys fk
WHERE OBJECT_NAME(fk.parent_object_id) LIKE 'Dim%' AND OBJECT_NAME(fk.referenced_object_id) LIKE 'Dim%';
GO

-- Step 4. Flatten the product snowflake into a view
-- Takeaway: This is what you hand to Power BI: one product table, one relationship to the fact.
CREATE OR ALTER VIEW dbo.vw_DimProductFlat AS
SELECT p.ProductKey, p.EnglishProductName AS Product, p.Color, p.Size, p.ListPrice,
       ps.EnglishProductSubcategoryName AS Subcategory, pc.EnglishProductCategoryName AS Category
FROM DimProduct p
LEFT JOIN DimProductSubcategory ps ON p.ProductSubcategoryKey = ps.ProductSubcategoryKey
LEFT JOIN DimProductCategory pc ON ps.ProductCategoryKey = pc.ProductCategoryKey;
GO

-- Step 5. Day 18 drill 2 through the view: one join instead of three
-- Takeaway: Fewer joins for the person writing the query. Whether the server does less work is the next question.
SELECT v.Category, SUM(f.SalesAmount) AS Revenue
FROM FactInternetSales f JOIN dbo.vw_DimProductFlat v ON f.ProductKey = v.ProductKey
GROUP BY v.Category ORDER BY Revenue DESC;
GO

-- Step 6. Cost of the snowflake: the plan for three joins
-- Takeaway: Count the join operators in the plan: one per table after the first.
SELECT pc.EnglishProductCategoryName AS Category, SUM(f.SalesAmount) AS Revenue
FROM FactInternetSales f
JOIN DimProduct p ON f.ProductKey = p.ProductKey
JOIN DimProductSubcategory ps ON p.ProductSubcategoryKey = ps.ProductSubcategoryKey
JOIN DimProductCategory pc ON ps.ProductCategoryKey = pc.ProductCategoryKey
GROUP BY pc.EnglishProductCategoryName ORDER BY Revenue DESC;
GO

-- Step 7. The view version of the same plan
-- Takeaway: A view flattens the model for people; a flattened table flattens it for the server too.
SELECT v.Category, SUM(f.SalesAmount) AS Revenue
FROM FactInternetSales f JOIN dbo.vw_DimProductFlat v ON f.ProductKey = v.ProductKey
GROUP BY v.Category ORDER BY Revenue DESC;
GO

-- Step 8. Cost of the star: how much text flattening would repeat
-- Takeaway: Check the syllabus' estimates against the data: here the repetition is double what was predicted, and the conclusion still holds.
SELECT COUNT(*) AS Customers, COUNT(DISTINCT GeographyKey) AS DistinctGeographies,
       COUNT(*) * 1.0 / COUNT(DISTINCT GeographyKey) AS CustomersPerGeography,
       (SELECT COUNT(*) FROM DimGeography) AS GeographyRows
FROM DimCustomer;
GO

-- Step 9. Conformed dimension: one DimDate shared by every fact
-- Takeaway: A conformed dimension is one dimension table used by several facts, with the same keys and the same meaning.
SELECT OBJECT_NAME(fk.parent_object_id) AS Fact, COUNT(*) AS DateKeys
FROM sys.foreign_keys fk WHERE OBJECT_NAME(fk.referenced_object_id) = 'DimDate' GROUP BY OBJECT_NAME(fk.parent_object_id);
GO

-- Step 10. Database diagram: FactInternetSales and its six dimensions
-- Takeaway: This is the star: one fact, one join to every dimension.
-- SSMS: Object Explorer > Databases > AdventureWorksDW2022 > Database Diagrams > New Database Diagram
-- (Yes to "create the support objects", the first time only)
-- Add Table: FactInternetSales, DimCurrency, DimCustomer, DimDate, DimProduct, DimPromotion, DimSalesTerritory
-- Select all > Table View > Keys, then right-click > Arrange Tables
GO

-- Step 11. The same diagram with DimProductSubcategory and DimProductCategory
-- Takeaway: A star grows a branch: that branch is a snowflake.
-- Right-click the diagram > Add Table: DimProductSubcategory, DimProductCategory
-- Table View > Keys, Arrange Tables, zoom 55%
GO

-- ============================================================================
-- Written exercise: the ride model as a star and as a snowflake
-- ============================================================================

-- Step 12. Pure star: Zone and City in one table, Vehicle folded into the driver
-- Takeaway: Each dimension is one flat table, one join from the fact.
USE AWPractice;
DROP TABLE IF EXISTS dbo.StarLocation, dbo.StarDriver;
SELECT ZoneKey AS LocationKey, ZoneName AS Zone, City INTO StarLocation FROM DimZone;
SELECT DISTINCT d.DriverKey, d.DriverName, v.VehiclePlate, v.VehicleType
INTO StarDriver
FROM FactRide f JOIN DimDriver d ON d.DriverKey = f.DriverKey JOIN DimVehicle v ON v.VehicleKey = f.VehicleKey;
SELECT * FROM StarLocation; SELECT * FROM StarDriver;
GO

-- Step 13. Fare by city by month on the star: 2 joins
-- Takeaway: Star: one join per dimension used.
SELECT l.City, d.CalendarYear, d.MonthName, SUM(f.FareAmount) AS Fare
FROM FactRide f
JOIN StarLocation l ON l.LocationKey = f.PickupZoneKey
JOIN DimRideDate d ON d.DateKey = f.DateKey
GROUP BY l.City, d.CalendarYear, d.MonthName;
GO

-- Step 14. Snowflake: Zone points to City, Driver to Vehicle to VehicleType
-- Takeaway: Snowflake: no repeated text, but each level is another table.
DROP TABLE IF EXISTS dbo.SnowDriver, dbo.SnowVehicle, dbo.SnowVehicleType, dbo.SnowZone, dbo.SnowCity;
SELECT IDENTITY(INT, 1, 1) AS CityKey, City INTO SnowCity FROM (SELECT DISTINCT City FROM DimZone) c;
SELECT z.ZoneKey, z.ZoneName, c.CityKey INTO SnowZone FROM DimZone z JOIN SnowCity c ON c.City = z.City;
SELECT IDENTITY(INT, 1, 1) AS VehicleTypeKey, VehicleType INTO SnowVehicleType FROM (SELECT DISTINCT VehicleType FROM DimVehicle) t;
SELECT v.VehicleKey, v.VehiclePlate, t.VehicleTypeKey INTO SnowVehicle FROM DimVehicle v JOIN SnowVehicleType t ON t.VehicleType = v.VehicleType;
SELECT DISTINCT f.DriverKey, d.DriverName, f.VehicleKey INTO SnowDriver FROM FactRide f JOIN DimDriver d ON d.DriverKey = f.DriverKey;
SELECT 'SnowCity' AS T, COUNT(*) AS Rows FROM SnowCity UNION ALL SELECT 'SnowZone', COUNT(*) FROM SnowZone
UNION ALL SELECT 'SnowVehicleType', COUNT(*) FROM SnowVehicleType UNION ALL SELECT 'SnowVehicle', COUNT(*) FROM SnowVehicle
UNION ALL SELECT 'SnowDriver', COUNT(*) FROM SnowDriver;
GO

-- Step 15. Fare by city by month on the snowflake: 3 joins
-- Takeaway: I would ship the star (reasons below the queries).
SELECT c.City, d.CalendarYear, d.MonthName, SUM(f.FareAmount) AS Fare
FROM FactRide f
JOIN SnowZone z ON z.ZoneKey = f.PickupZoneKey
JOIN SnowCity c ON c.CityKey = z.CityKey
JOIN DimRideDate d ON d.DateKey = f.DateKey
GROUP BY c.City, d.CalendarYear, d.MonthName;
GO

