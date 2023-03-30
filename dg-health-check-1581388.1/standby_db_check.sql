
-- standby_db_check.sql
-- possibly from Oracle Note 1581388.1

-- setup the environment
set pause off
set echo off
set timing off
set trimspool on
set feed on
set term on
set verify off
set linesize 500
set pagesize 100
set head on

clear col
clear break
clear computes

btitle ''
ttitle ''

btitle off
ttitle off

set newpage 1

-- set tab off is important for copy and paste of output
set tab off

set trimspool on
set line 500
set pagesize 50
col name for a30
col ID format 99
col "SRLs" format 99
col active format 99
col type format a4
col ID format 99
col "SRLs" format 99
col active format 99
col type format a4
col PROTECTION_MODE for a20
col RECOVERY_MODE for a20
col db_mode for a15

set trimspool on
set line 500
set pagesize 50
set linesize 200
col name for a30
col display_value for a60
col value for a10
col DATABASE_Role for a15

spool dg_standby_output.log

prompt
prompt -- dg parameters
prompt

SELECT name, nvl(display_value,'NULL') display_value
FROM v$parameter
WHERE name IN 
	(
		'db_name','db_unique_name','log_archive_config','log_archive_dest_2','log_archive_dest_state_2',
		'fal_client','fal_server','standby_file_management','standby_archive_dest','db_file_name_convert'
		,'log_file_name_convert','remote_login_passwordfile','local_listener','dg_broker_start',
		'dg_broker_config_file1','dg_broker_config_file2','log_archive_max_processes'
 )
order by name;

col name format a20
col DATABASE_ROLE for a10
col db_unique_name format a30

prompt
prompt -- db status
prompt

SELECT name,db_unique_name,protection_mode,DATABASE_ROLE,OPEN_MODE from v$database;

prompt
prompt -- archived log seq#
prompt

select thread#,max(sequence#) from v$archived_log where applied='YES' group by thread#;

col status format a15
col process format a10

prompt
prompt -- sb status
prompt

select process, status,thread#,sequence# from v$managed_standby;

prompt
prompt -- applied threads
prompt

SELECT 
	ARCH.THREAD# "Thread"
	, ARCH.SEQUENCE# "Last Sequence Received"
	, APPL.SEQUENCE# "Last Sequence Applied"
	, (ARCH.SEQUENCE# - APPL.SEQUENCE#) "Difference"
FROM
(
	SELECT THREAD# ,SEQUENCE#
	FROM V$ARCHIVED_LOG
	WHERE (THREAD#,FIRST_TIME ) IN 
		(
			SELECT THREAD#,MAX(FIRST_TIME)
			FROM V$ARCHIVED_LOG
			GROUP BY THREAD#
		)
) ARCH,
(
	SELECT THREAD# ,SEQUENCE#
	FROM V$LOG_HISTORY
	WHERE (THREAD#,FIRST_TIME ) IN 
		(
			SELECT THREAD#,MAX(FIRST_TIME)
			FROM V$LOG_HISTORY
			GROUP BY THREAD#
		)
) APPL
WHERE ARCH.THREAD# = APPL.THREAD#
ORDER BY 1;

col name for a30

prompt
prompt -- dg stats
prompt

select * from v$dataguard_stats;

prompt
prompt -- archive gap
prompt

select * from v$archive_gap;

col name format a30

prompt
prompt -- recovery space
prompt

select 
	name
	,floor(space_limit / 1024 / 1024) "Size MB" 
	,ceil(space_used  / 1024 / 1024) "Used MB" 
from v$recovery_file_dest
order by name;

spool off

prompt logfile: dg_standby_output.log

