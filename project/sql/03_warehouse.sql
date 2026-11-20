-- =====================================================================================
-- AWSupplyDW 03_warehouse.sql: the dimension and fact tables
-- Two business processes (purchasing and manufacturing) plus an inventory snapshot,
-- sharing conformed DimDate and DimProduct. Every dimension has an Unknown member
-- with key -1, so a fact row is never lost when a lookup fails (Day 24).
-- =====================================================================================
USE AWSupplyDW;
GO
---------------------------------------------------------------- dimensions
CREATE TABLE dw.DimDate (
    DateKey      INT          NOT NULL PRIMARY KEY,   -- yyyymmdd; -1 = unknown
    [Date]       DATE         NOT NULL,
    [Year]       SMALLINT     NOT NULL,
    [Quarter]    TINYINT      NOT NULL,
    YearQuarter  CHAR(7)      NOT NULL,               -- 2013-Q2
    MonthNo      TINYINT      NOT NULL,
    [MonthName]  VARCHAR(9)   NOT NULL,
    YearMonth    CHAR(7)      NOT NULL,               -- 2013-04
    DayName      VARCHAR(9)   NOT NULL,
    IsWeekend    BIT          NOT NULL,
    FiscalYear   SMALLINT     NOT NULL);              -- AdventureWorks' fiscal year starts on 1 July

CREATE TABLE dw.DimProduct (                           -- Type 2: a new version when cost or list price changes
    ProductKey       INT IDENTITY(1, 1) PRIMARY KEY,
    ProductID        INT           NOT NULL,
    ProductName      NVARCHAR(50)  NOT NULL,
    ProductNumber    NVARCHAR(25)  NOT NULL,
    Category         NVARCHAR(50)  NOT NULL,
    Subcategory      NVARCHAR(50)  NOT NULL,
    Sourcing         VARCHAR(12)   NOT NULL,           -- Manufactured / Purchased
    IsFinishedGood   BIT           NOT NULL,
    Color            NVARCHAR(15)  NOT NULL,
    ProductLine      VARCHAR(10)   NOT NULL,
    SafetyStockLevel SMALLINT      NOT NULL,
    ReorderPoint     SMALLINT      NOT NULL,
    StandardCost     DECIMAL(19, 4) NOT NULL,          -- Type 2
    ListPrice        DECIMAL(19, 4) NOT NULL,          -- Type 2
    ValidFrom        DATE          NOT NULL,
    ValidTo          DATE          NOT NULL,           -- exclusive: the next version's ValidFrom, or 9999-12-31
    IsCurrent        BIT           NOT NULL,
    HistorySource    VARCHAR(20)   NOT NULL);          -- Price history / Earliest history / No history / Change seen
CREATE UNIQUE INDEX UX_DimProduct_Current ON dw.DimProduct (ProductID) WHERE IsCurrent = 1;
CREATE UNIQUE INDEX UX_DimProduct_From    ON dw.DimProduct (ProductID, ValidFrom);

CREATE TABLE dw.DimVendor (                            -- Type 2 on rating, preferred and active; Type 1 on name and address
    VendorKey        INT IDENTITY(1, 1) PRIMARY KEY,
    VendorID         INT           NOT NULL,
    AccountNumber    NVARCHAR(15)  NOT NULL,
    VendorName       NVARCHAR(50)  NOT NULL,
    CreditRating     TINYINT       NOT NULL,
    CreditRatingName VARCHAR(13)   NOT NULL,
    PreferredVendor  VARCHAR(3)    NOT NULL,
    ActiveStatus     VARCHAR(8)    NOT NULL,
    City             NVARCHAR(30)  NOT NULL,
    StateProvince    NVARCHAR(50)  NOT NULL,
    Country          NVARCHAR(50)  NOT NULL,
    ValidFrom        DATE          NOT NULL,
    ValidTo          DATE          NOT NULL,
    IsCurrent        BIT           NOT NULL);
CREATE UNIQUE INDEX UX_DimVendor_Current ON dw.DimVendor (VendorID) WHERE IsCurrent = 1;

CREATE TABLE dw.DimEmployee (                          -- Type 1
    EmployeeKey  INT IDENTITY(1, 1) PRIMARY KEY,
    EmployeeID   INT          NOT NULL UNIQUE,
    EmployeeName NVARCHAR(101) NOT NULL,
    JobTitle     NVARCHAR(50) NOT NULL,
    Department   NVARCHAR(50) NOT NULL);

CREATE TABLE dw.DimShipMethod (
    ShipMethodKey INT IDENTITY(1, 1) PRIMARY KEY,
    ShipMethodID  INT          NOT NULL UNIQUE,
    ShipMethod    NVARCHAR(50) NOT NULL,
    ShipBase      DECIMAL(19, 4) NOT NULL,
    ShipRate      DECIMAL(19, 4) NOT NULL);

CREATE TABLE dw.DimPurchaseStatus (                    -- four fixed values, keyed by the source code
    StatusKey     TINYINT     NOT NULL PRIMARY KEY,
    StatusName    VARCHAR(10) NOT NULL,
    CountsAsSpend BIT         NOT NULL);               -- rejected orders were returned, not paid for

CREATE TABLE dw.DimLocation (
    LocationKey  INT IDENTITY(1, 1) PRIMARY KEY,
    LocationID   SMALLINT     NOT NULL UNIQUE,
    LocationName NVARCHAR(50) NOT NULL,
    CostRate     DECIMAL(10, 4) NOT NULL,
    Availability DECIMAL(8, 2) NOT NULL);

CREATE TABLE dw.DimScrapReason (
    ScrapReasonKey INT IDENTITY(1, 1) PRIMARY KEY,
    ScrapReasonID  SMALLINT     NOT NULL UNIQUE,
    ScrapReason    NVARCHAR(50) NOT NULL);

---------------------------------------------------------------- unknown and fixed members
SET IDENTITY_INSERT dw.DimProduct ON;
INSERT INTO dw.DimProduct (ProductKey, ProductID, ProductName, ProductNumber, Category, Subcategory, Sourcing, IsFinishedGood,
                           Color, ProductLine, SafetyStockLevel, ReorderPoint, StandardCost, ListPrice, ValidFrom, ValidTo, IsCurrent, HistorySource)
VALUES (-1, -1, 'Unknown', 'Unknown', 'Unknown', 'Unknown', 'Unknown', 0, 'Unknown', 'Unknown', 0, 0, 0, 0, '1900-01-01', '9999-12-31', 1, 'Unknown member');
SET IDENTITY_INSERT dw.DimProduct OFF;
SET IDENTITY_INSERT dw.DimVendor ON;
INSERT INTO dw.DimVendor (VendorKey, VendorID, AccountNumber, VendorName, CreditRating, CreditRatingName, PreferredVendor, ActiveStatus,
                          City, StateProvince, Country, ValidFrom, ValidTo, IsCurrent)
VALUES (-1, -1, 'Unknown', 'Unknown', 0, 'Unknown', 'Unk', 'Unknown', 'Unknown', 'Unknown', 'Unknown', '1900-01-01', '9999-12-31', 1);
SET IDENTITY_INSERT dw.DimVendor OFF;
SET IDENTITY_INSERT dw.DimEmployee ON;
INSERT INTO dw.DimEmployee (EmployeeKey, EmployeeID, EmployeeName, JobTitle, Department) VALUES (-1, -1, 'Unknown', 'Unknown', 'Unknown');
SET IDENTITY_INSERT dw.DimEmployee OFF;
SET IDENTITY_INSERT dw.DimShipMethod ON;
INSERT INTO dw.DimShipMethod (ShipMethodKey, ShipMethodID, ShipMethod, ShipBase, ShipRate) VALUES (-1, -1, 'Unknown', 0, 0);
SET IDENTITY_INSERT dw.DimShipMethod OFF;
SET IDENTITY_INSERT dw.DimLocation ON;
INSERT INTO dw.DimLocation (LocationKey, LocationID, LocationName, CostRate, Availability) VALUES (-1, -1, 'Unknown', 0, 0);
SET IDENTITY_INSERT dw.DimLocation OFF;
SET IDENTITY_INSERT dw.DimScrapReason ON;
INSERT INTO dw.DimScrapReason (ScrapReasonKey, ScrapReasonID, ScrapReason)
VALUES (-1, -1, 'Unknown'), (0, 0, 'Not scrapped');        -- most work orders scrap nothing: that is a real value, not unknown
SET IDENTITY_INSERT dw.DimScrapReason OFF;
INSERT INTO dw.DimPurchaseStatus (StatusKey, StatusName, CountsAsSpend)
VALUES (0, 'Unknown', 0), (1, 'Pending', 1), (2, 'Approved', 1), (3, 'Rejected', 0), (4, 'Complete', 1);
GO

---------------------------------------------------------------- facts
-- Purchasing. Grain: one purchase order line. Tax and freight are recorded per order;
-- they are allocated to the lines in proportion to the line amount, so they add up exactly.
CREATE TABLE dw.FactPurchaseLine (
    PurchaseOrderID       INT NOT NULL,                 -- degenerate dimension: the order number
    PurchaseOrderDetailID INT NOT NULL,
    OrderDateKey   INT     NOT NULL REFERENCES dw.DimDate (DateKey),
    DueDateKey     INT     NOT NULL REFERENCES dw.DimDate (DateKey),
    ShipDateKey    INT     NOT NULL REFERENCES dw.DimDate (DateKey),
    VendorKey      INT     NOT NULL REFERENCES dw.DimVendor (VendorKey),
    ProductKey     INT     NOT NULL REFERENCES dw.DimProduct (ProductKey),
    EmployeeKey    INT     NOT NULL REFERENCES dw.DimEmployee (EmployeeKey),
    ShipMethodKey  INT     NOT NULL REFERENCES dw.DimShipMethod (ShipMethodKey),
    StatusKey      TINYINT NOT NULL REFERENCES dw.DimPurchaseStatus (StatusKey),
    OrderQty       INT            NOT NULL,
    ReceivedQty    DECIMAL(9, 2)  NOT NULL,
    RejectedQty    DECIMAL(9, 2)  NOT NULL,
    StockedQty     DECIMAL(9, 2)  NOT NULL,
    UnitPrice      DECIMAL(19, 4) NOT NULL,
    LineAmount     DECIMAL(19, 4) NOT NULL,             -- OrderQty x UnitPrice
    TaxAmount      DECIMAL(19, 4) NOT NULL,             -- allocated from the order
    FreightAmount  DECIMAL(19, 4) NOT NULL,             -- allocated from the order
    CONSTRAINT PK_FactPurchaseLine PRIMARY KEY (PurchaseOrderID, PurchaseOrderDetailID));

-- Manufacturing. Grain: one work order (one product, one batch).
CREATE TABLE dw.FactWorkOrder (
    WorkOrderID     INT NOT NULL PRIMARY KEY,
    ProductKey      INT NOT NULL REFERENCES dw.DimProduct (ProductKey),
    StartDateKey    INT NOT NULL REFERENCES dw.DimDate (DateKey),
    EndDateKey      INT NOT NULL REFERENCES dw.DimDate (DateKey),
    DueDateKey      INT NOT NULL REFERENCES dw.DimDate (DateKey),
    ScrapReasonKey  INT NOT NULL REFERENCES dw.DimScrapReason (ScrapReasonKey),
    OrderQty        INT            NOT NULL,
    StockedQty      INT            NOT NULL,
    ScrappedQty     INT            NOT NULL,
    DaysToBuild     INT            NOT NULL,
    DaysLate        INT            NOT NULL,            -- 0 when finished on or before the due date
    StandardCostAtStart DECIMAL(19, 4) NOT NULL,        -- unit cost from the product version valid on the start date
    ScrapCost       DECIMAL(19, 4) NOT NULL);           -- ScrappedQty x StandardCostAtStart

-- Manufacturing, finer grain: one operation of a work order at one work centre.
-- Only 42,625 of the 72,591 work orders have operations: the rest are subassemblies with no routing.
CREATE TABLE dw.FactWorkOrderOperation (
    WorkOrderID        INT      NOT NULL,
    OperationSequence  SMALLINT NOT NULL,
    ProductKey         INT NOT NULL REFERENCES dw.DimProduct (ProductKey),
    LocationKey        INT NOT NULL REFERENCES dw.DimLocation (LocationKey),
    ScheduledStartDateKey INT NOT NULL REFERENCES dw.DimDate (DateKey),
    ActualStartDateKey    INT NOT NULL REFERENCES dw.DimDate (DateKey),
    ActualEndDateKey      INT NOT NULL REFERENCES dw.DimDate (DateKey),
    ResourceHours      DECIMAL(9, 4)  NOT NULL,
    PlannedCost        DECIMAL(19, 4) NOT NULL,
    ActualCost         DECIMAL(19, 4) NOT NULL,
    DaysLate           INT            NOT NULL,         -- actual end after scheduled end
    CONSTRAINT PK_FactWorkOrderOperation PRIMARY KEY (WorkOrderID, OperationSequence));

-- Inventory. Grain: one product at one location on the snapshot date (a periodic snapshot).
-- Quantity is semi-additive: add it across products and locations, never across dates.
CREATE TABLE dw.FactInventorySnapshot (
    SnapshotDateKey INT NOT NULL REFERENCES dw.DimDate (DateKey),
    ProductKey      INT NOT NULL REFERENCES dw.DimProduct (ProductKey),
    LocationKey     INT NOT NULL REFERENCES dw.DimLocation (LocationKey),
    Quantity        INT            NOT NULL,
    UnitCost        DECIMAL(19, 4) NOT NULL,
    InventoryValue  DECIMAL(19, 4) NOT NULL,
    CostBasis       VARCHAR(20)    NOT NULL,             -- Standard cost / Last purchase price / No cost known
    CONSTRAINT PK_FactInventorySnapshot PRIMARY KEY (SnapshotDateKey, ProductKey, LocationKey));
GO
