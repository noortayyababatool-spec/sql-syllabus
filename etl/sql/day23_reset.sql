-- Puts AWPractice back to its state at the end of Day 22, so Day 23 can be run again from step 1
USE AWPractice;
DROP VIEW IF EXISTS etl.vCustomer, etl.vProduct, etl.vSalesLine;
DROP TABLE IF EXISTS stg.Store, stg.ProductSubcategory, stg.ProductCategory;
DROP TABLE IF EXISTS stg.WebSignupRaw, stg.WebSignupReject, stg.WebSignupClean, etl.CityMap;
DELETE FROM etl.LoadLog WHERE LogID > 6;
DBCC CHECKIDENT ('etl.LoadLog', RESEED, 6) WITH NO_INFOMSGS;
