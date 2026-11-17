-- Puts AWPractice back to its state at the end of Day 23, so Day 24 can be run again from step 1
USE AWPractice;
DROP TABLE IF EXISTS dw.FactSales, dw.DimDate, dw.DimCustomer, dw.DimProduct;
IF SCHEMA_ID('dw') IS NOT NULL DROP SCHEMA dw;
DELETE FROM stg.SalesOrderDetail WHERE SalesOrderID = 75124;
DELETE FROM stg.SalesOrderHeader WHERE SalesOrderID = 75124;
DELETE FROM stg.Customer WHERE CustomerID = 30119;
UPDATE stg.Customer SET City = 'Rockhampton' WHERE CustomerID = 11000;
UPDATE stg.Product SET ListPrice = 1431.50, ModifiedDate = '2014-02-08 10:01:36.827' WHERE ProductID = 680;
UPDATE stg.Product SET ListPrice = 5.99, ModifiedDate = '2026-10-16 17:51:24.467' WHERE ProductID = 1001;
DELETE FROM stg.Product WHERE ProductID = 1005;
TRUNCATE TABLE stg.ProductDelta;
UPDATE etl.Watermark SET LastModified = '2026-11-13 09:00' WHERE TableName = 'dbo.Product';
DELETE FROM etl.LoadLog WHERE LogID > 9;
DBCC CHECKIDENT ('etl.LoadLog', RESEED, 9) WITH NO_INFOMSGS;
