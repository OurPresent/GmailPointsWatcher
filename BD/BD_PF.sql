/*
    Script Maestro de Base de Datos - GlobalPointsWatcher
    
    Este script realiza:
    1. Creación de la Base de Datos con rutas específicas para Datos y Logs.
    2. Creación de Tablas (Transacciones, Usuarios, Configuración, Reconocimientos).
    3. Creación de Procedimientos Almacenados.
    4. Configuración inicial de Jobs y Database Mail.
    
    NOTA: Ajustar las rutas de los archivos en la sección CREATE DATABASE según su entorno.
*/

USE master;
GO

IF DB_ID('GlobalPointsWatcher') IS NOT NULL
BEGIN
    ALTER DATABASE GlobalPointsWatcher SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE GlobalPointsWatcher;
END
GO

-- 1. CREACIÓN DE BASE DE DATOS (Ajustar rutas según necesidad)
-- Se recomienda crear la carpeta C:\BD_DATA\ antes de ejecutar, o cambiar a la ruta por defecto de SQL Server.
CREATE DATABASE GlobalPointsWatcher
ON PRIMARY 
( NAME = N'GlobalPointsWatcher', FILENAME = N'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\GlobalPointsWatcher.mdf' , SIZE = 8192KB , MAXSIZE = UNLIMITED, FILEGROWTH = 65536KB )
LOG ON 
( NAME = N'GlobalPointsWatcher_log', FILENAME = N'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\DATA\GlobalPointsWatcher_log.ldf' , SIZE = 8192KB , MAXSIZE = 2048GB , FILEGROWTH = 65536KB )
GO

USE GlobalPointsWatcher;
GO

-- 2. TABLAS

-- Configuración del Sistema
CREATE TABLE dbo.Parameters(
    ParamKey NVARCHAR(50) PRIMARY KEY,
    ParamValue NVARCHAR(MAX)
);
GO

-- Transacciones
CREATE TABLE dbo.Transactions (
    Id            BIGINT IDENTITY(1,1) PRIMARY KEY,
    Company       NVARCHAR(200) NOT NULL,
    Bank          NVARCHAR(100) NOT NULL,
    CardLast4     CHAR(4)       NOT NULL,
    AmountUSD     DECIMAL(12,2) NOT NULL,
    Points        INT           NOT NULL,
    TransactionAt DATETIME      NOT NULL,
    CreatedAt     DATETIME      DEFAULT GETDATE()
);
CREATE INDEX IX_Transactions_TransactionAt ON dbo.Transactions(TransactionAt);
CREATE INDEX IX_Transactions_CardLast4 ON dbo.Transactions(CardLast4);
GO

-- Reconocimiento de Transacciones (Telegram)
CREATE TABLE dbo.TransactionRecognitions(
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Token NVARCHAR(128) NOT NULL,
    Company NVARCHAR(256) NOT NULL,
    AmountUSD DECIMAL(18,2) NOT NULL,
    CardLast4 CHAR(4) NOT NULL,
    Status NVARCHAR(20) NOT NULL,
    RecognizedAt DATETIME NOT NULL
);
GO

-- Transacciones No Reconocidas
CREATE TABLE dbo.UnrecognizedTransactions(
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Token NVARCHAR(128) NOT NULL,
    Company NVARCHAR(256) NOT NULL,
    AmountUSD DECIMAL(18,2) NOT NULL,
    CardLast4 CHAR(4) NOT NULL,
    ReportedAt DATETIME NOT NULL
);
GO

-- Tarjetas de Usuarios
CREATE TABLE dbo.UserCards(
    Id INT IDENTITY(1,1) PRIMARY KEY,
    ChatId BIGINT NOT NULL,
    CardLast4 CHAR(4) NOT NULL,
    Alias NVARCHAR(50) NULL,
    CreatedAt DATETIME DEFAULT GETDATE()
);
GO

-- 3. DATOS INICIALES
INSERT INTO dbo.Parameters (ParamKey, ParamValue) VALUES 
('TELEGRAM_TOKEN', '8428323516:AAElzjmSPfUeCoTGKbm7wnDLSZ5ek1-6Gvc'),
('EMAIL_USERNAME', 'buglione2500@gmail.com'),
('EMAIL_PASSWORD', 'tsvk jljb torw blih'),
('CHAT_ID', '1943663667');
GO

-- 4. PROCEDIMIENTOS ALMACENADOS

-- Procedimiento para insertar transacción
CREATE OR ALTER PROCEDURE dbo.sp_InsertTransaction
    @Company NVARCHAR(200),
    @Bank NVARCHAR(100),
    @CardLast4 CHAR(4),
    @AmountUSD DECIMAL(12,2),
    @Points INT,
    @TransactionAt DATETIME
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.Transactions (Company, Bank, CardLast4, AmountUSD, Points, TransactionAt)
    VALUES (@Company, @Bank, @CardLast4, @AmountUSD, @Points, @TransactionAt);
END
GO

-- Procedimiento para el reporte mensual por correo
CREATE OR ALTER PROCEDURE dbo.sp_SendMonthlySummaryEmail
    @CardLast4   CHAR(4),
    @SendTo      NVARCHAR(256),
    @ProfileName NVARCHAR(128) = N'DefaultProfile'
AS
BEGIN
    SET NOCOUNT ON;
    -- Reporta el mes anterior (ya que se ejecuta el día 1 del mes siguiente)
    DECLARE @Dt DATE = DATEADD(month, -1, GETDATE());
    DECLARE @Year INT = YEAR(@Dt);
    DECLARE @Month INT = MONTH(@Dt);
    DECLARE @TotalPoints INT = 0;
    DECLARE @TopCompany NVARCHAR(256) = NULL;

    SELECT @TotalPoints = COALESCE(SUM(Points),0)
    FROM dbo.Transactions
    WHERE YEAR(TransactionAt)=@Year AND MONTH(TransactionAt)=@Month AND CardLast4=@CardLast4;

    SELECT TOP 1 @TopCompany = Company
    FROM (
        SELECT Company, SUM(Points) AS P
        FROM dbo.Transactions
        WHERE YEAR(TransactionAt)=@Year AND MONTH(TransactionAt)=@Month AND CardLast4=@CardLast4
        GROUP BY Company
    ) T
    ORDER BY P DESC;

    DECLARE @MonthName NVARCHAR(20) = DATENAME(MONTH, DATEFROMPARTS(@Year, @Month, 1));
    DECLARE @Subject NVARCHAR(255) = N'Resumen puntos ' + @MonthName + N' ' + CONVERT(NVARCHAR(4), @Year);
    DECLARE @Body NVARCHAR(MAX) =
        N'Resumen mensual ' + @MonthName + N' ' + CONVERT(NVARCHAR(4), @Year) + CHAR(13)+CHAR(10) +
        N'Tarjeta terminación: ' + @CardLast4 + CHAR(13)+CHAR(10) +
        N'Total puntos: ' + CONVERT(NVARCHAR(50), @TotalPoints) + CHAR(13)+CHAR(10) +
        N'Equivalente USD: $' + CONVERT(NVARCHAR(50), CAST(CONVERT(DECIMAL(18,2), @TotalPoints/100.0) AS DECIMAL(18,2))) + CHAR(13)+CHAR(10) +
        N'Comercio más consumido: ' + COALESCE(@TopCompany, N'–') + CHAR(13)+CHAR(10);

    -- Envío de correo (requiere Database Mail configurado)
    BEGIN TRY
        EXEC msdb.dbo.sp_send_dbmail
            @profile_name = @ProfileName,
            @recipients   = @SendTo,
            @subject      = @Subject,
            @body         = @Body;
    END TRY
    BEGIN CATCH
        -- Log error if needed
    END CATCH
END
GO

-- 5. CONFIGURACIÓN DATABASE MAIL (Básica)
sp_configure 'show advanced options', 1; RECONFIGURE;
sp_configure 'Database Mail XPs', 1; RECONFIGURE;
GO

-- 6. JOBS (Trabajos Programados)
USE msdb;
GO

DECLARE @jobId BINARY(16);
DECLARE @jobName NVARCHAR(128) = N'GlobalPointsMonthlySummary';

-- Limpiar Job anterior si existe
IF EXISTS (SELECT job_id FROM msdb.dbo.sysjobs WHERE name = @jobName)
BEGIN
    EXEC sp_delete_job @job_name = @jobName;
END

-- Crear Job
EXEC sp_add_job @job_name = @jobName, @enabled = 1, @description = N'Resumen Mensual de Puntos', @job_id = @jobId OUTPUT;

-- Crear Paso del Job (Configurar parámetros reales aquí)
EXEC sp_add_jobstep @job_id = @jobId, @step_name = N'Send Summary', @subsystem = N'TSQL', 
    @command = N'EXEC GlobalPointsWatcher.dbo.sp_SendMonthlySummaryEmail @CardLast4=''0000'', @SendTo=''usuario@ejemplo.com'', @ProfileName=''DefaultProfile''',
    @database_name = N'GlobalPointsWatcher';

-- Crear Horario (Mensual, día 1, 8:00 AM)
EXEC sp_add_schedule @schedule_name = N'MonthlySummarySchedule', 
    @freq_type = 16, @freq_interval = 1, @freq_recurrence_factor = 1, @active_start_time = 080000;

EXEC sp_attach_schedule @job_id = @jobId, @schedule_name = N'MonthlySummarySchedule';
EXEC sp_add_jobserver @job_id = @jobId;
GO

-- =============================================
-- 6. Job de Backup (Diario)
-- =============================================
USE msdb;
GO
DECLARE @backupJobId BINARY(16);
EXEC sp_add_job @job_name=N'GlobalPointsBackup', @enabled=1, @job_id = @backupJobId OUTPUT;
EXEC sp_add_jobstep @job_id=@backupJobId, @step_name=N'Full Backup', @subsystem=N'TSQL', 
    @command=N'BACKUP DATABASE [GlobalPointsWatcher] TO DISK = N''C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Backup\GlobalPointsWatcher.bak'' WITH INIT', 
    @database_name=N'master';
EXEC sp_add_schedule @schedule_name=N'DailyBackup', @freq_type=4, @freq_interval=1, @active_start_time=230000;
EXEC sp_attach_schedule @job_id=@backupJobId, @schedule_name=N'DailyBackup';
EXEC sp_add_jobserver @job_id = @backupJobId;
GO
