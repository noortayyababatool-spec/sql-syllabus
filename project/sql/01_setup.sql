-- =====================================================================================
-- Mini project: AWSupplyDW, a supply-chain data warehouse built from AdventureWorks2022
-- 01_setup.sql: the database, its four schemas and the ETL bookkeeping tables
-- Run order: 01_setup, 02_staging, 03_warehouse, 04_load, 05_quality, 06_summary,
--            07_run (runs the whole load), then 08_queries for the analysis.
-- =====================================================================================
USE master;
GO
IF DB_ID('AWSupplyDW') IS NOT NULL
BEGIN
    ALTER DATABASE AWSupplyDW SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE AWSupplyDW;
END
GO
CREATE DATABASE AWSupplyDW;
GO
ALTER DATABASE AWSupplyDW SET RECOVERY SIMPLE;   -- a warehouse is rebuilt from its source; no point-in-time restore needed
GO
USE AWSupplyDW;
GO
CREATE SCHEMA stg;   -- raw copies of the source tables, replaced on every run
GO
CREATE SCHEMA etl;   -- run log, step log and data quality results
GO
CREATE SCHEMA dw;    -- the star schemas: dimensions and facts
GO
CREATE SCHEMA rpt;   -- summary tables and views for reports
GO

-- One row per run of the whole load
CREATE TABLE etl.Run (
    RunID     INT IDENTITY(1, 1) PRIMARY KEY,
    StartedAt DATETIME2(0)   NOT NULL DEFAULT SYSDATETIME(),
    EndedAt   DATETIME2(0)   NULL,
    Status    VARCHAR(10)    NOT NULL DEFAULT 'Running'
              CHECK (Status IN ('Running', 'Succeeded', 'Failed', 'Blocked')),
    Errors    INT            NULL,      -- failed Error-level quality checks
    Warnings  INT            NULL,      -- open Warning-level quality checks
    Message   NVARCHAR(2048) NULL);

-- One row per step of a run: what it touched, how many rows, how long, and any error
CREATE TABLE etl.StepLog (
    StepLogID    INT IDENTITY(1, 1) PRIMARY KEY,
    RunID        INT            NOT NULL REFERENCES etl.Run (RunID),
    Step         VARCHAR(60)    NOT NULL,
    RowsAffected INT            NULL,
    Status       VARCHAR(10)    NOT NULL CHECK (Status IN ('Running', 'Succeeded', 'Failed')),
    Message      NVARCHAR(2048) NULL,
    StartedAt    DATETIME2(3)   NOT NULL DEFAULT SYSDATETIME(),
    EndedAt      DATETIME2(3)   NULL,
    Seconds AS (DATEDIFF(MILLISECOND, StartedAt, EndedAt) / 1000.0));

-- One row per quality check per run (the Day 25 design)
CREATE TABLE etl.DQResult (
    ResultID   INT IDENTITY(1, 1) PRIMARY KEY,
    RunID      INT          NOT NULL REFERENCES etl.Run (RunID),
    CheckName  VARCHAR(80)  NOT NULL,
    Category   VARCHAR(20)  NOT NULL,
    Severity   VARCHAR(7)   NOT NULL CHECK (Severity IN ('Error', 'Warning')),
    FailedRows INT          NOT NULL,
    Status AS (CASE WHEN FailedRows = 0 THEN 'Pass' WHEN Severity = 'Error' THEN 'Fail' ELSE 'Warning' END),
    CheckedAt  DATETIME2(0) NOT NULL DEFAULT SYSDATETIME());
GO

-- Every step of the load calls these two procedures, so the log is written the same way everywhere
CREATE OR ALTER PROCEDURE etl.usp_StepStart @RunID INT, @Step VARCHAR(60), @StepLogID INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO etl.StepLog (RunID, Step, Status) VALUES (@RunID, @Step, 'Running');
    SET @StepLogID = SCOPE_IDENTITY();
END
GO
CREATE OR ALTER PROCEDURE etl.usp_StepEnd @StepLogID INT, @Rows INT, @Status VARCHAR(10) = 'Succeeded', @Message NVARCHAR(2048) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE etl.StepLog
    SET RowsAffected = @Rows, Status = @Status, Message = @Message, EndedAt = SYSDATETIME()
    WHERE StepLogID = @StepLogID;
END
GO
