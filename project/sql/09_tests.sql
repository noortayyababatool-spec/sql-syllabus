-- =====================================================================================
-- AWSupplyDW 09_tests.sql: proving the load behaves as designed
-- Tests 2-4 change data inside a transaction and end with ROLLBACK, so the warehouse
-- is left exactly as it was. (A ROLLBACK also removes their StepLog rows.)
-- =====================================================================================
USE AWSupplyDW;
GO

-- Test 1. Re-running with no source change changes nothing
EXEC etl.usp_RunAll;
SELECT Step, RowsAffected, Status
FROM etl.StepLog
WHERE RunID = (SELECT MAX(RunID) FROM etl.Run) AND Step LIKE 'Load%'
ORDER BY StepLogID;
GO

-- Test 2. A price change and a vendor rating change each create a new Type 2 version
DECLARE @run INT = (SELECT MAX(RunID) FROM etl.Run);
BEGIN TRANSACTION;
UPDATE stg.Product SET StandardCost = StandardCost * 1.10 WHERE ProductID = 776;   -- cost up 10 per cent
UPDATE stg.Vendor  SET CreditRating = 3 WHERE VendorID = 1492;                     -- Superior -> Above average
EXEC etl.usp_LoadDimProduct @run;
EXEC etl.usp_LoadDimVendor  @run;
SELECT 'Product 776' AS Member, CAST(StandardCost AS VARCHAR(20)) AS TrackedValue, ValidFrom, ValidTo, IsCurrent
FROM dw.DimProduct WHERE ProductID = 776
UNION ALL
SELECT 'Vendor 1492', CreditRatingName, ValidFrom, ValidTo, IsCurrent
FROM dw.DimVendor WHERE VendorID = 1492
ORDER BY Member, ValidFrom;
ROLLBACK;
GO

-- Test 3. A planted error is caught by the checks, and the gate would block publishing
DECLARE @run INT = (SELECT MAX(RunID) FROM etl.Run), @errors INT, @warnings INT;
DECLARE @caught TABLE (CheckName VARCHAR(80), FailedRows INT, Status VARCHAR(7));
BEGIN TRANSACTION;
UPDATE dw.FactPurchaseLine SET LineAmount = LineAmount + 100                      -- one wrong amount
WHERE PurchaseOrderID = 1 AND PurchaseOrderDetailID = 1;
EXEC etl.usp_QualityChecks @run, @errors OUTPUT, @warnings OUTPUT;
INSERT INTO @caught SELECT CheckName, FailedRows, Status FROM etl.DQResult WHERE RunID = @run AND Status = 'Fail';
ROLLBACK;                                                                          -- table variables survive a rollback
SELECT CheckName, FailedRows, Status,
       CASE WHEN @errors > 0 THEN 'Gate: BLOCKED, summaries not published' ELSE 'Gate: open' END AS Gate
FROM @caught;
GO

-- Test 4. A purchase line whose vendor is not in the warehouse yet is kept on the Unknown member
DECLARE @run INT = (SELECT MAX(RunID) FROM etl.Run);
BEGIN TRANSACTION;
INSERT INTO stg.PurchaseOrderHeader VALUES (9999, 1, 251, 9999, 1, '2014-09-01', '2014-09-10', 500, 40, 12.5);
INSERT INTO stg.PurchaseOrderDetail VALUES (9999, 1, '2014-09-15', 10, 1, 50, 500, 0, 0, 0);
EXEC etl.usp_LoadFactPurchaseLine @run;
SELECT f.PurchaseOrderID, f.VendorKey, v.VendorName, f.LineAmount, f.TaxAmount, f.FreightAmount
FROM dw.FactPurchaseLine f JOIN dw.DimVendor v ON v.VendorKey = f.VendorKey
WHERE f.PurchaseOrderID = 9999;
ROLLBACK;
GO
