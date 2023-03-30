


prompt
prompt Check for MRP (Managed Recovery Process)
prompt
prompt Rows Returned == Success
prompt

select 
	process, pid, status 
	, block#, blocks, delay_mins
from v$managed_standby where process like 'MRP%'
/
