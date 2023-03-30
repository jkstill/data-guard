


prompt
prompt Check for Data Guard Events
prompt
prompt 'No Rows' == Success
prompt

select *
 from v$dataguard_status
 where severity in ('Error','Fatal')
 and timestamp > (sysdate -1)
/
