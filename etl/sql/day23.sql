-- Day 23: Transform: cleaning and standardising
-- Run in order on AWPractice after day22.sql.
-- https://noortayyababatool-spec.github.io/sql-syllabus/day23/

-- ==== Reference data the rules need ====

-- 1. Three more small full extracts: stores, subcategories, categories
USE AWPractice;
DECLARE @t0 DATETIME2(3) = SYSDATETIME(), @n INT;
DROP TABLE IF EXISTS stg.Store, stg.ProductSubcategory, stg.ProductCategory;
SELECT s.BusinessEntityID AS StoreID, s.Name AS StoreName, a.City, sp.CountryRegionCode, SYSDATETIME() AS ExtractedAt
INTO stg.Store
FROM AdventureWorks2022.Sales.Store s
LEFT JOIN AdventureWorks2022.Person.BusinessEntityAddress bea
       ON bea.BusinessEntityID = s.BusinessEntityID AND bea.AddressTypeID = 3     -- 3 = Main Office
LEFT JOIN AdventureWorks2022.Person.Address a        ON a.AddressID = bea.AddressID
LEFT JOIN AdventureWorks2022.Person.StateProvince sp ON sp.StateProvinceID = a.StateProvinceID;
SET @n = @@ROWCOUNT; INSERT INTO etl.LoadLog VALUES ('Extract full', 'stg.Store', @n, @t0, SYSDATETIME());
SELECT ProductSubcategoryID, ProductCategoryID, Name INTO stg.ProductSubcategory FROM AdventureWorks2022.Production.ProductSubcategory;
SET @n = @@ROWCOUNT; INSERT INTO etl.LoadLog VALUES ('Extract full', 'stg.ProductSubcategory', @n, @t0, SYSDATETIME());
SELECT ProductCategoryID, Name INTO stg.ProductCategory FROM AdventureWorks2022.Production.ProductCategory;
SET @n = @@ROWCOUNT; INSERT INTO etl.LoadLog VALUES ('Extract full', 'stg.ProductCategory', @n, @t0, SYSDATETIME());
SELECT LogID, Step, TableName, RowsAffected FROM etl.LoadLog WHERE LogID > 6;
GO

-- ==== Transform rules on the real data, written as views ====

-- 2. The customer rules: type, name, city and country with no NULLs
CREATE OR ALTER VIEW etl.vCustomer AS
SELECT c.CustomerID,
       CASE WHEN c.PersonID IS NULL THEN 'Store'
            WHEN c.StoreID  IS NULL THEN 'Individual'
            ELSE 'Store contact' END                                   AS CustomerType,
       COALESCE(c.FirstName + ' ' + c.LastName, s.StoreName)          AS CustomerName,
       ISNULL(s.StoreName, 'No store')                                 AS StoreName,
       COALESCE(c.City, s.City, 'Unknown')                             AS City,
       CASE COALESCE(c.CountryRegionCode, s.CountryRegionCode)
            WHEN 'US' THEN 'United States' WHEN 'CA' THEN 'Canada'  WHEN 'GB' THEN 'United Kingdom'
            WHEN 'FR' THEN 'France'        WHEN 'DE' THEN 'Germany' WHEN 'AU' THEN 'Australia'
            ELSE 'Unknown' END                                         AS Country,
       c.ModifiedDate
FROM stg.Customer c
LEFT JOIN stg.Store s ON s.StoreID = c.StoreID;
GO
SELECT TOP 6 * FROM etl.vCustomer ORDER BY CustomerID;
GO

-- 3. Did the rules close the gaps found on Day 22?
SELECT CustomerType, COUNT(*) AS Customers,
       SUM(CASE WHEN CustomerName IS NULL THEN 1 ELSE 0 END) AS NoName,
       SUM(CASE WHEN City = 'Unknown' THEN 1 ELSE 0 END)     AS UnknownCity,
       SUM(CASE WHEN Country = 'Unknown' THEN 1 ELSE 0 END)  AS UnknownCountry
FROM etl.vCustomer GROUP BY CustomerType;
GO

-- 4. The product rules: no NULL colour, category names, a price band
CREATE OR ALTER VIEW etl.vProduct AS
SELECT p.ProductID, p.ProductNumber, p.Name AS ProductName,
       ISNULL(p.Color, 'No colour')        AS Colour,
       ISNULL(sc.Name, 'Not for sale')     AS Subcategory,
       ISNULL(cat.Name, 'Not for sale')    AS Category,
       p.StandardCost, p.ListPrice,
       CASE WHEN p.ListPrice = 0    THEN 'No list price'
            WHEN p.ListPrice < 50   THEN 'Under 50'
            WHEN p.ListPrice < 500  THEN '50 to 499'
            WHEN p.ListPrice < 1500 THEN '500 to 1,499'
            ELSE '1,500 and over' END     AS PriceBand,
       p.ModifiedDate
FROM stg.Product p
LEFT JOIN stg.ProductSubcategory sc ON sc.ProductSubcategoryID = p.ProductSubcategoryID
LEFT JOIN stg.ProductCategory cat   ON cat.ProductCategoryID   = sc.ProductCategoryID;
GO
SELECT Category, PriceBand, COUNT(*) AS Products FROM etl.vProduct GROUP BY Category, PriceBand ORDER BY Category, MIN(ListPrice);
GO

-- 5. The sales-line rules: one row per order line, ready for the fact
CREATE OR ALTER VIEW etl.vSalesLine AS
SELECT d.SalesOrderID, d.SalesOrderDetailID,
       YEAR(h.OrderDate) * 10000 + MONTH(h.OrderDate) * 100 + DAY(h.OrderDate) AS OrderDateKey,   -- yyyymmdd
       h.CustomerID, d.ProductID, h.TerritoryID,
       CASE h.OnlineOrderFlag WHEN 1 THEN 'Online' ELSE 'Reseller' END        AS SalesChannel,
       h.SalesPersonID,                                                        -- NULL = online, mapped on Day 24
       d.OrderQty AS Quantity, d.UnitPrice, d.UnitPriceDiscount,
       CAST(d.LineTotal AS DECIMAL(19, 4))                                     AS SalesAmount
FROM stg.SalesOrderDetail d
JOIN stg.SalesOrderHeader h ON h.SalesOrderID = d.SalesOrderID;
GO
SELECT SalesChannel, COUNT(*) AS Lines, COUNT(DISTINCT SalesOrderID) AS Orders, SUM(SalesAmount) AS Revenue
FROM etl.vSalesLine GROUP BY SalesChannel;
GO

-- 6. Building a date key: FORMAT is easy to read and slow
DECLARE @t DATETIME2(3), @k INT, @a INT, @b INT;
SET @t = SYSDATETIME();
SELECT @k = MAX(CONVERT(INT, FORMAT(h.OrderDate, 'yyyyMMdd')))
FROM stg.SalesOrderDetail d JOIN stg.SalesOrderHeader h ON h.SalesOrderID = d.SalesOrderID;
SET @a = DATEDIFF(millisecond, @t, SYSDATETIME());
SET @t = SYSDATETIME();
SELECT @k = MAX(YEAR(h.OrderDate) * 10000 + MONTH(h.OrderDate) * 100 + DAY(h.OrderDate))
FROM stg.SalesOrderDetail d JOIN stg.SalesOrderHeader h ON h.SalesOrderID = d.SalesOrderID;
SET @b = DATEDIFF(millisecond, @t, SYSDATETIME());
SELECT @a AS FormatMs, @b AS ArithmeticMs, @k AS LastDateKey;
GO

-- ==== A messy source: web sign-ups loaded from a CSV ====

-- 7. The raw file, loaded as text: every column is NVARCHAR
DROP TABLE IF EXISTS stg.WebSignupRaw;
CREATE TABLE stg.WebSignupRaw (
    SignupID NVARCHAR(10), FullName NVARCHAR(100), Email NVARCHAR(100), Phone NVARCHAR(30),
    City NVARCHAR(50), SignupDate NVARCHAR(30), FirstOrderAmount NVARCHAR(30));
INSERT INTO stg.WebSignupRaw VALUES
 ('1', '  ayesha KHAN ', 'Ayesha.Khan@Gmail.com ', '0300-1111111',    'lahore',      '2026-11-02', '1,200'),
 ('2', 'Bilal Ahmed',    'bilal.ahmed@yahoo.com',  '+92 301 2222222', 'LHR',         '02/11/2026', 'Rs 850'),
 ('3', 'sara malik',     'SARA.MALIK@HOTMAIL.COM', '03213333333',     ' Islamabad',  '3 Nov 2026', '500'),
 ('4', 'Usman Tariq',    'usman.tariq@gmail',      '0333-444444',     'Karachi',     '2026-11-03', '2000'),
 ('5', 'Hina Raza',      '',                       '0345 5555555',    'Lahor',       '2026-11-04', ''),
 ('6', 'AYESHA KHAN',    'ayesha.khan@gmail.com',  '03001111111',     'Lahore',      '2026-11-05', '950'),
 ('7', 'Zain Ali',       'zain.ali@outlook.com',   '0312-6666666',    'NULL',        '2026-13-45', 'abc'),
 ('8', 'Fatima Noor',    'fatima noor@gmail.com',  '0300 7777777',    'islamabad',   '05/11/2026', '1,500.50'),
 ('9', 'Omar Farooq',    'omar.farooq@gmail.com',  '+923008888888',   'Rawalpindi',  '6 Nov 2026', ' 300 '),
 ('10','Sana Iqbal',     'sana.iqbal@gmail.com',   '0300-9999999',    'RWP',         '2026-11-06', '0'),
 ('11','bilal ahmed',    'Bilal.Ahmed@Yahoo.com',  '0301-2222222',    'Lahore',      '2026-11-07', '400'),
 ('12','Maryam Shah',    'maryam.shah@gmail.com',  '0322-1212121',    'Karachi ',    '07-11-2026', '650');
SELECT * FROM stg.WebSignupRaw;
GO

-- 8. Profile the mess
SELECT COUNT(*) AS Rows,
       COUNT(DISTINCT LOWER(TRIM(Email))) AS DistinctEmails,
       SUM(CASE WHEN TRIM(Email) = '' THEN 1 ELSE 0 END) AS BlankEmails,
       COUNT(DISTINCT City) AS CitySpellings,
       SUM(CASE WHEN TRY_CONVERT(DATE, SignupDate, 23) IS NULL THEN 1 ELSE 0 END) AS NotIsoDates,
       SUM(CASE WHEN TRY_CAST(FirstOrderAmount AS DECIMAL(10,2)) IS NULL THEN 1 ELSE 0 END) AS NotNumbers
FROM stg.WebSignupRaw;
GO

-- 9. Convert the dates the strict way: CONVERT stops at the first bad value
SELECT SignupID, SignupDate, CONVERT(DATE, SignupDate, 23) AS AsDate FROM stg.WebSignupRaw;
GO

-- 10. TRY_CONVERT, one format at a time
SELECT SignupID, SignupDate,
       TRY_CONVERT(DATE, SignupDate, 23)  AS Iso_yyyy_mm_dd,
       TRY_CONVERT(DATE, SignupDate, 103) AS British_dd_mm_yyyy,
       TRY_CONVERT(DATE, SignupDate, 105) AS Italian_dd_mm_yyyy,
       TRY_CONVERT(DATE, SignupDate, 106) AS dd_mon_yyyy,
       COALESCE(TRY_CONVERT(DATE, SignupDate, 23),  TRY_CONVERT(DATE, SignupDate, 103),
                TRY_CONVERT(DATE, SignupDate, 105), TRY_CONVERT(DATE, SignupDate, 106)) AS CleanDate
FROM stg.WebSignupRaw;
GO

-- 11. Names: trim, collapse spaces, capitalise each word
SELECT SignupID, FullName AS Raw,
       UPPER(LEFT(f.First, 1)) + LOWER(SUBSTRING(f.First, 2, 50)) + ' ' +
       UPPER(LEFT(f.Last, 1))  + LOWER(SUBSTRING(f.Last, 2, 50))  AS CleanName
FROM stg.WebSignupRaw
CROSS APPLY (SELECT LTRIM(RTRIM(REPLACE(FullName, '  ', ' '))) AS n) t
CROSS APPLY (SELECT LEFT(t.n, CHARINDEX(' ', t.n + ' ') - 1) AS First,
                    LTRIM(SUBSTRING(t.n, CHARINDEX(' ', t.n + ' ') + 1, 50)) AS Last) f;
GO

-- 12. Emails: lower case, no spaces, and a basic validity test
SELECT SignupID, Email AS Raw, e.Clean,
       CASE WHEN e.Clean = '' THEN 'Blank'
            WHEN e.Clean LIKE '% %' THEN 'Contains a space'
            WHEN e.Clean NOT LIKE '_%@_%._%' THEN 'No domain ending'
            ELSE 'OK' END AS EmailCheck
FROM stg.WebSignupRaw
CROSS APPLY (SELECT LOWER(TRIM(Email)) AS Clean) e;
GO

-- 13. Phones: keep the digits, turn +92 into 0, check the length, format one way
SELECT SignupID, Phone AS Raw, d.Digits,
       CASE WHEN LEN(d.Digits) = 11 AND LEFT(d.Digits, 2) = '03'
            THEN LEFT(d.Digits, 4) + '-' + RIGHT(d.Digits, 7) END AS CleanPhone
FROM stg.WebSignupRaw
CROSS APPLY (SELECT REPLACE(REPLACE(REPLACE(REPLACE(Phone, '+', ''), '-', ''), ' ', ''), '(', '') AS s) x
CROSS APPLY (SELECT CASE WHEN LEFT(x.s, 2) = '92' AND LEN(x.s) = 12 THEN '0' + SUBSTRING(x.s, 3, 10) ELSE x.s END AS Digits) d;
GO

-- 14. Cities: a mapping table for known spellings
DROP TABLE IF EXISTS etl.CityMap;
CREATE TABLE etl.CityMap (Variant NVARCHAR(50) PRIMARY KEY, City NVARCHAR(50) NOT NULL);
INSERT INTO etl.CityMap VALUES
 ('lahore', 'Lahore'), ('lhr', 'Lahore'), ('lahor', 'Lahore'),
 ('islamabad', 'Islamabad'), ('isb', 'Islamabad'),
 ('karachi', 'Karachi'), ('khi', 'Karachi'),
 ('rawalpindi', 'Rawalpindi'), ('rwp', 'Rawalpindi');
SELECT r.SignupID, r.City AS Raw, ISNULL(m.City, 'Unknown') AS CleanCity
FROM stg.WebSignupRaw r
LEFT JOIN etl.CityMap m ON m.Variant = LOWER(TRIM(r.City));
GO

-- 15. Amounts: strip commas and "Rs", then TRY_CAST
SELECT SignupID, FirstOrderAmount AS Raw,
       TRY_CAST(TRIM(REPLACE(REPLACE(FirstOrderAmount, ',', ''), 'Rs', '')) AS DECIMAL(10, 2)) AS CleanAmount,
       CASE WHEN NULLIF(TRIM(FirstOrderAmount), '') IS NULL THEN 'Blank'
            WHEN TRY_CAST(TRIM(REPLACE(REPLACE(FirstOrderAmount, ',', ''), 'Rs', '')) AS DECIMAL(10, 2)) IS NULL THEN 'Not a number'
            ELSE 'OK' END AS AmountCheck
FROM stg.WebSignupRaw;
GO

-- ==== Put the rules together: clean, reject, de-duplicate ====

-- 16. Rejects go to their own table, with the reason
DROP TABLE IF EXISTS stg.WebSignupReject;
WITH Cleaned AS (
    SELECT CAST(r.SignupID AS INT) AS SignupID,
           UPPER(LEFT(f.First, 1)) + LOWER(SUBSTRING(f.First, 2, 50)) + ' ' +
           UPPER(LEFT(f.Last, 1))  + LOWER(SUBSTRING(f.Last, 2, 50))  AS FullName,
           LOWER(TRIM(r.Email)) AS Email,
           CASE WHEN LEN(d.Digits) = 11 AND LEFT(d.Digits, 2) = '03' THEN LEFT(d.Digits, 4) + '-' + RIGHT(d.Digits, 7) END AS Phone,
           ISNULL(m.City, 'Unknown') AS City,
           COALESCE(TRY_CONVERT(DATE, r.SignupDate, 23),  TRY_CONVERT(DATE, r.SignupDate, 103),
                    TRY_CONVERT(DATE, r.SignupDate, 105), TRY_CONVERT(DATE, r.SignupDate, 106)) AS SignupDate,
           TRY_CAST(TRIM(REPLACE(REPLACE(r.FirstOrderAmount, ',', ''), 'Rs', '')) AS DECIMAL(10, 2)) AS FirstOrderAmount
    FROM stg.WebSignupRaw r
    CROSS APPLY (SELECT LTRIM(RTRIM(REPLACE(r.FullName, '  ', ' '))) AS n) t
    CROSS APPLY (SELECT LEFT(t.n, CHARINDEX(' ', t.n + ' ') - 1) AS First, LTRIM(SUBSTRING(t.n, CHARINDEX(' ', t.n + ' ') + 1, 50)) AS Last) f
    CROSS APPLY (SELECT REPLACE(REPLACE(REPLACE(r.Phone, '+', ''), '-', ''), ' ', '') AS s) x
    CROSS APPLY (SELECT CASE WHEN LEFT(x.s, 2) = '92' AND LEN(x.s) = 12 THEN '0' + SUBSTRING(x.s, 3, 10) ELSE x.s END AS Digits) d
    LEFT JOIN etl.CityMap m ON m.Variant = LOWER(TRIM(r.City))
), Checked AS (
    SELECT *, CASE WHEN Email = '' THEN 'Blank email'
                   WHEN Email LIKE '% %' OR Email NOT LIKE '_%@_%._%' THEN 'Invalid email'
                   WHEN Phone IS NULL THEN 'Invalid phone' END AS RejectReason
    FROM Cleaned
)
SELECT r.*, c.RejectReason, SYSDATETIME() AS RejectedAt
INTO stg.WebSignupReject
FROM Checked c JOIN stg.WebSignupRaw r ON CAST(r.SignupID AS INT) = c.SignupID
WHERE c.RejectReason IS NOT NULL;
SELECT SignupID, FullName, Email, Phone, RejectReason FROM stg.WebSignupReject;
GO

-- 17. The clean table: valid rows only, one row per email, newest sign-up wins
DROP TABLE IF EXISTS stg.WebSignupClean;
WITH Cleaned AS (
    SELECT CAST(r.SignupID AS INT) AS SignupID,
           UPPER(LEFT(f.First, 1)) + LOWER(SUBSTRING(f.First, 2, 50)) + ' ' +
           UPPER(LEFT(f.Last, 1))  + LOWER(SUBSTRING(f.Last, 2, 50))  AS FullName,
           LOWER(TRIM(r.Email)) AS Email,
           CASE WHEN LEN(d.Digits) = 11 AND LEFT(d.Digits, 2) = '03' THEN LEFT(d.Digits, 4) + '-' + RIGHT(d.Digits, 7) END AS Phone,
           ISNULL(m.City, 'Unknown') AS City,
           COALESCE(TRY_CONVERT(DATE, r.SignupDate, 23),  TRY_CONVERT(DATE, r.SignupDate, 103),
                    TRY_CONVERT(DATE, r.SignupDate, 105), TRY_CONVERT(DATE, r.SignupDate, 106)) AS SignupDate,
           TRY_CAST(TRIM(REPLACE(REPLACE(r.FirstOrderAmount, ',', ''), 'Rs', '')) AS DECIMAL(10, 2)) AS FirstOrderAmount
    FROM stg.WebSignupRaw r
    CROSS APPLY (SELECT LTRIM(RTRIM(REPLACE(r.FullName, '  ', ' '))) AS n) t
    CROSS APPLY (SELECT LEFT(t.n, CHARINDEX(' ', t.n + ' ') - 1) AS First, LTRIM(SUBSTRING(t.n, CHARINDEX(' ', t.n + ' ') + 1, 50)) AS Last) f
    CROSS APPLY (SELECT REPLACE(REPLACE(REPLACE(r.Phone, '+', ''), '-', ''), ' ', '') AS s) x
    CROSS APPLY (SELECT CASE WHEN LEFT(x.s, 2) = '92' AND LEN(x.s) = 12 THEN '0' + SUBSTRING(x.s, 3, 10) ELSE x.s END AS Digits) d
    LEFT JOIN etl.CityMap m ON m.Variant = LOWER(TRIM(r.City))
), Checked AS (
    SELECT *, CASE WHEN Email = '' THEN 'Blank email'
                   WHEN Email LIKE '% %' OR Email NOT LIKE '_%@_%._%' THEN 'Invalid email'
                   WHEN Phone IS NULL THEN 'Invalid phone' END AS RejectReason
    FROM Cleaned
), Ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY Email ORDER BY SignupDate DESC, SignupID DESC) AS rn
    FROM Checked WHERE RejectReason IS NULL
)
SELECT SignupID, FullName, Email, Phone, City, SignupDate, FirstOrderAmount
INTO stg.WebSignupClean FROM Ranked WHERE rn = 1;
SELECT * FROM stg.WebSignupClean ORDER BY SignupID;
GO

-- 18. Account for every raw row
SELECT (SELECT COUNT(*) FROM stg.WebSignupRaw)    AS RawRows,
       (SELECT COUNT(*) FROM stg.WebSignupClean)  AS CleanRows,
       (SELECT COUNT(*) FROM stg.WebSignupReject) AS RejectedRows,
       (SELECT COUNT(*) FROM stg.WebSignupRaw) - (SELECT COUNT(*) FROM stg.WebSignupClean)
         - (SELECT COUNT(*) FROM stg.WebSignupReject) AS DuplicatesRemoved;
GO

-- 19. What still needs a person: NULLs left by the rules
SELECT SignupID, FullName, City, SignupDate, FirstOrderAmount,
       CONCAT_WS(', ', CASE WHEN City = 'Unknown' THEN 'city not recognised' END,
                       CASE WHEN SignupDate IS NULL THEN 'date not recognised' END,
                       CASE WHEN FirstOrderAmount IS NULL THEN 'amount missing or not a number' END) AS Warnings
FROM stg.WebSignupClean
WHERE City = 'Unknown' OR SignupDate IS NULL OR FirstOrderAmount IS NULL;
GO
