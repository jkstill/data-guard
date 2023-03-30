
prompt
prompt Check for Recovery Gaps
prompt
prompt 'No Rows' == Success
prompt

select sysdate,database_mode,recovery_mode, gap_status
 from v$archive_dest_status
 where type='PHYSICAL'
 and gap_status !='NO GAP'
/


