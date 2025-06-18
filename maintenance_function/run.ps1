param($req)

Write-Host "HTTP trigger function executed at: $(Get-Date)"

# Load built-in SQL client assembly (System.Data.SqlClient works in Azure Functions)
Add-Type -AssemblyName "System.Data"

# Connection info (use environment variables in production)
$server         = $env:SQL_SERVER
$masterDatabase = $env:SQL_MASTER_DB
$username       = $env:SQL_USERNAME
$password       = $env:SQL_PASSWORD
$elasticPoolName = $env:SQL_ELASTIC_POOL

# SQLS to get list of databases in the elastic pool
$dbListQuery = @"
SELECT d.name
FROM sys.databases d
INNER JOIN sys.database_service_objectives o
    ON d.database_id = o.database_id
WHERE o.elastic_pool_name = '$elasticPoolName'a
"@

# SQL maintenance script - returns result sets for logs
$sqlScript = @"
SET NOCOUNT ON;

DECLARE @dbname sysname = DB_NAME();
DECLARE @sql NVARCHAR(MAX);
DECLARE @logFileName sysname;
DECLARE @logSizeMB INT;
DECLARE @logSpaceUsedMB INT;
DECLARE @logSpaceFreePercent FLOAT;
DECLARE @beforeShrinkLogSizeMB INT;
DECLARE @afterShrinkLogSizeMB INT;
DECLARE @shrinkPerformed BIT = 0;

IF OBJECT_ID('tempdb..#MaintenanceLog') IS NOT NULL DROP TABLE #MaintenanceLog;
CREATE TABLE #MaintenanceLog (
    DatabaseName sysname,
    LogFileName sysname,
    LogSizeBeforeMB INT,
    LogSizeAfterMB INT,
    LogShrinkPerformed BIT,
    IndexRebuildPerformed BIT,
    LogSpaceUsedMB INT,
    LogSpaceFreePercent FLOAT,
    Timestamp DATETIME DEFAULT GETDATE()
);

BEGIN TRY
    -- Log file maintenance
    SET @sql = N'
    SELECT TOP 1
        mf.name AS LogFileName,
        mf.size * 8 / 1024 AS LogSizeMB,
        FILEPROPERTY(mf.name, ''SpaceUsed'') * 8 / 1024 AS LogSpaceUsedMB
    FROM sys.database_files mf
    WHERE mf.type_desc = ''LOG'';';

    IF OBJECT_ID('tempdb..#LogInfo') IS NOT NULL DROP TABLE #LogInfo;
    CREATE TABLE #LogInfo (LogFileName sysname, LogSizeMB INT, LogSpaceUsedMB INT);
    INSERT INTO #LogInfo EXEC sp_executesql @sql;

    SELECT TOP 1
        @logFileName = LogFileName,
        @logSizeMB = LogSizeMB,
        @logSpaceUsedMB = LogSpaceUsedMB
    FROM #LogInfo;

    SET @logSpaceFreePercent = CASE WHEN @logSizeMB > 0
                                    THEN ((@logSizeMB - @logSpaceUsedMB) * 100.0) / @logSizeMB
                                    ELSE 0 END;

    SET @beforeShrinkLogSizeMB = @logSizeMB;
    SET @afterShrinkLogSizeMB = @logSizeMB;

    IF @logSpaceFreePercent > 20
    BEGIN
        SET @sql = N'DBCC SHRINKFILE(' + QUOTENAME(@logFileName,'''') + ', ' + CAST(@logSpaceUsedMB + 10 AS NVARCHAR(10)) + ');';
        EXEC sp_executesql @sql;

        SET @sql = N'
        SELECT mf.size * 8 / 1024 AS LogSizeMB
        FROM sys.database_files mf
        WHERE mf.type_desc = ''LOG'' AND mf.name = ' + QUOTENAME(@logFileName,'''') + ';';

        DROP TABLE IF EXISTS #LogSizeAfter;
        CREATE TABLE #LogSizeAfter(LogSizeMB INT);
        INSERT INTO #LogSizeAfter EXEC sp_executesql @sql;
        SELECT TOP 1 @afterShrinkLogSizeMB = LogSizeMB FROM #LogSizeAfter;

        SET @shrinkPerformed = 1;
    END

    -- Fragmentation-aware index maintenance
    SET @sql = N'
    IF OBJECT_ID(''tempdb..#frag'') IS NOT NULL DROP TABLE #frag;

    SELECT
        QUOTENAME(SCHEMA_NAME(t.schema_id)) + ''.'' + QUOTENAME(t.name) AS TableName,
        i.name AS IndexName,
        i.index_id,
        ps.avg_fragmentation_in_percent
    INTO #frag
    FROM sys.tables t
    INNER JOIN sys.indexes i ON t.object_id = i.object_id AND i.type IN (1,2)
    CROSS APPLY sys.dm_db_index_physical_stats(DB_ID(), t.object_id, i.index_id, NULL, ''LIMITED'') ps
    WHERE t.is_ms_shipped = 0
      AND ps.avg_fragmentation_in_percent > 30;

    DECLARE @tbl SYSNAME, @idx SYSNAME, @ixid INT, @sql2 NVARCHAR(4000);

    DECLARE cur CURSOR FOR
        SELECT TableName, IndexName, index_id FROM #frag;

    OPEN cur;
    FETCH NEXT FROM cur INTO @tbl, @idx, @ixid;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Log the index being rebuilt
        PRINT ''Rebuilding index '' + @idx + '' on table '' + @tbl;

        SET @sql2 = N''ALTER INDEX '' + QUOTENAME(@idx) + N'' ON '' + @tbl + N'' REBUILD'';
        EXEC(@sql2);
        FETCH NEXT FROM cur INTO @tbl, @idx, @ixid;
    END

    CLOSE cur;
    DEALLOCATE cur;

    DROP TABLE #frag;
    ';
    EXEC sp_executesql @sql;

    -- Storage quota analysis
    SET @sql = N'
    IF OBJECT_ID(''tempdb..#StorageInfo'') IS NOT NULL DROP TABLE #StorageInfo;
    CREATE TABLE #StorageInfo (
        FileName sysname,
        TypeDesc nvarchar(60),
        SizeMB int,
        UsedMB int,
        FreeMB int,
        FreePercent float
    );
    INSERT INTO #StorageInfo
    SELECT
        name AS FileName,
        type_desc AS TypeDesc,
        size * 8 / 1024 AS SizeMB,
        FILEPROPERTY(name, ''SpaceUsed'') * 8 / 1024 AS UsedMB,
        (size - FILEPROPERTY(name, ''SpaceUsed'')) * 8 / 1024 AS FreeMB,
        CASE WHEN size > 0 THEN ((size - FILEPROPERTY(name, ''SpaceUsed'')) * 100.0) / size ELSE 0 END AS FreePercent
    FROM sys.database_files;

    SELECT * FROM #StorageInfo;
    ';
    EXEC sp_executesql @sql;

    -- Log maintenance summary
    INSERT INTO #MaintenanceLog (DatabaseName, LogFileName, LogSizeBeforeMB, LogSizeAfterMB, LogShrinkPerformed, IndexRebuildPerformed, LogSpaceUsedMB, LogSpaceFreePercent)
    VALUES (@dbname, @logFileName, @beforeShrinkLogSizeMB, @afterShrinkLogSizeMB, @shrinkPerformed, 1, @logSpaceUsedMB, @logSpaceFreePercent);

    -- Return logs and storage info as result sets for PowerShell to capture
    SELECT * FROM #MaintenanceLog;
    SELECT * FROM #StorageInfo;

    -- Cleanup
    DROP TABLE IF EXISTS #MaintenanceLog;
    DROP TABLE IF EXISTS #LogInfo;
    DROP TABLE IF EXISTS #LogSizeAfter;
    DROP TABLE IF EXISTS #StorageInfo;

END TRY
BEGIN CATCH
    SELECT
        ERROR_MESSAGE() AS ErrorMessage,
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_SEVERITY() AS ErrorSeverity,
        ERROR_STATE() AS ErrorState,
        ISNULL(ERROR_PROCEDURE(), 'N/A') AS ErrorProcedure,
        ERROR_LINE() AS ErrorLine;
END CATCH;
"@

# Helper: Run query that returns results
function Invoke-Sql {
    param (
        [string]$connectionString,
        [string]$query
    )
    $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
    $command = $connection.CreateCommand()
    $command.CommandText = $query
    $connection.Open()
    $reader = $command.ExecuteReader()
    $results = @()
    while ($reader.Read()) {
        $row = @{ }
        for ($i = 0; $i -lt $reader.FieldCount; $i++) {
            $row[$reader.GetName($i)] = $reader[$i]
        }
        $results += [pscustomobject]$row
    }
    $connection.Close()
    return $results
}

# Build master connection string
$connectionString = "Server=$server;Database=$masterDatabase;User ID=$username;Password=$password;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30"

try {
    Write-Host "Retrieving list of databases in elastic pool..."
    $databases = Invoke-Sql -connectionString $connectionString -query $dbListQuery

    foreach ($db in $databases) {
        $dbName = $db.name
        Write-Host "Running maintenance script on database: $dbName"

        $dbConnectionString = "Server=$server;Database=$dbName;User ID=$username;Password=$password;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30"
        $results = Invoke-Sql -connectionString $dbConnectionString -query $sqlScript

        if ($results) {
            # Extract and log detailed maintenance results
            $logBefore = $results | Where-Object { $_.LogSizeBeforeMB } | Select-Object -ExpandProperty LogSizeBeforeMB
            $logAfter = $results | Where-Object { $_.LogSizeAfterMB } | Select-Object -ExpandProperty LogSizeAfterMB
            $logSaved = $logBefore - $logAfter

            Write-Host "Maintenance results for ${dbName}:"
            Write-Host "Log file storage saved: ${logSaved} MB"
            Write-Host "Log size before: ${logBefore} MB"
            Write-Host "Log size after: ${logAfter} MB"
            $results | Format-Table | Out-String | Write-Host
        } else {
            Write-Host "No detailed results returned for $dbName."
        }

        Write-Host "Maintenance completed for database: $dbName"
    }
}
catch {
    Write-Error "An error occurred while running the maintenance script: $_"
}