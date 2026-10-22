# Oracle 26ai Data Guard Physical Standby on a VirtualBox VM — Build Runbook

Oct 21, 2026 · @Jared Still

## Assumptions and names

The build is a single-instance physical standby of an existing single-instance 26ai CDB, created with RMAN active duplicate and managed by the broker, with all redo traffic on a dedicated DG network. Substitute your own values for the placeholders below; every command in this runbook uses them.

| Placeholder | Example | Meaning |
| --- | --- | --- |
| `orcl` | orcl | `DB_NAME` (same on both sides) and the `ORACLE_SID` on both hosts |
| `<PRI_UNQ>` | orcl | Primary `DB_UNIQUE_NAME` (existing; do not change it) |
| `orcl_stby` | orcl\_stby | Standby `DB_UNIQUE_NAME` |
| `dbprim` | ora97-26ai-01 | Primary host |
| `dbstby` | ora97-26ai-02 | Standby VM |
| `192.168.1.129` | 192.168.1.129 | Primary's address on the DG network |
| `192.168.1.131` | 192.168.1.131 | Standby's address on the DG network |
| `1522` | 1522 | DG listener port on both hosts |
| `/u02/oradata` | /u02/oradata | Standby datafile, controlfile and redo destination (OMF) |
| `/u03/fra` | /u03/fra | Standby fast recovery area |

Other assumptions:

- The standby software must be the same release and the same RU as the primary (check with `$ORACLE_HOME/OPatch/opatch lspatches` on the primary).
- 26ai is CDB-only, so the standby covers the whole CDB; all PDBs come across (`STANDBYS=ALL` is the default).
- Standby storage is a plain filesystem with OMF, so file names convert automatically even if the primary is on ASM.
- If `DB_DOMAIN` is set on the primary, append it to every service name below.
- If the primary is RAC, the steps are the same except SRLs are per thread and the primary-side listener and `LOCAL_LISTENER` changes are made per node.

## 1. Build the VM and the DG network

Give the VM two NICs: adapter 1 for management, adapter 2 used only for Data Guard. Adapter 2's virtual cable can then be pulled from the host with `VBoxManage`, which is the most realistic outage you can create.

**DG network.** The VM runs on a separate VirtualBox host, so bridge adapter 2 to a host NIC that reaches the primary. Put the DG traffic on its own subnet (192.168.56.0/24 here): give the primary a dedicated address on that subnet, ideally on a second NIC or VLAN, or as an extra address on an existing NIC if that's all you have. Fault injection works either way, because the outages are created on the VM side (`setlinkstate2`, nft and tc on enp0s8).

```
# on the VirtualBox host: bridge adapter 2 to the NIC facing the DG subnet
VBoxManage list bridgedifs                      # find the host NIC name
VBoxManage modifyvm ora97-26ai-02 --nic2 bridged --bridgeadapter2 <host-nic> --cableconnected2 on

# on ora97-26ai-01: dedicated DG address (second NIC shown; use an existing connection name for an extra address)
nmcli con add type ethernet ifname <dg-nic> con-name dg ipv4.method manual ipv4.addresses 192.168.1.129/24 ipv6.method disabled
nmcli con up dg
```

**VM sizing.** 4 vCPU, 8–16 GB RAM, and disk for the full primary datafile size plus FRA headroom. Give `/u02` and `/u03` their own virtual disks so you can fill or detach them independently later.

**OS prep on ora97-26ai-02.**

1. Install the same Oracle Linux major version as the primary, or another one certified for your 26ai RU.
2. Install the Oracle preinstall RPM for your release (`dnf search preinstall` shows the 23ai/26ai package); it creates the `oracle` user, kernel parameters and limits.
3. Configure enp0s8 (adapter 2) statically as 192.168.1.131/24 with no gateway, then add `192.168.1.129 ora97-26ai-01-dg` and `192.168.1.131 ora97-26ai-02-dg` to `/etc/hosts` on both hosts.
4. Create the directories: `mkdir -p /u01/app/oracle /u02/oradata /u03/fra && chown -R oracle:oinstall /u01 /u02 /u03`.
5. Open port 1522 on enp0s8 (`firewall-cmd --zone=trusted --change-interface=enp0s8 --permanent; firewall-cmd --reload`), or disable firewalld if you plan to drive nftables directly in the fault tests.
6. If the primary uses `use_large_pages=ONLY`, either configure HugePages on the VM or override that parameter in the duplicate (section 5).

**Oracle software, matching RU.** The safest way to get an identical home is a gold image of the primary's home.

```
# on ora97-26ai-01, as oracle
$ORACLE_HOME/runInstaller -silent -createGoldImage -destinationLocation /tmp/goldimg

# on ora97-26ai-02, as oracle: unzip into the same ORACLE_HOME path, then
./runInstaller -silent -ignorePrereqFailure \
  oracle.install.option=INSTALL_DB_SWONLY \
  ORACLE_BASE=/u01/app/oracle UNIX_GROUP_NAME=oinstall \
  INVENTORY_LOCATION=/u01/app/oraInventory \
  oracle.install.db.InstallEdition=EE   # plus the OSDBA/OSOPER/etc. group settings your response file normally uses
# then run root.sh as root
```

Confirm with `opatch lspatches` that both homes report the same patch list before going further.

## 2. Prepare the primary

The primary needs archivelog mode, force logging, an FRA, flashback, standby redo logs and the broker started; leave `LOG_ARCHIVE_DEST_n` and `LOG_ARCHIVE_CONFIG` alone, because the broker sets them. Run everything in `CDB$ROOT` as SYSDBA.

Check the current state first:

```
SELECT log_mode, force_logging, flashback_on, db_unique_name FROM v$database;
SELECT name, value FROM v$parameter
 WHERE name IN ('db_recovery_file_dest','db_recovery_file_dest_size','standby_file_management',
                'dg_broker_start','log_archive_dest_1','db_domain');
```

Enable what is missing (archivelog mode needs a restart):

Note: DGMGRL also has a `PREPARE DATABASE FOR DATA GUARD` command (21c and later) that does most of this section in one step. The manual steps are shown so you can see exactly what changed.

Just do this as of 21c:

```sql
prepare database for data guard with db_unique_name is orcl db_recovery_file_dest is '/u02/app/oracle/fast_recovery_area/'  db_recovery_file_dest_size is 14802M restart;
```

```
SHUTDOWN IMMEDIATE
STARTUP MOUNT
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;

ALTER DATABASE FORCE LOGGING;
ALTER SYSTEM SET db_recovery_file_dest_size = 100G SCOPE=BOTH;
ALTER SYSTEM SET db_recovery_file_dest = '/u03/fra' SCOPE=BOTH;   -- or your existing FRA / +RECO
ALTER DATABASE FLASHBACK ON;            -- needed to reinstate after failover tests
ALTER SYSTEM SET standby_file_management = AUTO SCOPE=BOTH;
```

**Standby redo logs.** Create one more SRL group per thread than there are online groups, all the same size as the online logs.

```
SELECT thread#, COUNT(*) groups, MAX(bytes)/1024/1024 mb FROM v$log GROUP BY thread#;

-- e.g. 3 groups of 1024 MB on thread 1 -> 4 SRLs (OMF; add file names if not OMF)
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 SIZE 1024M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 SIZE 1024M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 SIZE 1024M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 SIZE 1024M;

SELECT group#, thread#, bytes/1024/1024 mb, status FROM v$standby_log;
```

**Broker.** Point the config files at stable locations, then start it:

```
ALTER SYSTEM SET dg_broker_config_file1 = '/u01/app/oracle/product/26.1/dbs/dr1orcl.dat' SCOPE=BOTH;
ALTER SYSTEM SET dg_broker_config_file2 = '/u01/app/oracle/product/26.1/dbs/dr2orcl.dat' SCOPE=BOTH;
ALTER SYSTEM SET dg_broker_start = TRUE SCOPE=BOTH;
```

**RMAN deletion policy**, so the FRA does not purge logs the standby still needs:

```
rman target /
CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY;
```


## 3. Oracle Net on the DG network

Each host gets a `LISTENER_DG` bound only to its DG address on port 1522, with static entries for the `_DGMGRL` service. The standby listener also needs a static entry for the nomount instance. The broker and RMAN connect only through `*_DG` aliases, so redo never touches the public network.

**Primary `listener.ora`** (add alongside the existing listener):

```
LISTENER_DG =
  (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = 192.168.1.129)(PORT = 1522)))

SID_LIST_LISTENER_DG =
  (SID_LIST =
    (SID_DESC = (GLOBAL_DBNAME = orcl_dgmgrl)(ORACLE_HOME = /u01/app/oracle/product/26.1)(SID_NAME = orcl)))
```
Then register the primary dynamically with the DG listener as well, so `SERVICE_NAME=orcl` works there. Keep your existing address first:

```
ALTER SYSTEM SET local_listener =
 '(ADDRESS_LIST=(ADDRESS=(PROTOCOL=TCP)(HOST=ora97-26ai-01)(PORT=1521))(ADDRESS=(PROTOCOL=TCP)(HOST=192.168.1.129)(PORT=1522)))'
 SCOPE=BOTH;
ALTER SYSTEM REGISTER;
```

**Standby `listener.ora`** (on ora97-26ai-02):

```
LISTENER_DG =
  (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = 192.168.1.131)(PORT = 1522)))

SID_LIST_LISTENER_DG =
  (SID_LIST =
    (SID_DESC = (GLOBAL_DBNAME = orcl_stby)(ORACLE_HOME = /u01/app/oracle/product/26.1)(SID_NAME = orcl))
    (SID_DESC = (GLOBAL_DBNAME = orcl_stby_DGMGRL)(ORACLE_HOME = /u01/app/oracle/product/26.1)(SID_NAME = orcl)))
```

Start both with `lsnrctl start LISTENER_DG`.

**`tnsnames.ora`, identical on both hosts:**

```
orcl_PRI_DG =
  (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = 192.168.1.129)(PORT = 1522))
    (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = orcl.jks.com)))

orcl_stby_DG =
  (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = 192.168.1.131)(PORT = 1522))
    (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = orcl_stby)(UR = A)))
```

**Password file.** Copy the primary's password file to the standby so SYS authenticates identically:

```
scp ora97-26ai-01:$ORACLE_HOME/dbs/orapworcl ora97-26ai-02:$ORACLE_HOME/dbs/orapworcl
# primary password file in ASM: asmcmd pwget --dbuniquename <PRI_UNQ>, then asmcmd pwcopy to a local file first
```

Check both directions before going on: `tnsping` each alias, then `sqlplus sys@orcl_PRI_DG as sysdba` from ora97-26ai-02. Test `orcl_stby_DG` after the standby instance is started in section 4.

## 4. Start the standby instance in NOMOUNT

A one-line pfile is enough. RMAN builds the real spfile from the primary's during the duplicate.

```
# on ora97-26ai-02, as oracle
export ORACLE_SID=orcl
mkdir -p /u01/app/oracle/admin/orcl/adump
echo "*.db_name='orcl'" > $ORACLE_HOME/dbs/initorcl.ora

sqlplus / as sysdba
STARTUP NOMOUNT PFILE='$ORACLE_HOME/dbs/initorcl.ora'
```

Check the auxiliary connection from ora97-26ai-01 with `sqlplus sys@orcl_stby_DG as sysdba`. It should connect without error, and \`SELECT status FROM v$instance\` should return STARTED.

Before the duplicate, list the primary's non-default parameters that contain host-specific paths or addresses. Each one must be `SET` or `RESET` in the duplicate command:

```
SELECT name, value FROM v$parameter
 WHERE isdefault = 'FALSE'
   AND (value LIKE '%/%' OR value LIKE '%+%' OR name LIKE '%listener%' OR name LIKE '%large_pages%'
        OR name IN ('sga_target','sga_max_size','pga_aggregate_target','pga_aggregate_limit','memory_target'))
 ORDER BY name;
```

## 5. Create the standby with RMAN active duplicate

Run the duplicate from ora97-26ai-01 over the DG network; no backup or staging space is needed. Expect roughly the time to copy the full CDB across the link.

```
rman target sys@orcl_PRI_DG auxiliary sys@orcl_stby_DG

RUN {
  ALLOCATE CHANNEL p1 DEVICE TYPE DISK;
  ALLOCATE CHANNEL p2 DEVICE TYPE DISK;
  ALLOCATE AUXILIARY CHANNEL a1 DEVICE TYPE DISK;
  ALLOCATE AUXILIARY CHANNEL a2 DEVICE TYPE DISK;
  DUPLICATE TARGET DATABASE FOR STANDBY FROM ACTIVE DATABASE
    SPFILE
      SET db_unique_name             = 'orcl_stby'
      SET db_create_file_dest        = '/u02/app/oracle/oradata'
      SET db_create_online_log_dest_1= '/u02/app/oracle/oradata'
      SET db_recovery_file_dest      = '/u02/app/oracle/fast_recovery_area'
      SET db_recovery_file_dest_size = '50G'
      SET audit_file_dest            = '/u01/app/oracle/admin/orcl/adump'
      SET sga_target                 = '3G'      # size for the VM
      SET pga_aggregate_target       = '1G'
      SET use_large_pages            = 'TRUE'    # if primary is ONLY and VM has no HugePages
      SET dg_broker_start            = 'FALSE'
      SET local_listener             = '(ADDRESS=(PROTOCOL=TCP)(HOST=192.168.1.131)(PORT=1522))'
      RESET control_files
      RESET remote_listener
      RESET dg_broker_config_file1
      RESET dg_broker_config_file2
    NOFILENAMECHECK
    USING COMPRESSED BACKUPSET SECTION SIZE 4G;
}

```

Possible Errors::

If you see this:
   RMAN-05537: DUPLICATE without TARGET connection when auxiliary instance is started with spfile cannot use SPFILE clause

It is most likely due to an spfile having been created on the standby by previous clone attempts.
Just delete the spfile file from $ORACLE_HOME/dbs on the standby and try again.

Notes on the command:

- `RESET control_files` together with `db_create_file_dest` makes the standby controlfile OMF under `/u02/oradata/orcl_stby/`.
- If the primary's datafiles are **not** OMF (fixed filesystem names), add `SET db_file_name_convert='/old/path/','/u02/oradata/orcl_stby/'` and the matching `log_file_name_convert`.
- Add `SET` or `RESET` lines for anything else the parameter query in section 4 showed (`diagnostic_dest`, `utl_file_dir`, wallet paths, `memory_target`).
- Omit `remote_listener` if the primary does not set it. RMAN errors on a `RESET` of an unset parameter in some versions; remove the line if it complains.

When the duplicate finishes, the standby is mounted with an spfile in `$ORACLE_HOME/dbs`. Finish on ora97-26ai-02:

```
-- confirm SRLs came across (they should match the primary's)
SELECT group#, thread#, bytes/1024/1024 mb FROM v$standby_log;
-- if missing: set standby_file_management=MANUAL, add them as on the primary, set back to AUTO

ALTER SYSTEM SET dg_broker_config_file1 = '/u01/app/oracle/dbs/dr1orcl_stby.dat' SCOPE=BOTH;
ALTER SYSTEM SET dg_broker_config_file2 = '/u01/app/oracle/dbs/dr2orcl_stby.dat' SCOPE=BOTH;
ALTER SYSTEM SET dg_broker_start = TRUE SCOPE=BOTH;
ALTER DATABASE FLASHBACK ON;   -- lets you reinstate this side after a failover test
```

Add both instances to standby listener:

```
ALTER SYSTEM SET local_listener =
 '(ADDRESS_LIST=(ADDRESS=(PROTOCOL=TCP)(HOST=ora97-26ai-02.jks.com)(PORT=1521))(ADDRESS=(PROTOCOL=TCP)(HOST=192.168.1.131)(PORT=1522)))'
 SCOPE=BOTH;
ALTER SYSTEM REGISTER;
```

Open the standby read-only only if you have the Active Data Guard license on this test box. Otherwise leave it mounted; the broker starts redo apply either way.

## 6. Configure the Data Guard broker

Create the configuration with the `*_DG` aliases as connect identifiers, and set `StaticConnectIdentifier` explicitly. If you leave it at the default, the broker derives it from `LOCAL_LISTENER`'s first address, which is the primary's public interface.

```
dgmgrl sys@orcl_pri_dg

CREATE CONFIGURATION dgtest AS
  PRIMARY DATABASE IS orcl CONNECT IDENTIFIER IS orcl_pri_dg;

ADD DATABASE orcl_stby AS CONNECT IDENTIFIER IS orcl_stby_dg;

EDIT DATABASE orcl SET PROPERTY StaticConnectIdentifier =
  '(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=192.168.1.129)(PORT=1522))(CONNECT_DATA=(SERVICE_NAME=orcl_dgmgrl)(INSTANCE_NAME=orcl)(SERVER=DEDICATED)))';
EDIT DATABASE orcl_stby SET PROPERTY StaticConnectIdentifier =
  '(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=192.168.1.131)(PORT=1522))(CONNECT_DATA=(SERVICE_NAME=orcl_stby_dgmgrl)(INSTANCE_NAME=orcl)(SERVER=DEDICATED)))';

ENABLE CONFIGURATION;
SHOW CONFIGURATION;
```

The broker now sets `LOG_ARCHIVE_DEST_2`, `LOG_ARCHIVE_CONFIG` and `FAL_SERVER`, and starts redo apply on the standby. The defaults are ASYNC transport and MaxPerformance.

Optional settings that make fault tests more interesting:

```
EDIT DATABASE <PRI_UNQ> SET PROPERTY NetTimeout = 15;     -- seconds before a stalled send is declared failed (default 30)
EDIT DATABASE <PRI_UNQ> SET PROPERTY ReopenSecs = 60;     -- retry interval after a failure (default 300)
-- to test SYNC behaviour:
EDIT DATABASE <PRI_UNQ> SET PROPERTY LogXptMode = 'SYNC';
EDIT DATABASE orcl_stby SET PROPERTY LogXptMode = 'SYNC';
EDIT CONFIGURATION SET PROTECTION MODE AS MaxAvailability;
```

Run a switchover and back once now (`SWITCHOVER TO orcl_stby;`, then `SWITCHOVER TO orcl;`). If the static entries or `StaticConnectIdentifier` are wrong, this is where it fails, and better now than mid-test.

## 7. Verify transport and apply

The build is good when `SHOW CONFIGURATION` reports SUCCESS, both lags stay near zero, and a forced log switch is applied on the standby within seconds.

```
DGMGRL> SHOW CONFIGURATION;
DGMGRL> SHOW DATABASE orcl_stby;
DGMGRL> VALIDATE DATABASE orcl_stby;          -- SRL sizing, flashback, readiness for switchover
DGMGRL> VALIDATE NETWORK CONFIGURATION FOR ALL;

-- primary
ALTER SYSTEM ARCHIVE LOG CURRENT;
SELECT dest_id, status, error, gap_status FROM v$archive_dest_status WHERE status <> 'INACTIVE';

-- standby
SELECT name, value, time_computed FROM v$dataguard_stats;
SELECT name, role, action, thread#, sequence# FROM v$dataguard_process ORDER BY name;
SELECT MAX(sequence#) FROM v$archived_log WHERE applied = 'YES';
```

Views worth building the monitoring scripts around:

| View | Side | What it tells you |
| --- | --- | --- |
| `v$dataguard_stats` | Standby | Transport lag, apply lag, apply finish time, and when each was last computed (a stale `time_computed` is itself a signal) |
| `v$archive_dest_status` | Primary | Per-destination status, last error, `gap_status`, and the archived and applied sequence as the primary sees them |
| `v$archive_dest` | Primary | Destination settings and `fail_date`, `fail_sequence`, `error` |
| `v$dataguard_process` | Both | Transport (TTnn, NSS) and apply (PR00, MRP0, RFS) processes and their current action |
| `v$archive_gap` | Standby | Missing sequence ranges the standby is waiting on |
| `v$standby_log` | Standby | SRL in use, current sequence and last change |
| `v$recovery_progress` | Standby | Apply rate and active apply progress |
| `v$dataguard_status` | Both | Data Guard message log, the closest thing to an alert log feed in SQL |
| `v$database` | Both | `database_role`, `protection_mode`, `protection_level`, `switchover_status` |

In a CDB, query these from `CDB$ROOT`; the Data Guard views are CDB-wide.

## 8. Fault injection for monitoring tests

Each scenario below produces a distinct signature, so your scripts can be checked against each one separately. VirtualBox commands run on the host; `nft` and `tc` run on ora97-26ai-02 against enp0s8.

| Scenario | Inject | Undo | What monitoring should see |
| --- | --- | --- | --- |
| Silent link loss (cable pull) | `VBoxManage controlvm ora97-26ai-02 setlinkstate2 off` | `... setlinkstate2 on` | Transport stalls until `NetTimeout`, dest error (ORA-03135 / ORA-12170 class), transport lag grows, then catch-up via gap resolution |
| Black hole on DG port only | `nft add table inet dgtest; nft add chain inet dgtest in '{ type filter hook input priority -10; }'; nft add rule inet dgtest in tcp dport 1522 drop` | `nft delete table inet dgtest` | Same as cable pull but the VM stays reachable on its management NIC |
| Clean refusal | `lsnrctl stop LISTENER_DG` on ora97-26ai-02 (affects new connections only) | `lsnrctl start LISTENER_DG` | Immediate ORA-12541 on reconnect attempts, no timeout wait |
| Latency, jitter, loss | `tc qdisc add dev enp0s8 root netem delay 150ms 40ms loss 1%` | `tc qdisc del dev enp0s8 root` | Transport lag creeps up under load; under SYNC, primary commit latency rises (`log file sync`, `SYNC Remote Write`) |
| Standby hung but alive | `VBoxManage controlvm ora97-26ai-02 pause` | `... resume` | No errors at first, then timeouts; standby-side stats freeze (`time_computed` goes stale) |
| Standby crash | `VBoxManage controlvm ora97-26ai-02 poweroff` | Start VM, `STARTUP MOUNT` | Dest error, standby unreachable from the broker |
| Apply stopped, transport fine | `EDIT DATABASE orcl_stby SET STATE='APPLY-OFF';` | `SET STATE='APPLY-ON'` | Apply lag grows, transport lag stays near 0 |
| Transport stopped | `EDIT DATABASE <PRI_UNQ> SET STATE='TRANSPORT-OFF';` | `SET STATE='TRANSPORT-ON'` | Transport lag grows; broker shows a warning; gap on resume |
| Archive gap | Transport off, then `ALTER SYSTEM ARCHIVE LOG CURRENT` 5 times | Transport on | `v$archive_gap` rows, FAL fetch activity, `gap_status` changes |
| Standby FRA full | `ALTER SYSTEM SET db_recovery_file_dest_size=<just above used>` on ora97-26ai-02 | Raise it back | RFS errors, ORA-19809 / ORA-19815 class, transport failing from the primary's view |

Notes:

- For a silent drop, use `setlinkstate` or nft `drop`, not `ip link set enp0s8 down` inside the VM. The guest then knows the link is gone, so its own side fails cleanly.
- With firewalld running, a separate nft table at priority -10 runs before firewalld's rules and is removed in one command. Avoid `firewall-cmd --reload` during a test.
- `netem` shapes egress only. On enp0s8 that delays the standby's ACKs and FAL traffic, which is enough to raise RTT for redo transport. For `shaping in the redo direction, apply it to the primary's DG interface` instead.
- Under MaxAvailability, a cable pull also makes the primary stall for up to `NetTimeout` on commit. That is a useful test of whether your scripts see the primary-side impact.

## 9. Snapshots, reset and tear-down

Take a VM snapshot right after section 7 passes. Most broken test states can then be reset in minutes instead of re-duplicating.

```
VBoxManage snapshot ora97-26ai-02 take dg-baseline --description "standby built, SUCCESS"
# reset: shut the standby down, power off, then
VBoxManage snapshot ora97-26ai-02 restore dg-baseline
```

After a restore the standby is behind the primary. It catches up through FAL as long as the primary still has those archived logs. If they have been purged, restore the missing logs to the primary, or re-duplicate.

After a failover test, reinstate the old primary with `REINSTATE DATABASE <PRI_UNQ>;` (flashback must be on). Then switch back with `SWITCHOVER TO <PRI_UNQ>;`.

To remove the standby completely, unwind the primary side first so it stops retrying a dead destination and holding archived logs:

```
DGMGRL> REMOVE CONFIGURATION;          -- or REMOVE DATABASE orcl_stby; to keep the config
-- primary
ALTER SYSTEM SET dg_broker_start = FALSE SCOPE=BOTH;
ALTER SYSTEM RESET log_archive_dest_2 SCOPE=SPFILE;   -- if the broker left it set
ALTER SYSTEM SET log_archive_config = '' SCOPE=BOTH;
-- optional: drop the SRLs and remove the DG address from local_listener
```

Then shut down the standby, delete `/u02/oradata/orcl_stby` and `/u03/fra/orcl_stby`, and remove the spfile and password file from `$ORACLE_HOME/dbs` on ora97-26ai-02. To rebuild, start again at section 4.
