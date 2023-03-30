

prompt
prompt Check for Standby Transport Lag
prompt
prompt 'No Rows' == Success
prompt


select name,value,time_computed,datum_time
 from v$dataguard_stats
 where name='transport lag'
 and value > '+00 00:01:00'
/

