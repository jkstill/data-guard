

prompt
prompt Check for DataGuard Errors
prompt
prompt 'No Rows' == Success
prompt

select *
 from v$dataguard_status
 where severity in ('Error','Fatal')
 and timestamp > (sysdate -1)
/
