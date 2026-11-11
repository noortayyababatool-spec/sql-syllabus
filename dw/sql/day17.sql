-- Day 17: Identify facts and dimensions from sample data
-- Goal: given raw transactional tables never seen before, say what the fact is, what its grain should be, and which dimensions hang off it.
-- Database: AdventureWorks2022, AdventureWorksDW2022 and AWPractice on SQL Server Express. Run one step at a time in SSMS (select it, press F5).
-- Every step, with its result screenshot and explanation: https://noortayyababatool-spec.github.io/sql-syllabus/day17/

-- ============================================================================
-- Exercise 1: sales, the one you know
-- ============================================================================

-- Step 1. Q1 and Q2: the event and the grain in the OLTP tables
-- Takeaway: Pick the lowest level anyone could ask about. You can always add lines up to orders, but you can never split an order back into its lines.
USE AdventureWorks2022;
SELECT COUNT(*) AS OrderLines, COUNT(DISTINCT h.SalesOrderID) AS Orders, SUM(d.LineTotal) AS Revenue
FROM Sales.SalesOrderDetail d
JOIN Sales.SalesOrderHeader h ON d.SalesOrderID = h.SalesOrderID
WHERE h.OnlineOrderFlag = 1;
GO

-- Step 2. Q3: the measures on a line
-- Takeaway: Quantity and amount are measures. Price and discount percentage describe one line and must be recomputed, not summed.
SELECT MIN(d.OrderQty) AS MinQty, MAX(d.OrderQty) AS MaxQty,
       SUM(CASE WHEN d.UnitPriceDiscount > 0 THEN 1 ELSE 0 END) AS DiscountedLines,
       MIN(d.UnitPrice) AS MinPrice, MAX(d.UnitPrice) AS MaxPrice
FROM Sales.SalesOrderDetail d
JOIN Sales.SalesOrderHeader h ON d.SalesOrderID = h.SalesOrderID
WHERE h.OnlineOrderFlag = 1;
GO

-- Step 3. Q3: header numbers that belong to the whole order
-- Takeaway: A measure recorded at a higher level than the grain is a design decision: allocate it to the lines or keep it in its own fact.
SELECT SalesOrderID, OrderDate, DueDate, ShipDate, CustomerID, TerritoryID,
       SubTotal, TaxAmt, Freight, TotalDue
FROM Sales.SalesOrderHeader
WHERE SalesOrderID = 43697;
GO

-- Step 4. Compare: the dimensions Microsoft attached to FactInternetSales
-- Takeaway: If you were only given six tables, five dimensions is the right answer. Microsoft had more source tables, so it had more dimensions to attach.
USE AdventureWorksDW2022;
SELECT COL_NAME(fkc.parent_object_id, fkc.parent_column_id) AS FactColumn,
       OBJECT_NAME(fk.referenced_object_id) AS Dimension
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
WHERE fk.parent_object_id = OBJECT_ID('dbo.FactInternetSales')
ORDER BY Dimension;
GO

-- Step 5. Compare: same grain, and the header measures were allocated to the lines
-- Takeaway: Microsoft was right to keep the line grain and allocate tax and freight, and the 1.94 gap shows the price: allocated measures can drift by rounding. Always reconcile them.
SELECT COUNT(*) AS FactRows, COUNT(DISTINCT SalesOrderNumber) AS Orders,
       SUM(SalesAmount) AS Revenue, SUM(TaxAmt) AS Tax, SUM(Freight) AS Freight,
       (SELECT SUM(TaxAmt) FROM AdventureWorks2022.Sales.SalesOrderHeader WHERE OnlineOrderFlag = 1) AS OltpTax,
       (SELECT SUM(Freight) FROM AdventureWorks2022.Sales.SalesOrderHeader WHERE OnlineOrderFlag = 1) AS OltpFreight
FROM FactInternetSales;
GO

-- ============================================================================
-- Exercise 2: HR
-- ============================================================================

-- Step 6. SELECT TOP 20 * FROM HumanResources.Employee
-- Takeaway: A table with one row per thing and many descriptive columns is a dimension source.
USE AdventureWorks2022;
SELECT TOP 20 * FROM HumanResources.Employee;
GO

-- Step 7. SELECT TOP 20 * FROM HumanResources.EmployeeDepartmentHistory
-- Takeaway: StartDate and EndDate on a row are the sign of history, and history is where facts hide.
USE AdventureWorks2022;
SELECT TOP 20 * FROM HumanResources.EmployeeDepartmentHistory;
GO

-- Step 8. SELECT TOP 20 * FROM HumanResources.Department
-- Takeaway: Small lookup tables usually become dimension attributes.
USE AdventureWorks2022;
SELECT TOP 20 * FROM HumanResources.Department;
GO

-- Step 9. SELECT TOP 20 * FROM HumanResources.Shift
-- Takeaway: Three rows is too small to need its own table in a star, but it is a dimension either way.
USE AdventureWorks2022;
SELECT TOP 20 * FROM HumanResources.Shift;
GO

-- Step 10. SELECT TOP 20 * FROM HumanResources.EmployeePayHistory
-- Takeaway: This is the pay-change event. Its grain is already visible in the key: one employee on one change date.
USE AdventureWorks2022;
SELECT TOP 20 * FROM HumanResources.EmployeePayHistory;
GO

-- Step 11. The grain of a pay-change fact
-- Takeaway: State the grain as a sentence: "one row per employee per rate change".
SELECT Records AS PayChanges, COUNT(*) AS Employees
FROM (SELECT BusinessEntityID, COUNT(*) AS Records
      FROM HumanResources.EmployeePayHistory GROUP BY BusinessEntityID) x
GROUP BY Records;
GO

-- Step 12. Is Rate additive? No
-- Takeaway: An hourly rate is a price. Like UnitPrice on Day 16, never SUM it.
SELECT BusinessEntityID, COUNT(*) AS PayRecords, SUM(Rate) AS SumOfRates, MAX(Rate) AS LatestRate
FROM HumanResources.EmployeePayHistory
WHERE BusinessEntityID = 4
GROUP BY BusinessEntityID;
GO

-- Step 13. The second fact: department transfers
-- Takeaway: Two events, two facts: pay changes (with a measure) and assignments (factless).
SELECT h.BusinessEntityID, p.FirstName, p.LastName, d.Name AS Department, s.Name AS Shift, h.StartDate, h.EndDate
FROM HumanResources.EmployeeDepartmentHistory h
JOIN Person.Person p ON p.BusinessEntityID = h.BusinessEntityID
JOIN HumanResources.Department d ON d.DepartmentID = h.DepartmentID
JOIN HumanResources.Shift s ON s.ShiftID = h.ShiftID
WHERE h.BusinessEntityID IN (SELECT BusinessEntityID FROM HumanResources.EmployeeDepartmentHistory GROUP BY BusinessEntityID HAVING COUNT(*) > 1)
ORDER BY h.BusinessEntityID, h.StartDate;
GO

-- Step 14. Shift becomes a dimension
-- Takeaway: Anything you would put on a report's rows or a slicer is a dimension, however small.
SELECT s.Name AS Shift, s.StartTime, s.EndTime, COUNT(*) AS CurrentEmployees
FROM HumanResources.EmployeeDepartmentHistory h
JOIN HumanResources.Shift s ON s.ShiftID = h.ShiftID
WHERE h.EndDate IS NULL
GROUP BY s.Name, s.StartTime, s.EndTime
ORDER BY s.StartTime;
GO

-- Step 15. DimEmployee: history rows for the same five people
-- Takeaway: Microsoft put the HR events into the dimension as versions, not into a fact.
USE AdventureWorksDW2022;
SELECT EmployeeKey, FirstName, LastName, DepartmentName, Title, BaseRate, StartDate, EndDate, Status
FROM DimEmployee
WHERE EmployeeNationalIDAlternateKey IN (SELECT EmployeeNationalIDAlternateKey FROM DimEmployee GROUP BY EmployeeNationalIDAlternateKey HAVING COUNT(*) > 1)
ORDER BY LastName, StartDate;
GO

-- Step 16. DimEmployee keeps only the latest pay rate
-- Takeaway: If a question needs history and the warehouse only kept the latest value, the warehouse cannot answer it.
SELECT COUNT(*) AS CurrentRows,
       SUM(CASE WHEN d.BaseRate = lr.Rate THEN 1 ELSE 0 END) AS BaseRateIsLatestRate
FROM DimEmployee d
JOIN AdventureWorks2022.HumanResources.Employee e ON e.NationalIDNumber = d.EmployeeNationalIDAlternateKey
OUTER APPLY (SELECT TOP 1 ph.Rate FROM AdventureWorks2022.HumanResources.EmployeePayHistory ph
             WHERE ph.BusinessEntityID = e.BusinessEntityID ORDER BY ph.RateChangeDate DESC) lr
WHERE d.Status = 'Current';
GO

-- Step 17. No HR fact in the warehouse
-- Takeaway: The warehouse was built for sales analysis. Employees are there as a dimension of sales.
SELECT name AS FactTable FROM sys.tables WHERE name LIKE 'Fact%' ORDER BY name;
GO

-- ============================================================================
-- Exercise 3: a dataset you have never seen
-- ============================================================================

-- Step 18. Create RawRides in AWPractice
-- Takeaway: One flat table, the way rides usually arrive from an app's export.
USE AWPractice;
DROP TABLE IF EXISTS dbo.RawRides;
CREATE TABLE RawRides (
    RideID INT, RiderPhone VARCHAR(20), RiderName VARCHAR(50), RiderCity VARCHAR(50),
    DriverID INT, DriverName VARCHAR(50), VehicleType VARCHAR(20), VehiclePlate VARCHAR(10),
    PickupTime DATETIME, DropoffTime DATETIME, PickupZone VARCHAR(30), DropoffZone VARCHAR(30),
    DistanceKm DECIMAL(6,2), FareAmount DECIMAL(8,2), TipAmount DECIMAL(8,2), PaymentMethod VARCHAR(10),
    Rating TINYINT, PromoCode VARCHAR(10)
);
INSERT INTO RawRides VALUES
(1, '0300-1111111', 'Ayesha', 'Lahore', 501, 'Tariq', 'Mini', 'LEB-1234', '2026-10-01 08:05', '2026-10-01 08:32', 'DHA', 'Gulberg', 9.4, 450, 50, 'Card', 5, NULL),
(2, '0321-2222222', 'Bilal', 'Lahore', 502, 'Nadeem', 'Bike', 'LEC-5678', '2026-10-01 08:10', '2026-10-01 08:25', 'Johar Town', 'Model Town', 5.1, 180, 0, 'Cash', 4, 'OCT10'),
(3, '0300-1111111', 'Ayesha', 'Lahore', 503, 'Faisal', 'Mini', 'LED-9012', '2026-10-01 18:40', '2026-10-01 19:20', 'Gulberg', 'DHA', 10.2, 520, 0, 'Card', 3, NULL),
(4, '0333-3333333', 'Sara', 'Karachi', 601, 'Kamran', 'AC', 'KHI-3456', '2026-10-02 09:00', '2026-10-02 09:45', 'Clifton', 'Saddar', 12.0, 700, 100, 'Wallet', 5, 'OCT10'),
(5, '0321-2222222', 'Bilal', 'Lahore', 502, 'Nadeem', 'Bike', 'LEC-5678', '2026-10-02 08:12', '2026-10-02 08:28', 'Johar Town', 'Model Town', 5.1, 180, 20, 'Cash', 5, NULL);
GO

-- Step 19. Look at the raw data
-- Takeaway: RideID, RiderPhone, DriverID and VehiclePlate are numbers or codes you would never sum: they are identifiers, not measures.
SELECT * FROM RawRides;
GO

-- Step 20. What the raw table repeats
-- Takeaway: Repeated descriptive text in a raw table is a dimension waiting to be pulled out.
SELECT 'Rider' AS Entity, RiderPhone AS Id, RiderName + ', ' + RiderCity AS Description, COUNT(*) AS TimesStored
FROM RawRides GROUP BY RiderPhone, RiderName, RiderCity
UNION ALL
SELECT 'Driver + vehicle', CAST(DriverID AS VARCHAR(10)), DriverName + ', ' + VehicleType + ' ' + VehiclePlate, COUNT(*)
FROM RawRides GROUP BY DriverID, DriverName, VehicleType, VehiclePlate
ORDER BY Entity, TimesStored DESC;
GO

-- Step 21. Build the dimensions
-- Takeaway: Each DISTINCT pulls one entity out of the raw table. The UNIQUE constraint on the natural key stops a second copy creeping in on the next load.
DROP TABLE IF EXISTS dbo.FactRide, dbo.DimRider, dbo.DimDriver, dbo.DimVehicle, dbo.DimZone, dbo.DimRideDate, dbo.DimPayment;
CREATE TABLE DimRider (RiderKey INT IDENTITY PRIMARY KEY, RiderPhone VARCHAR(20) NOT NULL UNIQUE, RiderName VARCHAR(50), RiderCity VARCHAR(50));
CREATE TABLE DimDriver (DriverKey INT IDENTITY PRIMARY KEY, DriverID INT NOT NULL UNIQUE, DriverName VARCHAR(50));
CREATE TABLE DimVehicle (VehicleKey INT IDENTITY PRIMARY KEY, VehiclePlate VARCHAR(10) NOT NULL UNIQUE, VehicleType VARCHAR(20));
CREATE TABLE DimZone (ZoneKey INT IDENTITY PRIMARY KEY, ZoneName VARCHAR(30) NOT NULL, City VARCHAR(50), CONSTRAINT UQ_Zone UNIQUE (ZoneName, City));
CREATE TABLE DimRideDate (DateKey INT PRIMARY KEY, FullDate DATE, DayName VARCHAR(10), MonthName VARCHAR(10), CalendarYear INT);
CREATE TABLE DimPayment (PaymentKey INT IDENTITY PRIMARY KEY, PaymentMethod VARCHAR(10), PromoCode VARCHAR(10), HasPromo BIT);
INSERT INTO DimRider (RiderPhone, RiderName, RiderCity) SELECT DISTINCT RiderPhone, RiderName, RiderCity FROM RawRides;
INSERT INTO DimDriver (DriverID, DriverName) SELECT DISTINCT DriverID, DriverName FROM RawRides;
INSERT INTO DimVehicle (VehiclePlate, VehicleType) SELECT DISTINCT VehiclePlate, VehicleType FROM RawRides;
INSERT INTO DimZone (ZoneName, City) SELECT PickupZone, RiderCity FROM RawRides UNION SELECT DropoffZone, RiderCity FROM RawRides;
INSERT INTO DimRideDate SELECT DISTINCT CONVERT(INT, FORMAT(PickupTime, 'yyyyMMdd')), CAST(PickupTime AS DATE),
       DATENAME(weekday, PickupTime), DATENAME(month, PickupTime), YEAR(PickupTime) FROM RawRides;
INSERT INTO DimPayment (PaymentMethod, PromoCode, HasPromo)
SELECT DISTINCT PaymentMethod, PromoCode, CASE WHEN PromoCode IS NULL THEN 0 ELSE 1 END FROM RawRides;
GO

-- Step 22. Build and load the fact
-- Takeaway: If the fact row count after the load differs from the raw row count, a dimension lookup failed. Five in, five out.
DROP TABLE IF EXISTS dbo.FactRide;
CREATE TABLE FactRide (
    RideID INT PRIMARY KEY,
    DateKey INT REFERENCES DimRideDate(DateKey), PickupHour TINYINT,
    RiderKey INT REFERENCES DimRider(RiderKey), DriverKey INT REFERENCES DimDriver(DriverKey),
    VehicleKey INT REFERENCES DimVehicle(VehicleKey),
    PickupZoneKey INT REFERENCES DimZone(ZoneKey), DropoffZoneKey INT REFERENCES DimZone(ZoneKey),
    PaymentKey INT REFERENCES DimPayment(PaymentKey),
    PickupTime DATETIME, DropoffTime DATETIME,
    DistanceKm DECIMAL(6,2), DurationMin INT, FareAmount DECIMAL(8,2), TipAmount DECIMAL(8,2), Rating TINYINT
);
INSERT INTO FactRide
SELECT r.RideID, CONVERT(INT, FORMAT(r.PickupTime, 'yyyyMMdd')), DATEPART(hour, r.PickupTime),
       dr.RiderKey, dd.DriverKey, v.VehicleKey, pz.ZoneKey, dz.ZoneKey, pm.PaymentKey,
       r.PickupTime, r.DropoffTime, r.DistanceKm, DATEDIFF(minute, r.PickupTime, r.DropoffTime),
       r.FareAmount, r.TipAmount, r.Rating
FROM RawRides r
JOIN DimRider dr ON dr.RiderPhone = r.RiderPhone
JOIN DimDriver dd ON dd.DriverID = r.DriverID
JOIN DimVehicle v ON v.VehiclePlate = r.VehiclePlate
JOIN DimZone pz ON pz.ZoneName = r.PickupZone AND pz.City = r.RiderCity
JOIN DimZone dz ON dz.ZoneName = r.DropoffZone AND dz.City = r.RiderCity
JOIN DimPayment pm ON pm.PaymentMethod = r.PaymentMethod AND ISNULL(pm.PromoCode, '') = ISNULL(r.PromoCode, '');
GO

-- Step 23. The fact table
-- Takeaway: A fact row is narrow: keys plus measures.
SELECT * FROM FactRide;
GO

-- ============================================================================
-- Self-test: does the model answer the questions?
-- ============================================================================

-- Step 24. Rides per zone per day
-- Takeaway: No join to RawRides needed.
SELECT d.FullDate, z.ZoneName AS PickupZone, COUNT(*) AS Rides
FROM FactRide f
JOIN DimRideDate d ON d.DateKey = f.DateKey
JOIN DimZone z ON z.ZoneKey = f.PickupZoneKey
GROUP BY d.FullDate, z.ZoneName
ORDER BY d.FullDate, z.ZoneName;
GO

-- Step 25. Average tip by payment method
-- Takeaway: Group by a dimension attribute, aggregate a measure: the pattern for every report.
SELECT p.PaymentMethod, COUNT(*) AS Rides, AVG(f.TipAmount) AS AvgTip
FROM FactRide f
JOIN DimPayment p ON p.PaymentKey = f.PaymentKey
GROUP BY p.PaymentMethod
ORDER BY AvgTip DESC;
GO

-- Step 26. Top drivers by fare
-- Takeaway: Group by the key's attribute (name) only when names are unique; with real data group by DriverKey and show the name.
SELECT d.DriverName, COUNT(*) AS Rides, SUM(f.FareAmount) AS Fare
FROM FactRide f
JOIN DimDriver d ON d.DriverKey = f.DriverKey
GROUP BY d.DriverName
ORDER BY Fare DESC;
GO

-- Step 27. Repeat riders
-- Takeaway: All four self-test questions run on the star alone: the model is complete for them.
SELECT r.RiderName, r.RiderPhone, COUNT(*) AS Rides
FROM FactRide f
JOIN DimRider r ON r.RiderKey = f.RiderKey
GROUP BY r.RiderName, r.RiderPhone
HAVING COUNT(*) > 1;
GO

-- Step 28. Additivity check: Rating and DistanceKm
-- Takeaway: Rating: average it. DistanceKm, FareAmount, TipAmount, DurationMin: sum them.
SELECT SUM(Rating) AS SumOfRatings, AVG(CAST(Rating AS DECIMAL(4,2))) AS AvgRating,
       SUM(DistanceKm) AS TotalKm, SUM(FareAmount) / SUM(DistanceKm) AS FarePerKm
FROM FactRide;
GO

