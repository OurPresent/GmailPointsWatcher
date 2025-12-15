USE [msdb]
GO

/****** Object:  Job [GlobalPointsWatcher_DailyBackup]    Script Date: 12/15/2025 ******/
BEGIN TRANSACTION
DECLARE @ReturnCode INT
SELECT @ReturnCode = 0

/****** Check if job exists and delete if so ******/
IF EXISTS (SELECT name FROM msdb.dbo.sysjobs WHERE name=N'GlobalPointsWatcher_DailyBackup')
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name=N'GlobalPointsWatcher_DailyBackup', @delete_unused_schedule=1
END

/****** Object:  Job [GlobalPointsWatcher_DailyBackup] ******/
DECLARE @jobId BINARY(16)
EXEC @ReturnCode =  msdb.dbo.sp_add_job @job_name=N'GlobalPointsWatcher_DailyBackup', 
		@enabled=1, 
		@notify_level_eventlog=0, 
		@notify_level_email=0, 
		@notify_level_netsend=0, 
		@notify_level_page=0, 
		@delete_level=0, 
		@description=N'Backup diario de la base de datos GlobalPointsWatcher.', 
		@category_name=N'[Uncategorized (Local)]', 
		@owner_login_name=N'sa', @job_id = @jobId OUTPUT
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

/****** Object:  Step [Backup Database] ******/
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'Backup Database', 
		@step_id=1, 
		@cmdexec_success_code=0, 
		@on_success_action=1, 
		@on_success_step_id=0, 
		@on_fail_action=2, 
		@on_fail_step_id=0, 
		@retry_attempts=0, 
		@retry_interval=0, 
		@os_run_priority=0, @subsystem=N'TSQL', 
		@command=N'DECLARE @path NVARCHAR(500)
DECLARE @fileDate NVARCHAR(20)
DECLARE @fileName NVARCHAR(500)

-- Ajustar la ruta segun la configuracion del servidor. 
-- Por defecto intentamos usar la carpeta Backup de la instancia MSSQL16 por defecto.
SET @path = N''C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER_2022\MSSQL\Backup\''

IF NOT EXISTS (SELECT * FROM sys.databases WHERE name = ''GlobalPointsWatcher'')
BEGIN
    PRINT ''La base de datos GlobalPointsWatcher no existe.''
    RETURN
END

SELECT @fileDate = CONVERT(NVARCHAR(20),GETDATE(),112) + ''_'' + REPLACE(CONVERT(NVARCHAR(20),GETDATE(),108),'':'','''')
SET @fileName = @path + N''GlobalPointsWatcher_'' + @fileDate + N''.bak''

BACKUP DATABASE [GlobalPointsWatcher] 
TO  DISK = @fileName 
WITH NOFORMAT, NOINIT,  
NAME = N''GlobalPointsWatcher-Full Database Backup'', 
SKIP, NOREWIND, NOUNLOAD,  STATS = 10', 
		@database_name=N'master', 
		@flags=0
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

/****** Object:  Step [Cleanup Old Backups] ******/
-- Opcional: Paso para borrar backups antiguos (mayores a 30 dias)
EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N'Cleanup Old Backups', 
		@step_id=2, 
		@cmdexec_success_code=0, 
		@on_success_action=1, 
		@on_success_step_id=0, 
		@on_fail_action=2, 
		@on_fail_step_id=0, 
		@retry_attempts=0, 
		@retry_interval=0, 
		@os_run_priority=0, @subsystem=N'CmdExec', 
		@command=N'cmd /q /c "Forfiles /P "C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER_2022\MSSQL\Backup" /M GlobalPointsWatcher_*.bak /D -30 /C "cmd /c del @path""', 
		@flags=0
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = 1
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

/****** Object:  Schedule [GlobalPointsWatcher_DailySchedule] ******/
EXEC @ReturnCode = msdb.dbo.sp_add_schedule @schedule_name=N'GlobalPointsWatcher_DailySchedule', 
		@enabled=1, 
		@freq_type=4, -- Daily
		@freq_interval=1, 
		@freq_subday_type=1, 
		@freq_subday_interval=0, 
		@freq_relative_interval=0, 
		@freq_recurrence_factor=0, 
		@active_start_date=20250101, 
		@active_end_date=99991231, 
		@active_start_time=0, -- 00:00:00
		@active_end_time=235959
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

EXEC @ReturnCode = msdb.dbo.sp_attach_schedule @job_id=@jobId, @schedule_name=N'GlobalPointsWatcher_DailySchedule'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N'(local)'
IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback

COMMIT TRANSACTION
GOTO EndSave
QuitWithRollback:
    IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION
EndSave:
GO
