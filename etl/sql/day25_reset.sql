-- Puts AWPractice back to its state at the end of Day 24, so Day 25 can be run again from step 1
-- (Day 25 only adds the two data quality tables; the planted error in step 14 is rolled back by the step itself)
USE AWPractice;
DROP TABLE IF EXISTS etl.DQResult, etl.DQRun;
