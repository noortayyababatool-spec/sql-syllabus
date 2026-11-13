-- Puts AWPractice back to its state before Day 22, so the steps can be run again from step 1
USE AWPractice;
DROP TABLE IF EXISTS stg.SalesOrderHeader, stg.SalesOrderDetail, stg.Customer, stg.Product, stg.ProductDelta;
DROP TABLE IF EXISTS etl.LoadLog, etl.Watermark;
IF SCHEMA_ID('stg') IS NOT NULL EXEC('DROP SCHEMA stg');
IF SCHEMA_ID('etl') IS NOT NULL EXEC('DROP SCHEMA etl');
UPDATE dbo.Product SET ListPrice = 1431.50, ModifiedDate = '2014-02-08 10:01:36.827' WHERE ProductID = 680;
UPDATE dbo.Product SET ListPrice = 5.99, ModifiedDate = (SELECT ModifiedDate FROM dbo.Product WHERE ProductID = 1002) WHERE ProductID = 1001;
DELETE FROM dbo.Product WHERE ProductNumber = 'PR-1005';
DBCC CHECKIDENT ('dbo.Product', RESEED, 1004) WITH NO_INFOMSGS;
