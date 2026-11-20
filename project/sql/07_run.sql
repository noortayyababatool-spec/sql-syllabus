-- =====================================================================================
-- AWSupplyDW 07_run.sql: one procedure that runs the whole load, with logging and a gate
--   extract -> dimensions -> facts -> quality checks -> gate -> publish summaries
-- Any failure is logged against its step and the run, then re-raised so a scheduler
-- (SQL Server Agent) marks the job failed. Quality errors block publishing.
-- =====================================================================================
USE AWSupplyDW;
GO
CREATE OR ALTER PROCEDURE etl.usp_RunAll
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @run INT, @errors INT, @warnings INT, @msg NVARCHAR(2048);

    INSERT INTO etl.Run DEFAULT VALUES;
    SET @run = SCOPE_IDENTITY();

    BEGIN TRY
        EXEC etl.usp_Extract                    @run;
        EXEC etl.usp_LoadDimDate                @run;
        EXEC etl.usp_LoadSmallDimensions        @run;
        EXEC etl.usp_LoadDimVendor              @run;
        EXEC etl.usp_LoadDimProduct             @run;
        EXEC etl.usp_LoadFactPurchaseLine       @run;
        EXEC etl.usp_LoadFactWorkOrder          @run;
        EXEC etl.usp_LoadFactWorkOrderOperation @run;
        EXEC etl.usp_LoadFactInventorySnapshot  @run;
        EXEC etl.usp_QualityChecks              @run, @errors OUTPUT, @warnings OUTPUT;
    END TRY
    BEGIN CATCH
        SET @msg = CONCAT(ERROR_PROCEDURE(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE());
        IF XACT_STATE() <> 0 ROLLBACK;
        UPDATE etl.StepLog SET Status = 'Failed', Message = @msg, EndedAt = SYSDATETIME()
        WHERE RunID = @run AND Status = 'Running';
        UPDATE etl.Run SET Status = 'Failed', EndedAt = SYSDATETIME(), Message = @msg WHERE RunID = @run;
        THROW;
    END CATCH;

    -- The gate: the warehouse tables are loaded, but nothing is published if a check failed
    IF @errors > 0
    BEGIN
        SET @msg = CONCAT('Run ', @run, ': ', @errors, ' data quality errors. Summaries not published.');
        UPDATE etl.Run SET Status = 'Blocked', EndedAt = SYSDATETIME(), Errors = @errors, Warnings = @warnings, Message = @msg
        WHERE RunID = @run;
        THROW 50001, @msg, 1;
    END;

    EXEC etl.usp_BuildSummaries @run;

    SET @msg = CONCAT('Run ', @run, ' succeeded: 0 errors, ', @warnings, ' warnings. Summaries published.');
    UPDATE etl.Run SET Status = 'Succeeded', EndedAt = SYSDATETIME(), Errors = 0, Warnings = @warnings, Message = @msg
    WHERE RunID = @run;
    PRINT @msg;
END
GO
