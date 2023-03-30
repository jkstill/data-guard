SPOOL OFF
CLEAR SCREEN

col   NAME    NEW_VALUE  v_name
SELECT NAME FROM V$DATABASE;


set tab off

SPOOL test.log

PROMPT
PROMPT -----------------------------------------------------------------------|
PROMPT

SET TERMOUT ON
SET VERIFY OFF
SET FEEDBACK ON

PROMPT
PROMPT Checking database name and archive mode, dbid
PROMPT

col NAME format A9
col LOG_MODE format A12

SELECT NAME,CREATED, LOG_MODE, DBID FROM V$DATABASE;

PROMPT
PROMPT -----------------------------------------------------------------------|
PROMPT
PROMPT
PROMPT Checking Time since last RMAN backup
PROMPT

select (sysdate-min(t))*24 from
(
select max(b.CHECKPOINT_TIME) t
from v$backup_datafile b, v$tablespace ts, v$datafile f
where INCLUDED_IN_DATABASE_BACKUP='YES'
and f.file#=b.file#
and f.ts#=ts.ts#
group by f.file#
);

PROMPT
PROMPT -----------------------------------------------------------------------|
PROMPT
PROMPT
PROMPT Check for default passwords .
PROMPT

SELECT U.USERNAME FROM SYS.DBA_USERS_WITH_DEFPWD U WHERE USERNAME <> 'XS$NULL';

PROMPT
PROMPT Checking freespace by tablespace
PROMPT

col dummy noprint
col  pct_used format 999.9       heading "%|Used"
col  name    format a16      heading "Tablespace Name"
col  bytes   format 9,999,999,999,999    heading "Total Bytes"
col  used    format 999,999,999,999   heading "Used"
col  free    format 999,999,999,999  heading "Free"

break   on report
compute sum of bytes on report
compute sum of free on report
compute sum of used on report

set linesize 132
set pagesize 400
set termout off

select a.tablespace_name                                              name,
       b.tablespace_name                                              dummy,
       sum(b.bytes)/count( distinct a.file_id||'.'||a.block_id )      bytes,
       sum(b.bytes)/count( distinct a.file_id||'.'||a.block_id ) -
       sum(a.bytes)/count( distinct b.file_id )              used,
       sum(a.bytes)/count( distinct b.file_id )                       free,
       100 * ( (sum(b.bytes)/count( distinct a.file_id||'.'||a.block_id )) -
               (sum(a.bytes)/count( distinct b.file_id ) )) /
       (sum(b.bytes)/count( distinct a.file_id||'.'||a.block_id )) pct_used
from sys.dba_free_space a, sys.dba_data_files b
where a.tablespace_name = b.tablespace_name
group by a.tablespace_name, b.tablespace_name;


PROMPT
PROMPT ------------------------------------------------------------------------|
PROMPT
PROMPT
PROMPT Check for tablespaces without flashback data should be ZERO!!
PROMPT
select name,flashback_on from v$tablespace where flashback_on='NO';
PROMPT
PROMPT ------------------------------------------------------------------------|
PROMPT
PROMPT
PROMPT Checking Size and usage in GB of Flash Recovery Area
PROMPT

SELECT
  ROUND((A.SPACE_LIMIT / 1024 / 1024 / 1024), 2) AS FLASH_IN_GB,
  ROUND((A.SPACE_USED / 1024 / 1024 / 1024), 2) AS FLASH_USED_IN_GB,
  ROUND((A.SPACE_RECLAIMABLE / 1024 / 1024 / 1024), 2) AS FLASH_RECLAIMABLE_GB,
  SUM(B.PERCENT_SPACE_USED)  AS PERCENT_OF_SPACE_USED
FROM
  V$RECOVERY_FILE_DEST A,
  V$FLASH_RECOVERY_AREA_USAGE B
GROUP BY
  SPACE_LIMIT,
  SPACE_USED ,
  SPACE_RECLAIMABLE ;

PROMPT
PROMPT ------------------------------------------------------------------------|
PROMPT
PROMPT
PROMPT Checking free space In Flash Recovery Area
PROMPT

col FILE_TYPE format a20
select * from v$flash_recovery_area_usage;

PROMPT
PROMPT ------------------------------------------------------------------------|
PROMPT
PROMPT
PROMPT ------------------------------------------------------------------------|
PROMPT

col STANDBY format a20
col applied format a10

SELECT  NAME AS STANDBY, SEQUENCE#, APPLIED, COMPLETION_TIME FROM V$ARCHIVED_LOG WHERE  DEST_ID = 2 AND NEXT_TIME > SYSDATE -1 ORDER BY SEQUENCE#;

prompt
prompt----------------Last log on Primary--------------------------------------|
prompt

select max(sequence#) from v$archived_log where NEXT_TIME > sysdate -1;

PROMPT
PROMPT ------------------------------------------------------------------------|
PROMPT
PROMPT
PROMPT Checking switchover status
PROMPT

select switchover_status from v$database;

PROMPT
PROMPT ------------------------------------------------------------------------|
PROMPT
PROMPT
PROMPT Checking for guaranteed restored points
PROMPT

select name from V$RESTORE_POINT WHERE GUARANTEE_FLASHBACK_DATABASE='YES';

PROMPT
PROMPT ------------------------------------------------------------------------|
PROMPT
PROMPT
PROMPT Checking for Failed jobs
PROMPT

SELECT
  OWNER,
  LOG_DATE,
  JOB_NAME,
  STATUS
FROM
  DBA_SCHEDULER_JOB_RUN_DETAILS
WHERE
  STATUS <> 'SUCCEEDED'
AND
  LOG_DATE > SYSDATE -7;

PROMPT
PROMPT ------------------------------------------------------------------------|
PROMPT
PROMPT
PROMPT Checking for invalid objects
PROMPT

col owner format A15
col object_name format A30 heading 'Object'
col object_id format 999999 heading "Id#"
col object_type format A15
col status format A8
col USERNAME format A35

select owner, object_name, object_id, object_type, status
from dba_objects where status != 'VALID' and object_type != 'SYNONYM';

PROMPT
PROMPT ------------------------------------------------------------------------|
PROMPT
PROMPT
PROMPT  Checking Quotas
PROMPT

select
  tablespace_name,
  username,
  round (max_bytes / 1024 / 1024  ) as total_Available,
  round (bytes / 1024 / 1024  ) as Total_used,
  round( (bytes / 1024 / 1024  )/( max_bytes / 1024 / 1024) * 100,2) as Percentage
from
  dba_ts_quotas
where
   tablespace_name not in ('SYSAUX','SYSTEM')
and
  bytes / 1024 / 1024 > 1000
and
  max_bytes / 1024 / 1024 >  0
and
  exists (select tablespace_name from dba_ts_quotas )
order by
  username;

PROMPT
PROMPT ------------------------------------------------------------------------|
PROMPT
PROMPT
PROMPT ------------------------------------------------------------------------|
PROMPT
PROMPT
PROMPT Checking the recycle Bin
PROMPT

SELECT
  OWNER, SUM(SPACE) AS TOTAL_BLOCKS
FROM
  DBA_RECYCLEBIN GROUP BY OWNER
ORDER BY OWNER;

PROMPT
PROMPT ------------------------------------------------------------------------|
PROMPT
PROMPT
PROMPT Checking for common users logging in NOT GOOD!!!
PROMPT

col USERNAME format a24
col OS_USERNAME format a24
col TERMINAL format a40
col USERHOST format a30

select
    a.username,
     a.timestamp,
     a.logoff_time,
     a.returncode,
     userhost
from
   dba_audit_session a
where (a.username,a.timestamp) in
     (select b.username,max(b.timestamp)
         from dba_audit_session b
         group by b.username)
and
    a.timestamp>(sysdate-30)
and
   a.username IN ('ANONYMOUS','APEX_040200','APEX_PUBLIC_USER','APPQOSSYS','AUDSYS',
                  'CTXSYS','DIP','DVF','DVSYS','FLOWS_FILES','GSMADMIN_INTERNAL',
                  'GSMCATUSER','GSMUSER','LBACSYS','MDDATA','MDSYS','OJVMSYS',
                  'OLAPSYS','ORACLE_OCM','ORDDATA','ORDPLUGINS','ORDSYS',
                  'OUTLN','SI_INFORMTN_SCHEMA','SPATIAL_CSW_ADMIN_USR',
                  'SYSBACKUP','SYSDG','SYSKM','WMSYS','XDB','XS$NULL',
                  'PERFSTAT','SYSTEM');

PROMPT
PROMPT ------------------------------------------------------------------------|
PROMPT
SPOOL OFF

ed test.log

