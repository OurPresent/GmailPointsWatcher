-- 1) Crear base de datos
CREATE DATABASE GlobalPointsWatcher;
GO

USE GlobalPointsWatcher;
GO

-- 2) Seguridad para credenciales (encriptación simétrica)
-- NOTA: Cambia 'StrongMasterKeyPassword!' por una contraseña robusta guardada de forma segura.
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'StrongMasterKeyPassword!';
CREATE CERTIFICATE EmailCredsCert WITH SUBJECT = 'Certificado para credenciales de correo';
CREATE SYMMETRIC KEY EmailCredsKey WITH ALGORITHM = AES_256 ENCRYPTION BY CERTIFICATE EmailCredsCert;
GO

-- 3) Tabla de credenciales de correo (usuario + contraseña encriptada)
CREATE TABLE dbo.EmailCredentials (
    Id               INT IDENTITY(1,1) PRIMARY KEY,
    Email            NVARCHAR(256) NOT NULL UNIQUE,
    PasswordEncrypted VARBINARY(MAX) NOT NULL,
    CreatedAt        DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

-- 4) Tabla de transacciones
CREATE TABLE dbo.Transactions (
    Id            BIGINT IDENTITY(1,1) PRIMARY KEY,
    Company       NVARCHAR(200) NOT NULL,
    Bank          NVARCHAR(100) NOT NULL,
    CardLast4     CHAR(4)       NOT NULL,
    AmountUSD     DECIMAL(12,2) NOT NULL,
    Points        INT           NOT NULL,
    TransactionAt DATETIME2(0)  NOT NULL,
    CreatedAt     DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME()
);

CREATE INDEX IX_Transactions_TransactionAt ON dbo.Transactions(TransactionAt);
CREATE INDEX IX_Transactions_CompanyMonth ON dbo.Transactions(Company, TransactionAt);
CREATE INDEX IX_Transactions_CardLast4Month ON dbo.Transactions(CardLast4, TransactionAt);
GO

-- 5) Procedimiento para insertar credenciales (encripta la contrase�a)
CREATE OR ALTER PROCEDURE dbo.sp_SaveEmailCredential
    @Email NVARCHAR(256),
    @PlainPassword NVARCHAR(4000)
AS
BEGIN
    SET NOCOUNT ON;
    OPEN SYMMETRIC KEY EmailCredsKey DECRYPTION BY CERTIFICATE EmailCredsCert;

    DECLARE @Enc VARBINARY(MAX) = EncryptByKey(Key_GUID('EmailCredsKey'), CONVERT(VARBINARY(MAX), @PlainPassword));

    MERGE dbo.EmailCredentials AS target
    USING (SELECT @Email AS Email) AS src
    ON target.Email = src.Email
    WHEN MATCHED THEN
        UPDATE SET PasswordEncrypted = @Enc, CreatedAt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN
        INSERT (Email, PasswordEncrypted) VALUES (@Email, @Enc);

    CLOSE SYMMETRIC KEY EmailCredsKey;
END;
GO

-- 6) Procedimiento para insertar transacci�n (opcional para uso desde aplicaciones)
CREATE OR ALTER PROCEDURE dbo.sp_InsertTransaction
    @Company NVARCHAR(200),
    @Bank NVARCHAR(100),
    @CardLast4 CHAR(4),
    @AmountUSD DECIMAL(12,2),
    @Points INT,
    @TransactionAt DATETIME2(0)
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.Transactions (Company, Bank, CardLast4, AmountUSD, Points, TransactionAt)
    VALUES (@Company, @Bank, @CardLast4, @AmountUSD, @Points, @TransactionAt);
END;
GO

-- 7) Resumen mensual por tarjeta
CREATE OR ALTER PROCEDURE dbo.sp_MonthlyPointsSummary
    @Year INT,
    @Month INT,
    @CardLast4 CHAR(4)
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Monthly AS (
        SELECT *
        FROM dbo.Transactions
        WHERE YEAR(TransactionAt) = @Year
          AND MONTH(TransactionAt) = @Month
          AND CardLast4 = @CardLast4
    )
    SELECT
        SUM(Points) AS TotalPoints,
        SUM(AmountUSD) AS TotalAmountUSD,
        (SELECT TOP 1 Company
         FROM Monthly
         GROUP BY Company
         ORDER BY COUNT(*) DESC, SUM(AmountUSD) DESC) AS TopCompany
    FROM Monthly;
END;
GO

-- 8) Env�o por correo (Database Mail) del resumen mensual
-- Requiere perfil y cuenta de Database Mail (ver secci�n siguiente)
CREATE OR ALTER PROCEDURE dbo.sp_SendMonthlySummaryEmail
    @CardLast4 CHAR(4),
    @SendTo NVARCHAR(256),
    @ProfileName NVARCHAR(128) = N'DefaultProfile' -- cambia por tu perfil real
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Year INT = YEAR(GETDATE());
    DECLARE @Month INT = MONTH(GETDATE());

    DECLARE @TotalPoints INT;
    DECLARE @TotalAmount DECIMAL(18,2);
    DECLARE @TopCompany NVARCHAR(200);

    SELECT @TotalPoints = SUM(Points),
           @TotalAmount = SUM(AmountUSD),
           @TopCompany = (SELECT TOP 1 Company
                          FROM dbo.Transactions
                          WHERE YEAR(TransactionAt) = @Year AND MONTH(TransactionAt) = @Month AND CardLast4 = @CardLast4
                          GROUP BY Company
                          ORDER BY COUNT(*) DESC, SUM(AmountUSD) DESC)
    FROM dbo.Transactions
    WHERE YEAR(TransactionAt) = @Year AND MONTH(TransactionAt) = @Month AND CardLast4 = @CardLast4;

    DECLARE @Body NVARCHAR(MAX) = CONCAT(
        'Resumen mensual ', FORMAT(DATEFROMPARTS(@Year, @Month, 1), 'MMMM yyyy'), CHAR(13)+CHAR(10),
        'Tarjeta terminación: ', @CardLast4, CHAR(13)+CHAR(10),
        'Total puntos: ', COALESCE(CONVERT(NVARCHAR(50), @TotalPoints), N'0'), CHAR(13)+CHAR(10),
        'Equivalente USD: $', COALESCE(CONVERT(NVARCHAR(50), CAST(COALESCE(@TotalPoints,0)/100.0 AS DECIMAL(18,2))), N'0.00'), CHAR(13)+CHAR(10),
        'Comercio más consumido: ', COALESCE(@TopCompany, N'�'), CHAR(13)+CHAR(10)
    );

    EXEC msdb.dbo.sp_send_dbmail
        @profile_name = @ProfileName,
        @recipients   = @SendTo,
        @subject      = CONCAT('Resumen puntos ', FORMAT(DATEFROMPARTS(@Year, @Month, 1), 'MMMM yyyy')),
        @body         = @Body;
END;
GO

-- 9) Procedimiento envoltorio para fin de mes (solo envía si hoy es último día)
CREATE OR ALTER PROCEDURE dbo.sp_SendMonthlyIfLastDay
    @CardLast4 CHAR(4),
    @SendTo NVARCHAR(256),
    @ProfileName NVARCHAR(128) = N'DefaultProfile'
AS
BEGIN
    IF CAST(GETDATE() AS DATE) = EOMONTH(GETDATE())
        EXEC dbo.sp_SendMonthlySummaryEmail @CardLast4=@CardLast4, @SendTo=@SendTo, @ProfileName=@ProfileName;
END;
GO

-- Cargar los datos de correo SMTP
USE GlobalPointsWatcher;
GO
EXEC dbo.sp_SaveEmailCredential
    @Email = N'hola@gmail.com',
    @PlainPassword = N'';


-- Habilitar Database Mail si está deshabilitado
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'Database Mail XPs', 1; RECONFIGURE;

-- Crear cuenta
EXEC msdb.dbo.sysmail_add_account_sp
    @account_name = 'CuentaSMTP',
    @description  = 'Cuenta SMTP para resumenes',
    @email_address= 'hola@gmail.com',
    @display_name = 'GlobalPoints Watcher',
    @mailserver_name = 'smtp.gmail.com', -- servidor SMTP
    @port = 587,
    @enable_ssl = 1,
    @username = 'hola@gmail.com',
    @password = '';

-- Crear perfil
EXEC msdb.dbo.sysmail_add_profile_sp
    @profile_name = 'DefaultProfile',
    @description  = 'Perfil por defecto';

-- Asociar cuenta al perfil
EXEC msdb.dbo.sysmail_add_profileaccount_sp
    @profile_name = 'DefaultProfile',
    @account_name = 'CuentaSMTP',
    @sequence_number = 1;

EXEC msdb.dbo.sp_send_dbmail
    @profile_name = 'DefaultProfile',
    @recipients = 'hola0@gmail.com',
    @subject = 'Prueba Database Mail',
    @body = 'Mensaje de prueba';

USE msdb;
GO

DECLARE @jobId UNIQUEIDENTIFIER;

EXEC sp_add_job @job_name = N'Enviar resumen mensual puntos',
                @enabled = 1,
                @description = N'Envía el resumen de puntos el último día de cada mes',
                @start_step_id = 1,
                @owner_login_name = N'sa', -- ajusta el owner
                @job_id = @jobId OUTPUT;

EXEC sp_add_jobstep
    @job_id = @jobId,
    @step_id = 1,
    @step_name = N'Ejecutar resumen si es fin de mes',
    @subsystem = N'TSQL',
    @database_name = N'GlobalPointsWatcher',
    @command = N'EXEC dbo.sp_SendMonthlyIfLastDay @CardLast4=''8624'', @SendTo=''hola@gmail.com'', @ProfileName=''DefaultProfile'';',
    @on_success_action = 1, -- Quit
    @on_fail_action = 2;    -- Retry/quit

-- Programa diario 23:59, el procedimiento solo enviará el resumen si es fin de mes
EXEC sp_add_schedule
    @schedule_name = N'Diario 23:59',
    @freq_type = 4, -- diario
    @freq_interval = 1,
    @active_start_time = 235900; -- 23:59:00

EXEC sp_attach_schedule @job_id = @jobId, @schedule_name = N'Diario 23:59';
EXEC sp_add_jobserver  @job_id = @jobId, @server_name = N'(local)'; -- ajusta el nombre del servidor si aplica
GO