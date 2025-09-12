# Oracle Data Guard CLI (dgmgrl) Cheat Sheet

## Connection and Session Management

### Connect to Data Guard Broker
```bash
dgmgrl sys/password@primary_db
dgmgrl / as sysdba
```

### Exit
```
EXIT
QUIT
```

## Configuration Management

### Show Configuration
```
SHOW CONFIGURATION [VERBOSE]
```
Display current Data Guard configuration and status

### Create Configuration
```
CREATE CONFIGURATION config_name AS 
PRIMARY DATABASE IS database_name 
CONNECT IDENTIFIER IS connect_string;
```
Create new Data Guard configuration

### Add Database
```
ADD DATABASE database_name AS 
CONNECT IDENTIFIER IS connect_string 
MAINTAINED AS PHYSICAL;
```
Add standby database to configuration

### Remove Database
```
REMOVE DATABASE database_name [PRESERVE DESTINATIONS];
```
Remove database from configuration

### Enable/Disable Configuration
```
ENABLE CONFIGURATION;
DISABLE CONFIGURATION;
```
Enable or disable entire configuration

## Database Operations

### Enable/Disable Database
```
ENABLE DATABASE database_name;
DISABLE DATABASE database_name;
```
Enable or disable specific database

### Switchover
```
SWITCHOVER TO database_name;
```
Perform planned role change between primary and standby

### Failover
```
FAILOVER TO database_name [IMMEDIATE];
```
Perform emergency role change to standby database

### Reinstate Database
```
REINSTATE DATABASE database_name;
```
Reinstate failed primary as new standby after failover

### Convert Database
```
CONVERT DATABASE database_name TO SNAPSHOT STANDBY;
CONVERT DATABASE database_name TO PHYSICAL STANDBY;
```
Convert between physical standby and snapshot standby

## Monitoring and Status

### Show Database
```
SHOW DATABASE database_name;
SHOW DATABASE VERBOSE database_name;
```
Display database status and properties

### Show Database Status
```
SHOW DATABASE database_name 'StatusReport';
SHOW DATABASE database_name 'InconsistentProperties';
SHOW DATABASE database_name 'InconsistentLogXptProps';
```
Show specific status reports

### Monitor Operations
```
SHOW DATABASE database_name 'LogXptStatus';
SHOW DATABASE database_name 'RecvQEntries';
SHOW DATABASE database_name 'SendQEntries';
```
Monitor log transport and apply services

## Property Management

### Show Properties
```
SHOW DATABASE database_name property_name;
SHOW CONFIGURATION property_name;
```
Display specific property values

### Edit Properties
```
EDIT DATABASE database_name SET PROPERTY property_name = value;
EDIT CONFIGURATION SET PROPERTY property_name = value;
```
Modify database or configuration properties

### Common Properties
- `LogXptMode` - Log transport mode (SYNC, ASYNC, FASTSYNC)
- `LogShipping` - Enable/disable log shipping (ON, OFF)
- `ApplyInstanceTimeout` - Apply instance timeout value
- `NetTimeout` - Network timeout for connections
- `LogArchiveTrace` - Log archive tracing level
- `LogArchiveFormat` - Archive log file format
- `StandbyFileManagement` - Automatic file management (AUTO, MANUAL)

## Validation and Health Checks

### Validate Configuration
```
VALIDATE CONFIGURATION [VERBOSE];
```
Check configuration for issues

### Validate Database
```
VALIDATE DATABASE database_name [VERBOSE];
```
Check specific database for issues

### Validate Network
```
VALIDATE NETWORK CONFIGURATION [FOR ALL] [VERBOSE];
```
Test network connectivity between databases

## Fast-Start Failover

### Enable Fast-Start Failover
```
ENABLE FAST_START FAILOVER;
```
Enable automatic failover capability

### Disable Fast-Start Failover
```
DISABLE FAST_START FAILOVER;
```
Disable automatic failover

### Start/Stop Observer
```
START OBSERVER [FILE IS 'observer_config_file'];
STOP OBSERVER;
```
Control Data Guard Observer process

### Show Fast-Start Failover
```
SHOW FAST_START FAILOVER;
```
Display fast-start failover configuration and status

## Log Management

### Show Log Apply Services
```
SHOW DATABASE database_name 'LogXptStatus';
SHOW DATABASE database_name 'ApplyLag';
SHOW DATABASE database_name 'TransportLag';
```
Monitor log apply and transport lag

### Start/Stop Log Apply
```
EDIT DATABASE database_name SET STATE = 'APPLY-ON';
EDIT DATABASE database_name SET STATE = 'APPLY-OFF';
```
Control log apply services on standby

## Utilities and Maintenance

### Help
```
HELP [command_name];
```
Display help for commands

### Show Version
```
SHOW VERSION;
```
Display Data Guard Broker version

### Set Echo
```
SET ECHO ON|OFF;
```
Control command echo in scripts

### Set Time
```
SET TIME ON|OFF;
```
Show timestamps with command output

## Common Administrative Tasks

### Check Database Status
```
SHOW CONFIGURATION VERBOSE;
VALIDATE DATABASE primary_db_name VERBOSE;
VALIDATE DATABASE standby_db_name VERBOSE;
```

### Monitor Lag
```
SHOW DATABASE standby_db_name 'ApplyLag';
SHOW DATABASE standby_db_name 'TransportLag';
```

### Planned Switchover Steps
```
VALIDATE DATABASE primary_db_name;
VALIDATE DATABASE standby_db_name;
SWITCHOVER TO standby_db_name;
```

### Emergency Failover Steps
```
VALIDATE DATABASE standby_db_name;
FAILOVER TO standby_db_name IMMEDIATE;
REINSTATE DATABASE old_primary_db_name;
```

## Script Mode

### Run in Batch Mode
```bash
dgmgrl sys/password@primary_db < script.dgmgrl
dgmgrl -silent sys/password@primary_db "SHOW CONFIGURATION"
```

### Common Script Commands
```
SET ECHO ON;
SET TIME ON;
CONNECT sys/password@primary_db;
SHOW CONFIGURATION VERBOSE;
EXIT;
```

## Exit Codes

- `0` - Success
- `1` - Warning
- `2` - Error
- `3` - Fatal error

---

*Note: Replace `database_name`, `config_name`, `connect_string`, and other placeholders with your actual values.*