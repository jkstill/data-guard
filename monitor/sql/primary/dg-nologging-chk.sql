
prompt
prompt Check for No Logging Operations
prompt
prompt 'No Rows' ==  Success!
prompt

select file#, name, unrecoverable_change#, unrecoverable_time
 from v$datafile
 where unrecoverable_time > (sysdate - 1)
/
