
-- primary_db_check.sql
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

col name for a30
col display_value for a60
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

spool dg_primary_output.log

prompt
prompt -- DG parameters
prompt

SELECT name, nvl(display_value,'NULL') display_value
FROM v$parameter
WHERE name IN 
	(
		'db_name','db_unique_name','log_archive_config','log_archive_dest_2','log_archive_dest_state_2',
		'fal_client','fal_server','standby_file_management','standby_archive_dest','db_file_name_convert',
		'log_file_name_convert','remote_login_passwordfile','local_listener','dg_broker_start',
		'dg_broker_config_file1','dg_broker_config_file2','log_archive_max_processes'
	)
order by name;

col name for a10
col DATABASE_ROLE for a10
col db_unique_name format a30
col open_mode format a20
col switchover_status format a20


prompt
prompt -- db status
prompt

SELECT name,db_unique_name,protection_mode,DATABASE_ROLE,OPEN_MODE,switchover_status from v$database;

prompt
prompt -- archived log seq#
prompt

select thread#,max(sequence#) from v$archived_log group by thread#;

col severity for a15
col message for a70
col timestamp for a20

prompt
prompt -- dg status
prompt

select dest_id
	,severity
   ,error_code
   ,to_char(timestamp,'DD-MON-YYYY HH24:MI:SS') timestamp
   , message
from v$dataguard_status
where dest_id != 0
	-- uncomment to avoid non-error messages
	-- and error_code != 0
order by timestamp, dest_id
/

prompt
prompt -- archived dest status
prompt

select ds.dest_id id
	, ad.status
	, ds.database_mode db_mode
	, ad.archiver type
	, ds.recovery_mode
	, ds.protection_mode
	, ds.standby_logfile_count "SRLs"
	, ds.standby_logfile_active active
	, ds.archived_seq#
from v$archive_dest_status ds
	, v$archive_dest ad
where ds.dest_id = ad.dest_id
	and ad.status != 'INACTIVE'
order by ds.dest_id;


col FILE_TYPE format a20
col name format a30

prompt
prompt -- recovery space
prompt

select name
	, floor(space_limit / 1024 / 1024) "Size MB"
	, ceil(space_used  / 1024 / 1024) "Used MB"
from    v$recovery_file_dest
order by name;

prompt
prompt -- check for force logging
prompt

col force_logging format a15
select force_logging from v$database;

prompt
prompt -- check for errors
prompt

select sysdate,status,error
 from gv$archive_dest_status
 where type='PHYSICAL'
 and status!='VALID'
 or error is not null;


col file# format 99999
col name format a60
col unrecoverable_change# format 99999999999999999 head 'UNRECOVER|SCN#'
col unrecoverable_time format a25

prompt
prompt -- check for unrecoverable actions in the last 10 days
prompt

select 
	file#
	, name
	, unrecoverable_change#
	, to_char(unrecoverable_time,'yyyy-mm-dd hh24:mi:ss') unrecoverable_time
from v$datafile
where unrecoverable_time > (sysdate - 10);

prompt -- check for gaps
-- Good health = no rows returned
-- If the query returns rows, then there's an existing gap between the primary and the standby database, and you must run the same query on the standby database.
-- If the output from the primary and standby is identical, then no action is required.
-- If the output on the standby does not match the output from the primary, then the datafile on the standby should be refreshed.

select sysdate,database_mode,recovery_mode, gap_status
from v$archive_dest_status
where type='PHYSICAL'
and gap_status !='NO GAP';

spool off

prompt logfile:  dg_primary_output.log

