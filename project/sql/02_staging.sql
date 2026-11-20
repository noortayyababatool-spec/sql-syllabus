-- =====================================================================================
-- AWSupplyDW 02_staging.sql: staging tables and the extract procedure
-- Staging holds plain copies of the source columns the warehouse needs, with no keys
-- and no rules. Every run empties and refills it (a full extract): the whole source is
-- about 300,000 rows and copies in a few seconds, so a watermark (Day 22) would add
-- complexity without saving time.
-- =====================================================================================
USE AWSupplyDW;
GO
CREATE TABLE stg.PurchaseOrderHeader (
    PurchaseOrderID INT, Status TINYINT, EmployeeID INT, VendorID INT, ShipMethodID INT,
    OrderDate DATETIME, ShipDate DATETIME, SubTotal MONEY, TaxAmt MONEY, Freight MONEY);
CREATE TABLE stg.PurchaseOrderDetail (
    PurchaseOrderID INT, PurchaseOrderDetailID INT, DueDate DATETIME, OrderQty SMALLINT, ProductID INT,
    UnitPrice MONEY, LineTotal MONEY, ReceivedQty DECIMAL(8, 2), RejectedQty DECIMAL(8, 2), StockedQty DECIMAL(9, 2));
CREATE TABLE stg.Vendor (
    VendorID INT, AccountNumber NVARCHAR(15), VendorName NVARCHAR(50), CreditRating TINYINT,
    PreferredVendorStatus BIT, ActiveFlag BIT, City NVARCHAR(30), StateProvince NVARCHAR(50), Country NVARCHAR(50));
CREATE TABLE stg.ShipMethod (ShipMethodID INT, ShipMethod NVARCHAR(50), ShipBase MONEY, ShipRate MONEY);
CREATE TABLE stg.Employee (
    EmployeeID INT, EmployeeName NVARCHAR(101), JobTitle NVARCHAR(50), Department NVARCHAR(50), HireDate DATE);
CREATE TABLE stg.Product (
    ProductID INT, ProductName NVARCHAR(50), ProductNumber NVARCHAR(25), MakeFlag BIT, FinishedGoodsFlag BIT,
    Color NVARCHAR(15), Size NVARCHAR(5), ProductLine NCHAR(2), Class NCHAR(2), Subcategory NVARCHAR(50),
    Category NVARCHAR(50), StandardCost MONEY, ListPrice MONEY, SafetyStockLevel SMALLINT, ReorderPoint SMALLINT,
    SellStartDate DATETIME, SellEndDate DATETIME, DiscontinuedDate DATETIME);
CREATE TABLE stg.ProductCostHistory (ProductID INT, StartDate DATETIME, EndDate DATETIME, StandardCost MONEY);
CREATE TABLE stg.ProductListPriceHistory (ProductID INT, StartDate DATETIME, EndDate DATETIME, ListPrice MONEY);
CREATE TABLE stg.WorkOrder (
    WorkOrderID INT, ProductID INT, OrderQty INT, StockedQty INT, ScrappedQty SMALLINT,
    StartDate DATETIME, EndDate DATETIME, DueDate DATETIME, ScrapReasonID SMALLINT);
CREATE TABLE stg.WorkOrderRouting (
    WorkOrderID INT, ProductID INT, OperationSequence SMALLINT, LocationID SMALLINT,
    ScheduledStartDate DATETIME, ScheduledEndDate DATETIME, ActualStartDate DATETIME, ActualEndDate DATETIME,
    ActualResourceHrs DECIMAL(9, 4), PlannedCost MONEY, ActualCost MONEY);
CREATE TABLE stg.Location (LocationID SMALLINT, LocationName NVARCHAR(50), CostRate SMALLMONEY, Availability DECIMAL(8, 2));
CREATE TABLE stg.ScrapReason (ScrapReasonID SMALLINT, ScrapReason NVARCHAR(50));
CREATE TABLE stg.ProductInventory (ProductID INT, LocationID SMALLINT, Shelf NVARCHAR(10), Bin TINYINT, Quantity SMALLINT, ModifiedDate DATETIME);
GO

CREATE OR ALTER PROCEDURE etl.usp_Extract @RunID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @log INT, @rows INT = 0;
    EXEC etl.usp_StepStart @RunID, 'Extract: source to staging', @log OUTPUT;

    TRUNCATE TABLE stg.PurchaseOrderHeader;
    INSERT INTO stg.PurchaseOrderHeader
    SELECT PurchaseOrderID, Status, EmployeeID, VendorID, ShipMethodID, OrderDate, ShipDate, SubTotal, TaxAmt, Freight
    FROM AdventureWorks2022.Purchasing.PurchaseOrderHeader;
    SET @rows += @@ROWCOUNT;

    TRUNCATE TABLE stg.PurchaseOrderDetail;
    INSERT INTO stg.PurchaseOrderDetail
    SELECT PurchaseOrderID, PurchaseOrderDetailID, DueDate, OrderQty, ProductID,
           UnitPrice, LineTotal, ReceivedQty, RejectedQty, StockedQty
    FROM AdventureWorks2022.Purchasing.PurchaseOrderDetail;
    SET @rows += @@ROWCOUNT;

    TRUNCATE TABLE stg.Vendor;                    -- every vendor has exactly one address, its Main Office
    INSERT INTO stg.Vendor
    SELECT v.BusinessEntityID, v.AccountNumber, v.Name, v.CreditRating, v.PreferredVendorStatus, v.ActiveFlag,
           a.City, sp.Name, cr.Name
    FROM AdventureWorks2022.Purchasing.Vendor v
    LEFT JOIN AdventureWorks2022.Person.BusinessEntityAddress bea ON bea.BusinessEntityID = v.BusinessEntityID
    LEFT JOIN AdventureWorks2022.Person.Address a                 ON a.AddressID = bea.AddressID
    LEFT JOIN AdventureWorks2022.Person.StateProvince sp          ON sp.StateProvinceID = a.StateProvinceID
    LEFT JOIN AdventureWorks2022.Person.CountryRegion cr          ON cr.CountryRegionCode = sp.CountryRegionCode;
    SET @rows += @@ROWCOUNT;

    TRUNCATE TABLE stg.ShipMethod;
    INSERT INTO stg.ShipMethod
    SELECT ShipMethodID, Name, ShipBase, ShipRate FROM AdventureWorks2022.Purchasing.ShipMethod;
    SET @rows += @@ROWCOUNT;

    TRUNCATE TABLE stg.Employee;                  -- current department only (EndDate IS NULL)
    INSERT INTO stg.Employee
    SELECT e.BusinessEntityID, p.FirstName + ' ' + p.LastName, e.JobTitle, d.Name, e.HireDate
    FROM AdventureWorks2022.HumanResources.Employee e
    JOIN AdventureWorks2022.Person.Person p ON p.BusinessEntityID = e.BusinessEntityID
    LEFT JOIN AdventureWorks2022.HumanResources.EmployeeDepartmentHistory h
           ON h.BusinessEntityID = e.BusinessEntityID AND h.EndDate IS NULL
    LEFT JOIN AdventureWorks2022.HumanResources.Department d ON d.DepartmentID = h.DepartmentID;
    SET @rows += @@ROWCOUNT;

    TRUNCATE TABLE stg.Product;
    INSERT INTO stg.Product
    SELECT p.ProductID, p.Name, p.ProductNumber, p.MakeFlag, p.FinishedGoodsFlag, p.Color, p.Size,
           p.ProductLine, p.Class, s.Name, c.Name, p.StandardCost, p.ListPrice, p.SafetyStockLevel,
           p.ReorderPoint, p.SellStartDate, p.SellEndDate, p.DiscontinuedDate
    FROM AdventureWorks2022.Production.Product p
    LEFT JOIN AdventureWorks2022.Production.ProductSubcategory s ON s.ProductSubcategoryID = p.ProductSubcategoryID
    LEFT JOIN AdventureWorks2022.Production.ProductCategory c    ON c.ProductCategoryID = s.ProductCategoryID;
    SET @rows += @@ROWCOUNT;

    TRUNCATE TABLE stg.ProductCostHistory;
    INSERT INTO stg.ProductCostHistory
    SELECT ProductID, StartDate, EndDate, StandardCost FROM AdventureWorks2022.Production.ProductCostHistory;
    SET @rows += @@ROWCOUNT;

    TRUNCATE TABLE stg.ProductListPriceHistory;
    INSERT INTO stg.ProductListPriceHistory
    SELECT ProductID, StartDate, EndDate, ListPrice FROM AdventureWorks2022.Production.ProductListPriceHistory;
    SET @rows += @@ROWCOUNT;

    TRUNCATE TABLE stg.WorkOrder;
    INSERT INTO stg.WorkOrder
    SELECT WorkOrderID, ProductID, OrderQty, StockedQty, ScrappedQty, StartDate, EndDate, DueDate, ScrapReasonID
    FROM AdventureWorks2022.Production.WorkOrder;
    SET @rows += @@ROWCOUNT;

    TRUNCATE TABLE stg.WorkOrderRouting;
    INSERT INTO stg.WorkOrderRouting
    SELECT WorkOrderID, ProductID, OperationSequence, LocationID, ScheduledStartDate, ScheduledEndDate,
           ActualStartDate, ActualEndDate, ActualResourceHrs, PlannedCost, ActualCost
    FROM AdventureWorks2022.Production.WorkOrderRouting;
    SET @rows += @@ROWCOUNT;

    TRUNCATE TABLE stg.Location;
    INSERT INTO stg.Location
    SELECT LocationID, Name, CostRate, Availability FROM AdventureWorks2022.Production.Location;
    SET @rows += @@ROWCOUNT;

    TRUNCATE TABLE stg.ScrapReason;
    INSERT INTO stg.ScrapReason
    SELECT ScrapReasonID, Name FROM AdventureWorks2022.Production.ScrapReason;
    SET @rows += @@ROWCOUNT;

    TRUNCATE TABLE stg.ProductInventory;
    INSERT INTO stg.ProductInventory
    SELECT ProductID, LocationID, Shelf, Bin, Quantity, ModifiedDate FROM AdventureWorks2022.Production.ProductInventory;
    SET @rows += @@ROWCOUNT;

    EXEC etl.usp_StepEnd @log, @rows;
END
GO
