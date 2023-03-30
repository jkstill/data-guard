
prompt
prompt Check for Error Conditions
prompt
prompt 'No Rows' == Success
prompt

select sysdate,status,error
 from gv$archive_dest_status
 where type='PHYSICAL'
 and status!='VALID'
 or error is not null
/
