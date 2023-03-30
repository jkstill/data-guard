


prompt
prompt Check for Datafile Issues
prompt
prompt 'No Rows' == Success
prompt


select *
 from v$datafile_header
 where status ='OFFLINE'
 or ERROR is not null
/
