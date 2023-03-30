

prompt
prompt Check for Standby Apply Lag
prompt
prompt 'No Rows' == Success
prompt

select name,value,time_computed,datum_time
 from v$dataguard_stats
 where name='apply lag'
 and value > '+00 00:01:00'
/
