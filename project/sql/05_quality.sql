-- =====================================================================================
-- AWSupplyDW 05_quality.sql: data quality checks (the Day 25 design)
-- Each check counts the rows that break one rule and writes one etl.DQResult row.
-- Error = the load must not be published; Warning = publish, and a person looks.
-- =====================================================================================
USE AWSupplyDW;
GO
CREATE OR ALTER PROCEDURE etl.usp_QualityChecks @RunID INT, @Errors INT OUTPUT, @Warnings INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @log INT, @n INT;
    EXEC etl.usp_StepStart @RunID, 'Data quality checks', @log OUTPUT;
    DELETE FROM etl.DQResult WHERE RunID = @RunID;          -- the checks can be repeated for a run

    ------------------------------------------------------------ completeness
    SET @n = ABS((SELECT COUNT(*) FROM stg.PurchaseOrderDetail) - (SELECT COUNT(*) FROM dw.FactPurchaseLine));
    INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows)
    VALUES (@RunID, 'Purchase lines: staging = fact', 'Completeness', 'Error', @n);

    SET @n = CASE WHEN (SELECT SUM(CAST(LineTotal AS DECIMAL(19, 4))) FROM stg.PurchaseOrderDetail)
                     = (SELECT SUM(LineAmount) FROM dw.FactPurchaseLine) THEN 0 ELSE 1 END;
    INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows)
    VALUES (@RunID, 'Purchase amount: staging = fact', 'Completeness', 'Error', @n);

    -- orders whose allocated tax or freight does not add back up to the order's own figure
    SELECT @n = COUNT(*) FROM (
        SELECT h.PurchaseOrderID FROM stg.PurchaseOrderHeader h
        JOIN dw.FactPurchaseLine f ON f.PurchaseOrderID = h.PurchaseOrderID
        GROUP BY h.PurchaseOrderID, h.TaxAmt, h.Freight
        HAVING SUM(f.TaxAmount) <> h.TaxAmt OR SUM(f.FreightAmount) <> h.Freight) x;
    INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows)
    VALUES (@RunID, 'Tax and freight allocation adds up per order', 'Completeness', 'Error', @n);

    SET @n = ABS((SELECT COUNT(*) FROM stg.WorkOrder) - (SELECT COUNT(*) FROM dw.FactWorkOrder))
           + ABS((SELECT COUNT(*) FROM stg.WorkOrderRouting) - (SELECT COUNT(*) FROM dw.FactWorkOrderOperation));
    INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows)
    VALUES (@RunID, 'Work orders and operations: staging = fact', 'Completeness', 'Error', @n);

    SET @n = ABS((SELECT SUM(Quantity) FROM stg.ProductInventory)
               - (SELECT SUM(Quantity) FROM dw.FactInventorySnapshot
                  WHERE SnapshotDateKey = (SELECT MAX(SnapshotDateKey) FROM dw.FactInventorySnapshot)));
    INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows)
    VALUES (@RunID, 'Inventory units: staging = snapshot', 'Completeness', 'Error', @n);

    ------------------------------------------------------------ uniqueness
    SELECT @n = (SELECT COUNT(*) FROM (SELECT ProductID FROM dw.DimProduct GROUP BY ProductID
                                       HAVING SUM(CAST(IsCurrent AS INT)) <> 1) a)
              + (SELECT COUNT(*) FROM (SELECT VendorID FROM dw.DimVendor GROUP BY VendorID
                                       HAVING SUM(CAST(IsCurrent AS INT)) <> 1) b);
    INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows)
    VALUES (@RunID, 'Exactly one current version per product and vendor', 'Uniqueness', 'Error', @n);

    ------------------------------------------------------------ consistency
    WITH v AS (
        SELECT ProductID AS ID, ValidFrom, ValidTo, LEAD(ValidFrom) OVER (PARTITION BY ProductID ORDER BY ValidFrom) AS NextFrom FROM dw.DimProduct
        UNION ALL
        SELECT VendorID + 1000000, ValidFrom, ValidTo, LEAD(ValidFrom) OVER (PARTITION BY VendorID ORDER BY ValidFrom) FROM dw.DimVendor)
    SELECT @n = COUNT(*) FROM v
    WHERE ValidFrom >= ValidTo OR (NextFrom IS NOT NULL AND NextFrom <> ValidTo) OR (NextFrom IS NULL AND ValidTo <> '9999-12-31');
    INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows)
    VALUES (@RunID, 'Type 2 versions touch, no gaps or overlaps', 'Consistency', 'Error', @n);

    SELECT @n = COUNT(*) FROM dw.DimProduct d JOIN stg.Product s ON s.ProductID = d.ProductID
    WHERE d.IsCurrent = 1 AND (d.StandardCost <> s.StandardCost OR d.ListPrice <> s.ListPrice);
    INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows)
    VALUES (@RunID, 'Current product version has the source prices', 'Consistency', 'Error', @n);

    SELECT @n = (SELECT COUNT(*) FROM dw.FactPurchaseLine WHERE VendorKey = -1 OR ProductKey = -1 OR EmployeeKey = -1
                                                            OR ShipMethodKey = -1 OR StatusKey = 0 OR OrderDateKey = -1)
              + (SELECT COUNT(*) FROM dw.FactWorkOrder WHERE ProductKey = -1 OR ScrapReasonKey = -1 OR StartDateKey = -1)
              + (SELECT COUNT(*) FROM dw.FactWorkOrderOperation WHERE ProductKey = -1 OR LocationKey = -1)
              + (SELECT COUNT(*) FROM dw.FactInventorySnapshot WHERE ProductKey = -1 OR LocationKey = -1);
    INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows)
    VALUES (@RunID, 'Fact rows on an Unknown member', 'Consistency', 'Warning', @n);

    ------------------------------------------------------------ validity
    SELECT @n = COUNT(*) FROM dw.FactPurchaseLine
    WHERE OrderQty <= 0 OR UnitPrice < 0 OR RejectedQty < 0 OR StockedQty < 0
       OR ReceivedQty <> RejectedQty + StockedQty
       OR ABS(LineAmount - OrderQty * UnitPrice) > 0.01;
    INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows)
    VALUES (@RunID, 'Purchase quantities and amounts consistent', 'Validity', 'Error', @n);

    SELECT @n = COUNT(*) FROM dw.FactWorkOrder
    WHERE OrderQty <= 0 OR StockedQty + ScrappedQty <> OrderQty OR EndDateKey < StartDateKey
       OR (ScrappedQty > 0 AND ScrapReasonKey = 0) OR (ScrappedQty = 0 AND ScrapReasonKey > 0);
    INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows)
    VALUES (@RunID, 'Work order quantities, dates and scrap reason consistent', 'Validity', 'Error', @n);

    SELECT @n = COUNT(*) FROM dw.FactPurchaseLine WHERE DueDateKey < OrderDateKey;
    INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows)
    VALUES (@RunID, 'Purchase line due before it was ordered', 'Validity', 'Warning', @n);

    SELECT @n = COUNT(*) FROM dw.FactInventorySnapshot
    WHERE SnapshotDateKey = (SELECT MAX(SnapshotDateKey) FROM dw.FactInventorySnapshot) AND CostBasis = 'No cost known';
    INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows)
    VALUES (@RunID, 'Stock with no cost to value it', 'Validity', 'Warning', @n);

    ------------------------------------------------------------ plausibility
    SELECT @n = COUNT(*) FROM dw.FactPurchaseLine WHERE ReceivedQty > OrderQty;
    INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows)
    VALUES (@RunID, 'More received than ordered', 'Plausibility', 'Warning', @n);

    -- a real factory's actual cost differs from plan on some operations; if it never does,
    -- "actual cost" is a copy of the plan and cost variance cannot be reported
    SET @n = CASE WHEN EXISTS (SELECT 1 FROM dw.FactWorkOrderOperation WHERE ActualCost <> PlannedCost) THEN 0 ELSE 1 END;
    INSERT INTO etl.DQResult (RunID, CheckName, Category, Severity, FailedRows)
    VALUES (@RunID, 'Actual operation cost ever differs from plan', 'Plausibility', 'Warning', @n);

    SELECT @Errors   = COUNT(CASE WHEN Status = 'Fail' THEN 1 END),
           @Warnings = COUNT(CASE WHEN Status = 'Warning' THEN 1 END)
    FROM etl.DQResult WHERE RunID = @RunID;

    SET @n = (SELECT COUNT(*) FROM etl.DQResult WHERE RunID = @RunID);   -- checks recorded
    EXEC etl.usp_StepEnd @log, @n;
END
GO
