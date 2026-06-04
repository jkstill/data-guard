# Oracle 19c Data Guard Configuration Guide

Here is a step-by-step guide for configuring, managing, and recovering a
basic Oracle 19c Data Guard environment on RedHat Linux 8. It covers
initial setup, planned switchover, and manual failover with
reinstatement.

This document does not cover things such as mirroring redo logs. Only
what is is necessary to configure Data Guard is included.

**Assumptions:**

- **OS:** RedHat Linux 8.10
- **Database:** Oracle 19.27 (Legacy Mode, Non-CDB)
- **Storage:** ASM for data files and redo logs

**Primary Database:**

- **Server:** primary-server
- **Database Name:** orcl
- **DB_UNIQUE_NAME:** orcl

**Standby Database:**

- **Server:** standby-server
- **Database Name:** orcl
- **DB_UNIQUE_NAME:** orcldr

Instructions are included for both the traditional SQL based
configuration method, and the Data Guard Broker method.

Please read carefully, as some steps are skipped if DG Broker is used.

## Redo Log Mirroring

The Redo logs on the primary database are on 4kn disks in the +FRA diskgroup.

On the standby, the storage is 512e.  The +FRA diskgroup in the standby database has been created with 4k logical and physical sector sizes so as to be compatible with the 4k sector sizes from the primary database.

This is only of importance for the redo logs.  

Important:  Do NOT create redo logs in the +DATA diskgroup. If the redo logs are to be mirrored, then separate storage should be assigned to create an additional diskgroup, such as +FRA2. The underlying storage must use 4kn sector sizes.

## 1. Initial Data Guard Setup

Establish a physical standby database.

### Primary Database Prerequisites and Configuration

### Verify ARCHIVELOG Mode:

```text
sqlplus / as sysdba`  
archive log list;
```

### If not in ARCHIVELOG mode, enable it:

```text
shutdown immediate
startup mount
alter database archivelog;  
alter database open;
```

### Create BCT file (Block Change Tracking)

`ALTER DATABASE ENABLE BLOCK CHANGE TRACKING USING FILE '+DATA';`

### Enable Force Logging:

For replication to work, FORCE LOGGING must be enabled.

DML operations done with NOLOGGING will then be logged. This is
necessary for all replication products.

`alter database force logging;`

### Configure `tnsnames.ora` (on both servers):

```text
orcl =
(DESCRIPTION =
(ADDRESS = (PROTOCOL = TCP)(HOST = primary-server)(PORT = 1521))
(CONNECT_DATA = (SERVICE_NAME = orcl))
)

orcldr =
(DESCRIPTION =
(ADDRESS = (PROTOCOL = TCP)(HOST = standby-server)(PORT = 1521))
(CONNECT_DATA = (SERVICE_NAME = orcldr))
)
```

### Configure `log_archive_dest_n` Parameters (on primary):

If your choice is to use Data Guard Broker, skip this step. Do not use
any ‘alter system set’ commands.

```sql
alter system set log_archive_config='dg_config=(orcl,orcldr)'
scope=both;

alter system set log_archive_dest_1='LOCATION=USE_DB_RECOVERY_FILE_DEST
VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=orcl' scope=both;

alter system set log_archive_dest_2='SERVICE=orcldr ASYNC NOAFFIRM
VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=orcldr'
scope=both;

alter system set log_archive_dest_state_1=ENABLE scope=both;

alter system set log_archive_dest_state_2=ENABLE scope=both;

alter system set remote_listener='standby-server:1521' scope=both;

alter system set standby_file_management=AUTO scope=both;

alter system set log_archive_format='arch\_%t\_%s\_%r.arc' scope=spfile;

alter system set fal_server='orcldr' scope=both;
```

### Create Standby Redo Logs (SRLs) on primary:

Match the size of the online redo logs and create one more SRL than your Online Redo Log
groups.

Following are some examples.

#### 1G Stanby Redo Logs

```sql
alter database add standby logfile group 4 ('+FRA') size 1G;
alter database add standby logfile group 5 ('+FRA') size 1G;
alter database add standby logfile group 6 ('+FRA') size 1G;
```

#### 200M Standby Redo Logs

```sql
alter database add standby logfile group 31 ('+FRA') size 209715200;
alter database add standby logfile group 32 ('+FRA') size 209715200;
alter database add standby logfile group 33 ('+FRA') size 209715200;
alter database add standby logfile group 34 ('+FRA') size 209715200;
```

### Create a Level 0 Backup of Primary

See [Appendix – RMAN Level Incremental Backup](#appendix-rman-incremental-backup) to create the the Level 0 Incremental Backup.

Once complete, copy the backup files from the primary server.

The assumption is the backups are on the PRD db server at
`/backups/nfs/prd/incremental/`

From the standby server

```text
mkdir -p /mnt/resource/backups/level-0
cd /mnt/resource/backups
rsync -avz -e ssh oracle@10.10.10.10:/backups/nfs/prd/incremental/ backups/level-0/
```

This will take ~ 3 hours.

### Create a Password File if Necessary

orapwd file='\<path_to_password_file>' password='\<password>' entries=10;

The format for the name MUST be "orapw$ORACLE_SID"

Example:

orapwd file=orapw$ORACLE_SID password="WCdb124dm1n!" entries=10 force=y

Copy the password file to the standby server, and rename it to match the local ORACLE_SID

scp \<path_to_password_file>
\<standby_server>:\<path_to_password_file>;

Example:

```text
scp $ORACLE_HOME/dbs/orapw$ORACLE_SID 10.10.10.20:/u01/app/oracle/product/19.0.0/dbhome_1/dbs/orapw<ORACLE_SID_OF_STANDBY>
```

Ensure they are both the same internally by using md5sum on each, and comparing the hash values.

## Standby Database Configuration

### Create PFILE from SPFILE (on primary)

create pfile=’/tmp/initorcldr.ora’ from spfile;

### **Edit PFILE for Standby:** 

Modify the PFILE with the following:

Do NOT specify the controlfile parameter, as it will cause an error when
trying to restore the controlfile

\_disk_sector_size_override=TRUE

DB_UNIQUE_NAME = orcldr

db_file_name_convert='+DATA/orcl','+DATA/orcldr'

log_file_name_convert='+DATA/orcl','+DATA/orcldr'

Ensure that db_file_recovery_dest is not included in the pfile, or the

Copy /tmp/initorcldr.ora to the standby server.

### Start Standby Instance in NOMOUNT:

`export ORACLE_SID=``orcl`

`sqlplus`` / as ``sysdba`

`startup ``nomount pfile``=’/``tmp``/``initorcldr.ora``’;`

### Create Standby Database using RMAN `DUPLICATE`:

Due to the 22ms latency between Primary and Standby servers, the standby
database cannot be created via ‘from active database’.

An incremental level 0 backup must be created on PRD, and those
backup files copied to the Standby database.

Do NOT specify the controlfile parameter, as it will cause an error when
trying to restore the controlfile

The RMAN command used will vary, based on whether or not DG Broker is being used.

#### Using DG Broker

```text
rman auxiliary /

RUN {

ALLOCATE AUXILIARY CHANNEL ch1 DEVICE TYPE DISK;
ALLOCATE AUXILIARY CHANNEL ch2 DEVICE TYPE DISK;
ALLOCATE AUXILIARY CHANNEL ch3 DEVICE TYPE DISK;
ALLOCATE AUXILIARY CHANNEL ch4 DEVICE TYPE DISK;
ALLOCATE AUXILIARY CHANNEL ch5 DEVICE TYPE DISK;
ALLOCATE AUXILIARY CHANNEL ch6 DEVICE TYPE DISK;
ALLOCATE AUXILIARY CHANNEL ch7 DEVICE TYPE DISK;
ALLOCATE AUXILIARY CHANNEL ch8 DEVICE TYPE DISK;

DUPLICATE TARGET DATABASE FOR STANDBY BACKUP LOCATION
'/mnt/resource/backups/level-0'
   NOFILENAMECHECK
   SPFILE
   SET db_unique_name='orcldr'
   SET "_disk_sector_size_override"='TRUE'
   SET db_create_file_dest='+DATA'
   SET db_recovery_file_dest='+FRA'
   SET db_recovery_file_dest_size='200G'
   SET remote_listener='primary-server:1521'
   SET log_archive_dest_state_1='ENABLE'
   SET log_archive_dest_state_2='ENABLE';
}
```

#### Not Using DG Broker

```text
rman auxiliary /

RUN {

ALLOCATE AUXILIARY CHANNEL ch1 DEVICE TYPE DISK;
ALLOCATE AUXILIARY CHANNEL ch2 DEVICE TYPE DISK;
ALLOCATE AUXILIARY CHANNEL ch3 DEVICE TYPE DISK;
ALLOCATE AUXILIARY CHANNEL ch4 DEVICE TYPE DISK;
ALLOCATE AUXILIARY CHANNEL ch5 DEVICE TYPE DISK;
ALLOCATE AUXILIARY CHANNEL ch6 DEVICE TYPE DISK;
ALLOCATE AUXILIARY CHANNEL ch7 DEVICE TYPE DISK;
ALLOCATE AUXILIARY CHANNEL ch8 DEVICE TYPE DISK;

DUPLICATE TARGET DATABASE FOR STANDBY BACKUP LOCATION
'/mnt/resource/backups/level-0'
   NOFILENAMECHECK
   SPFILE
   SET db_unique_name='orcldr'
   SET "_disk_sector_size_override"='TRUE'
   SET db_create_file_dest='+DATA'
   SET db_recovery_file_dest='+FRA'
   SET db_recovery_file_dest_size='200G'
   SET remote_listener='primary-server:1521'
   SET log_archive_config='dg_config=(orcl,orcldr)'
   SET log_archive_dest_1='LOCATION=USE_DB_RECOVERY_FILE_DEST
      VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=orcldr'
   SET log_archive_dest_2='SERVICE=orcl ASYNC
      VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=orcl'
   SET log_archive_dest_state_1='ENABLE'
   SET log_archive_dest_state_2='ENABLE';
}
```

### Create Standby Redo Logs on Standby Database

Check for standby logs:

`select group#, thread#, bytes from v$standby_log;`

Create standby logs as needed.

The standby logs should already exist from the database restore.

```sql
alter database add standby logfile group 4 ('+DATA') size 1G;
alter database add standby logfile group 5 ('+DATA') size 1G;
alter database add standby logfile group 6 ('+DATA') size 1G;
...
```

NOTE: The number and size of standby redo logs must match the primary.

It does not hurt to do this now:

`alter database recover managed standby database using current logfile
disconnect from session;`

### Create Static Listener Entries

Create these entries in listener.ora. This is most likely owned by grid and found at `$ORACLE_HOME/network/admin`


Technically these should not be necessary, but I have had better success when they are available.

Creating static listener entries allows DG Broker to startup the remote database.

Replace the ORACLE_SID placeholder with the ORACLE_SID value of the
database. This is done on both the primary and standby servers.

Check that the value for ORACLE_HOME is correct.

I have found it necessary in a Data Guard config to create static listener entries for both the DGMGRL service and for the instance

For instance, with an ORACLE_SID == orcldr (standby)

```text
SID_LIST_LISTENER =
   (SID_LIST =
      (SID_DESC =
         # This entry allows DGMGRL to connect and start the instance when it is down
         (GLOBAL_DBNAME = orcldr_DGMGRL)
         (ORACLE_HOME = /u01/app/oracle/product/19.0.0/dbhome_1 )
         (SID_NAME = orcldr)
      )
      (SID_DESC =
         # This entry allows DGMGRL to connect and start the instance when it is down
         (GLOBAL_DBNAME = orcldr)
         (ORACLE_HOME = /u01/app/oracle/product/19.0.0/dbhome_1 )
         (SID_NAME = orcldr)
      )
   )
```

Following is the generic template:

```text
SID_LIST_LISTENER =
   (SID_LIST =
      (SID_DESC =
         # This entry allows DGMGRL to connect and start the instance when it is down
         (GLOBAL_DBNAME = ORACLE_SID_DGMGRL)
         (ORACLE_HOME = /u01/app/oracle/product/19.0.0/dbhome_1)
         (SID_NAME = ORACLE_SID)
      )
      (SID_DESC =
         (GLOBAL_DBNAME = ORACLE_SID)
         (ORACLE_HOME = /u01/app/oracle/product/19.0.0/dbhome_1)
         (SID_NAME = ORACLE_SID)
      )
   )
```

## Enable Flashback

On both the primary and standby

### Primary

```sql
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE FLASHBACK ON;
ALTER DATABASE OPEN;
SELECT flashback_on FROM v$database;
```

### Standby

As the standby is open in `mount` mode, there is no need to shut it down.

```sql
ALTER DATABASE FLASHBACK ON;
SELECT flashback_on FROM v$database;
```

# Check Basic Configuration

Ensure the following have all been done

- ssh equivalency
- tnsnames.ora configured on both servers
- Standby database is recovered to be in sync with Primary

# Using DG Broker

## Start the Broker

On both the Primary and Standby Databases

`alter system set dg_broker_start=true scope=both;`

## Configure the Broker

Run on the following steps on the primary.

### Connect to the broker

While it is not technically necessary to use the password to connect to the broker, it may be a good idea to do so anyway, just to ensure the password is correct, that you can connect to the service.

`dgmgrl sys/<password>@orcl`

### Create the configuration

Note: Adjust the name as needed

Name it `orcl_dg_config`

`CREATE CONFIGURATION 'orcl_dg_config' AS PRIMARY DATABASE IS 'orcl' CONNECT IDENTIFIER IS orcl;`

### Add the standby database to the configuration

`ADD DATABASE 'orcldr' AS CONNECT IDENTIFIER IS orcldr;`

### Enable the configuration

`ENABLE CONFIGURATION;`

### Verify it's working


```text
DGMGRL> ENABLE CONFIGURATION;
Enabled.

DGMGRL>
DGMGRL> SHOW DATABASE 'orcldr';
Database - orcldr
Role: PHYSICAL STANDBY
Intended State: APPLY-ON
Transport Lag: 0 seconds (computed 0 seconds ago)
Apply Lag: 0 seconds (computed 0 seconds ago)
Average Apply Rate: 2.07 MByte/s
Real Time Query: OFF

Instance(s):

orcl
Database Status:
SUCCESS

DGMGRL> show configuration
Configuration - orcl_dg_config
Protection Mode: MaxPerformance
Members:

orcl - Primary database
orcldr - Physical standby database

Fast-Start Failover: Disabled

Configuration Status:

SUCCESS (status updated 60 seconds ago)
```

## Switchover – from Primary to Standby

Substitute the correct primary and standby instance names as needed.

### Check the status from the primary

```text
$ dgmgrl sys/’PASSWORD'@$ORACLE_SID

DGMGRL> SHOW CONFIGURATION;
```

The result should be ‘SUCCESS’

### Make sure the lag is 0 seconds at the standby.

```text
DGMGRL> SHOW DATABASE 'orcldr';
Database - orcldr
Role: PHYSICAL STANDBY
Intended State: APPLY-ON
Transport Lag: 0 seconds (computed 0 seconds ago)
Apply Lag: 0 seconds (computed 0 seconds ago)
Average Apply Rate: 46.00 KByte/s
Real Time Query: OFF
Instance(s):

orcl

Database Status:
SUCCESS
```

### Switch to Standby

```text
DGMGRL> SWITCHOVER TO 'orcldr';

Performing switchover NOW, please wait...
Operation requires a connection to database "orcldr"
Connecting ...
Connected to "orcldr"
Connected as SYSDBA.

New primary database "orcldr" is opening...

Oracle Clusterware is restarting database "orcl" ...
Connected to "orcl"
Switchover succeeded, new primary is "orcldr"
```

### Check the Status

The roles are now reversed.

```text
DGMGRL> show configuration

Configuration - orcl_dg_config
Protection Mode: MaxPerformance

Members:
orcldr - Primary database
orcl - Physical standby database

Fast-Start Failover: Disabled

Configuration Status:
SUCCESS (status updated 25 seconds ago)
```

## Switchover – from Standby to Primary

This is much the same as the switch from primary to standby, just reversed

### Check the status from the primary

Remember, the standby is now what was previously the primary.

These commands are performed on the standby server.

```text
$ dgmgrl sys/’PASSWORD'@$ORACLE_SID

Connected to "orcldr"
Connected as SYSDBA.

DGMGRL> show configuration
Configuration - orcl_dg_config
Protection Mode: MaxPerformance

Members:
orcldr - Primary database
orcl - Physical standby database

Fast-Start Failover: Disabled

Configuration Status:
SUCCESS (status updated 5 seconds ago)
```

### Make sure the lag is 0 seconds at the standby.

```text
DGMGRL> show database orcl

Database - orcl
Role: PHYSICAL STANDBY

Intended State: APPLY-ON
Transport Lag: 0 seconds (computed 0 seconds ago)
Apply Lag: 0 seconds (computed 0 seconds ago)
Average Apply Rate: 156.00 KByte/s
Real Time Query: OFF

Instance(s):
orcl

Database Status:
SUCCESS
```

### Switch to Standby (originally the Primary)

These steps are performed from the current primary database, which was originally the standby before switching over.

Please note that switching back to the original primary was partially successful.

The original primary started fine, but there was an issue starting the standby up again.

This was due to not having the static listener entries configured in `grid:OH/network/admin/listener.ora`.
(this has been mentioned elsewhere as not technically required, but it solved this issue.)

The workaround was just as the message shows: logon to the standby database as sysdba, and perform startup mount.

```text
DGMGRL> SWITCHOVER TO 'orcl';

Performing switchover NOW, please wait...
Operation requires a connection to database "orcl"
Connecting ...
Connected to "orcl"
Connected as SYSDBA.

New primary database "orcl" is opening...
Operation requires start up of instance "orcl" on database "orcldr"

Starting instance "orcl"...

Unable to connect to database using
(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=10.10.10.20)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=orcldr_DGMGRL)(INSTANCE_NAME=orcldr)(SERVER=DEDICATED)))

ORA-12514: TNS:listener does not currently know of service requested in
connect descriptor

Failed.

 [W000 2025-09-10T17:16:47.009+00:00 ] Failed to attach to
(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=10.10.10.20)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=orcldr_DGMGRL)(INSTANCE_NAME=orcldr)(SERVER=DEDICATED))).

Please complete the following steps to finish switchover:
start up and mount instance "orcl" of database "orcldr"
Now perform the same status checks as previous

Do this from what is now the primary database.
DGMGRL> show configuration
DGMGRL> show database orcldr
```

### Failover to Standby

In the event the Primary database fails, the following DG Broker commands can be used to failover from the primary to the standby.

On the standby server, logon to DG Broker:

`dgmgrl sys/’PASSWORD'@$ORACLE_SID`

Check the status. You may see output such as this:

```text

DGMGRL> SHOW CONFIGURATION;

Configuration - orcl_dg_config
  Protection Mode: MaxPerformance
  Members:
  orcl  - Primary database
    Error: ORA-16664: unable to receive the result from a member

  orcldr  - Physical standby database
    Warning: ORA-16809: multiple warnings detected for the member

Fast-Start Failover: DISABLED

Configuration Status:
ERROR   (status updated 59 seconds ago)
```

Initiate the Failover command, using the DB_UNIQUE_NAME (same as standby instance name)

```text
DGMGRL> FAILOVER TO orcldr;

Performing failover NOW, please wait...
Failover succeeded, new primary is "orcldr"
```

Check the status:

```text
DGMGRL> SHOW CONFIGURATION;

Configuration - orcl_dg_config
  Protection Mode: MaxPerformance
  Members:
  orcldr  - Primary database
    Success:
  orcl  - Physical standby database (disabled)
    ORA-16661: the standby database needs to be reinstated

Fast-Start Failover: DISABLED

Configuration Status:
SUCCESS   (status updated 10 seconds ago)
```

Recovery steps are similar to what is outlined in the [Using SQL](#using-sql) section.

Further detail for recovery is not in scope for this documentation.

## Using SQL 

### Start Redo Apply on the Standby:

`alter database recover managed standby database using current logfile disconnect from session;`

### Step 1.3: Data Flow Visualization

<img src="images/Data-Guard-Config.svg" alt="Data Guard Flow" style="width:10.28788in;height:5.51545in" >


## Planned Switchover

A switchover is a zero-data-loss role transition for planned maintenance or testing of the DR system.

### Verify Data Guard Status

### Check Redo Transport and Apply Status (on primary):

`select dest_id, process, status, client_process, thread#, sequence# from v$managed_standby;`

`select dest_id, status, error from v$archive_dest where dest_id=2;`

### Verify Switchover Capability (on both)

`select switchover_status from v$database;`

Status should be `TO STANDBY` (on primary) or `SESSIONS ACTIVE` (on standby).

### Perform the Switchover (Primary to Standby)

#### Initiate Switchover from Primary

`alter database commit to switchover to standby with session shutdown;`

#### Activate New Primary (on standby)

`alter database commit to switchover to primary;`

### Start Redo Apply on New Standby (on original primary):

```sql
startup mount;

alter database recover managed standby database using current logfile disconnect from session;
```

## Manual Failover and Reinstatement

This process is for unplanned primary database failures.

### Perform Manual Failover

#### Activate the Standby Database:

sqlplus / as sysdba

alter database activate standby database;

#### Open the New Primary Database:

`alter database open;`

#### Verify role: 

`select ``database_role``, ``open_mode`` from ``v$database``;`

#### **Update** `LOG_ARCHIVE_DEST` **Parameters (on new primary):** Disable the destination to the old, failed primary.

```text
alter system set log_archive_dest_2='' scope=both;

alter system set log_archive_dest_state_2=DEFER scope=both;
```

### Reinstating the Failed Primary

#### Start the Failed Primary in NOMOUNT:

```text
export ORACLE_SID=bpmplpd
sqlplus / as sysdba
startup nomount;
```

#### Attempt RMAN `REINSTATE` (Optional):

```text
rman target sys@\<PRIMARY> auxiliary sys@\<STANDBY>

run { reinstate database; }
```

*Note: This command is sometimes unsuccessful due to a large log gap. If
it fails, proceed to the next step.*

**Manual Reinstatement via RMAN** `DUPLICATE`**:**

> This is the by-the-book method. The original primary (currently
> standby) can also just be caught up to the standby (current primary)
> by applying an incremental level 1 backup or archive logs.
>
> Documenting that process is beyond the scope of this document.

**Clean up the old primary:**

As Oracle:

```text
sqlplus / as sysdba
shutdown immediate;
```

As grid:

```texte
asmcmd
rm -rf +DATA/<PRIMARY_DB_NAME>
```

**Duplicate from the new primary:**

```text
rman target sys@<STANDBY> auxiliary sys@<PRIMARY>

duplicate target database for standby from active database
nofilenamecheck
...
```

  (Use the same `DUPLICATE` command as in the initial setup, ensuring
  the `target` and `auxiliary` connections are reversed).

#### Start Redo Apply on the New Standby:

> alter database recover managed standby database using current logfile
> disconnect from session;

# Appendix - 4kn FRA 

To be compatible with the 4kn storage used for FRA on the wc-prd production server, the FRA on the standby must be created with 4k physical and logical block sizes. 

This is only necessary if the storage is 512e.

If the storage is 4kn, then 4k block sizes will be automatically used by ASM.

Create an FRA2 diskgroup with 4k blocks:

```sql
CREATE DISKGROUP FRA2 EXTERNAL REDUNDANCY DISK '/dev/oracleasm/disks/ASMDISK05', '/dev/oracleasm/disks/ASMDISK06'   ATTRIBUTE 'sector_size'='4096', 'logical_sector_size'='4096';
alter diskgroup FRA2 SET ATTRIBUTE 'compatible.asm' = '19.0.0.0.0';
alter diskgroup FRA2 SET ATTRIBUTE 'compatible.rdbms' = '12.2.0.0.0';
alter diskgroup FRA2 set ATTRIBUTE 'sector_size'='4096';
alter diskgroup FRA2 set ATTRIBUTE 'logical_sector_size'='4096';
```

The is a 4kn disk - both the logical and physical sectors are 4096 bytes.

```text
$ sudo sfdisk -l /dev/oracleasm/disks/FRADISK01
Disk /dev/oracleasm/disks/FRADISK01: 2 TiB, 2199021158400 bytes, 536870400 sectors
Units: sectors of 1 * 4096 = 4096 bytes
Sector size (logical/physical): 4096 bytes / 4096 bytes
I/O size (minimum/optimal): 4096 bytes / 4096 bytes
```

The is a 512n disk - both the logical and physical sectors are 512 bytes.

```text
$  sudo sfdisk -l /dev/sdc
Disk /dev/sdc: 128 GiB, 137438953472 bytes, 268435456 sectors
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
Disklabel type: gpt
```

The is a 512e disk - the logical sector size is 512e, while tthe physical sectors are 4096 bytes.

```text
$ sudo sfdisk -l /dev/oracleasm/disks/ASMDISK05
Disk /dev/oracleasm/disks/ASMDISK05: 1024 GiB, 1099509530624 bytes, 2147479552 sectors
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 4096 bytes
I/O size (minimum/optimal): 4096 bytes / 4096 bytes
```

# Appendix – RMAN Incremental Backups

Examples:

`./ rman-incremental.sh 0`

`./ rman-incremental.sh 1`


Go to the RMAN directory:

`cd /home/oracle/migrate/flsplm/rman`

The following script should be in that directory:

```text
#!/usr/bin/env bash
# ---------------------------
# Oracle RMAN Incremental Backup Script
# ---------------------------

: ${INCREMENTAL_LEVEL:=$1}

echo "INCREMENTAL_LEVEL: $INCREMENTAL_LEVEL"

[[ -z $INCREMENTAL_LEVEL ]] && {
   echo
   echo "usage: INCREMENTAL_LEVEL= [0|1] $0"
   echo
   exit 1
}

[[ $INCREMENTAL_LEVEL =~  [0|1]  ]] || {
   echo
   echo 'INCREMENTAL_LEVEL can only be 0 or 1'
   echo
   exit 2
}

set -u

ORACLE_SID=ORCL # \<-- change to your DB name
ORACLE_HOME=/u01/app/oracle/product/19.3.0/dbhome_1
BACKUP_DIR="/backups/$ORACLE_SID/rman/incremental"
LOG_DIR="$BACKUP_DIR/../logs/"
RMAN_LOG="$LOG_DIR/rman_backup_inc-${INCREMENTAL_LEVEL}\_$(date +%F\_%H-%M-%S).log"

export ORACLE_SID ORACLE_HOME PATH=$ORACLE_HOME/bin:$PATH

mkdir -p "$BACKUP_DIR"
mkdir -p "$LOG_DIR"

echo "BACKUP_DIR: $BACKUP_DIR"
echo "LOG_DIR: $LOG_DIR"
echo "RMAN_LOG: $RMAN_LOG"

#exit

echo "Starting RMAN backup at $(date)"  | tee -a "$RMAN_LOG"

rman target / <<EOF >> "$RMAN_LOG" 2>&1

CONFIGURE CONTROLFILE AUTOBACKUP ON;

CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '${BACKUP_DIR}/%F';

RUN {

ALLOCATE CHANNEL ch1 DEVICE TYPE DISK FORMAT '/backups/${ORACLE_SID}/rman/incremental/%U';
ALLOCATE CHANNEL ch2 DEVICE TYPE DISK FORMAT '/backups/${ORACLE_SID}/rman/incremental/%U';
ALLOCATE CHANNEL ch3 DEVICE TYPE DISK FORMAT '/backups/${ORACLE_SID}/rman/incremental/%U';
ALLOCATE CHANNEL ch4 DEVICE TYPE DISK FORMAT '/backups/${ORACLE_SID}/rman/incremental/%U';

BACKUP AS COMPRESSED BACKUPSET INCREMENTAL LEVEL $INCREMENTAL_LEVEL
SECTION SIZE 10g DATABASE INCLUDE CURRENT CONTROLFILE PLUS ARCHIVELOG ;

# FORMAT '${BACKUP_DIR}/${ORACLE_SID}-incremental-${INCREMENTAL_LEVEL}-%U.bkp';

RELEASE CHANNEL ch1;
RELEASE CHANNEL ch2;
RELEASE CHANNEL ch3;
RELEASE CHANNEL ch4;

}

EOF
```

# SCRATCH

SQL> select status from v$instance;

STATUS

------------

MOUNTED

1\* select database_role from v$database

SQL> /

DATABASE_ROLE

----------------

PHYSICAL STANDBY

No need to convert to physical standby, as the duplicate command did
that

fal_server string eugene

SQL> ALTER SYSTEM SET fal_server=portland scope=both;

System altered.

SQL> ALTER SYSTEM SET fal_client=eugene scope=both;

System altered.

-- Managed recovery in background

ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION;

OR

-- If you want real-time apply:

ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE
DISCONNECT FROM SESSION;

For local listener, set it to use IP rather than name, it is more
reliable

ALTER SYSTEM SET local_listener =

'(ADDRESS=(PROTOCOL=TCP)(HOST=10.10.10.20)(PORT=1521))'

SCOPE=BOTH;
