#!/bin/bash
# =============================================================================
# dg-diag-standby.sh — DataGuard Diagnostic Script (STANDBY NODE)
#
# Covers:
#   - OS/kernel network buffer and TCP settings  (same as primary)
#   - NIC ring buffers and interrupt coalescing   (same as primary)
#   - Active socket state (Recv-Q / Send-Q)       (same as primary)
#   - Oracle SQLNet SDU/TDU configuration         (same as primary)
#   - Oracle DataGuard receive/apply status       (standby-safe views only)
#   - RFS process state
#   - MRP / apply lag
#   - Standby redo log (SRL) sizing
#   - netstat drop/prune counters
#
# STANDBY VIEW RESTRICTIONS:
#   Many V$ views are unavailable or empty on a physical standby in mount state.
#   This script only queries views that work reliably on standby:
#     V$DATABASE, V$MANAGED_STANDBY, V$STANDBY_LOG, V$ARCHIVED_LOG,
#     V$DATAGUARD_STATS, V$PARAMETER, V$DIAG_INFO, V$RFS_THREAD,
#     V$ARCHIVE_DEST (local dest only), V$LOG (empty but safe to query)
#
# Requirements:
#   - Run as oracle OS user (or any user with sudo)
#   - Oracle env vars set (ORACLE_HOME, ORACLE_SID), or pass SID as $1
#   - sqlplus / as sysdba must work
# =============================================================================

set -auo pipefail

SID="${1:-$ORACLE_SID}"
ORACLE_HOME="${ORACLE_HOME:-$(bash -c 'echo $ORACLE_HOME')}"
export PATH="$PATH:/usr/local/bin"
. /usr/local/bin/oraenv -s <<< "${SID}" >/dev/null
unset TWO_TASK
set -u

SQLPLUS="${ORACLE_HOME}/bin/sqlplus"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
OUTFILE="/tmp/dg_standby_diag_${TIMESTAMP}.txt"

exec > >(tee -a "$OUTFILE") 2>&1

line()  { echo ""; echo "═══════════════════════════════════════════════════════════════"; }
hdr()   { line; echo "  $1"; line; }
subhdr(){ echo ""; echo "── $1 ──"; }

echo "DataGuard STANDBY Diagnostic Report"
echo "Generated : $(date)"
echo "Hostname  : $(hostname -f)"
echo "ORACLE_SID: ${SID}"
echo "Output    : ${OUTFILE}"

# =============================================================================
hdr "1. KERNEL TCP / SOCKET BUFFER SETTINGS"
# =============================================================================

subhdr "Core socket buffer limits (bytes)"
sysctl net.core.rmem_default net.core.rmem_max \
       net.core.wmem_default net.core.wmem_max \
       net.core.netdev_max_backlog

subhdr "TCP-specific buffer limits (min / default / max bytes)"
sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem

subhdr "TCP features relevant to DataGuard"
sysctl net.ipv4.tcp_window_scaling \
       net.ipv4.tcp_moderate_rcvbuf \
       net.ipv4.tcp_timestamps \
       net.ipv4.tcp_sack \
       net.ipv4.tcp_adv_win_scale 2>/dev/null || true

# =============================================================================
hdr "2. NETSTAT DROP / PRUNE COUNTERS"
# =============================================================================

subhdr "Receive buffer errors and pruned packets"
netstat -s 2>/dev/null | grep -iE "receive buffer|RcvbufErrors|TCPRcvQDrop|pruned|collapsed|overrun" || \
  ss -s 2>/dev/null

subhdr "Full TCP statistics snapshot (key drop fields)"
netstat -s 2>/dev/null | grep -iE "segment|retransmit|reset|listen|drop|fail|error|timeout|window|prune|collapse" || true

# =============================================================================
hdr "3. /proc/net/sockstat — SOCKET MEMORY PRESSURE"
# =============================================================================
cat /proc/net/sockstat
cat /proc/net/sockstat6 2>/dev/null || true

# =============================================================================
hdr "4. ACTIVE ORACLE TNS SOCKETS (Recv-Q / Send-Q)"
# =============================================================================

subhdr "Sockets with non-zero Recv-Q or Send-Q (backlog indicator)"
ss -tnmp 2>/dev/null | awk 'NR==1 || $2>0 || $3>0' | head -40 || \
  netstat -tnp 2>/dev/null | grep -E "ESTABLISHED|Recv" | head -40

subhdr "All ESTABLISHED sockets to/from Oracle listener port"
ss -tnp 2>/dev/null | grep -E ':1521|:1522|oracle' | head -40 || true

# =============================================================================
hdr "5. NIC RING BUFFERS AND INTERRUPT COALESCING"
# =============================================================================

# Priority:
#   1. Explicit override: set DG_IFACE=ethX|bondX|vlanX before running the script
#   2. Derive from DG_DEST_IP via 'ip route get'
#   3. Fall back to default route interface with a warning
#
# Bond/VLAN handling:
#   ethtool ring/coalescing usually must be checked on the physical slave NIC,
#   not on the VLAN interface or bond master. This section resolves:
#      vlan50 -> bond0 -> active/all bond slaves -> physical NIC(s)
#      bond0  -> active/all bond slaves -> physical NIC(s)
#      ethX   -> ethX

resolve_route_iface() {
    local dest="${1:-}"
    local dev=""

    if [[ -n "$dest" ]]; then
        dev=$(ip route get "$dest" 2>/dev/null \
              | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' \
              | head -1)
    fi

    if [[ -z "$dev" ]]; then
        dev=$(ip route show default 2>/dev/null \
              | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' \
              | head -1)
    fi

    echo "${dev:-eth0}"
}

vlan_parent() {
    local dev="$1"
    if [[ -f "/proc/net/vlan/${dev}" ]]; then
        awk -F': ' '/Device:/{print $2; exit}' "/proc/net/vlan/${dev}"
        return
    fi

    # Fallback for systems where /proc/net/vlan is not populated.
    ip -d link show "$dev" 2>/dev/null \
      | awk '/ vlan /{for(i=1;i<=NF;i++) if($i=="link") print $(i+1)}' \
      | head -1
}

bond_slaves() {
    local dev="$1"

    if [[ -f "/sys/class/net/${dev}/bonding/active_slave" ]]; then
        local active
        active=$(cat "/sys/class/net/${dev}/bonding/active_slave" 2>/dev/null || true)
        if [[ -n "$active" && -d "/sys/class/net/${active}" ]]; then
            echo "$active"
            return
        fi
    fi

    if [[ -f "/sys/class/net/${dev}/bonding/slaves" ]]; then
        cat "/sys/class/net/${dev}/bonding/slaves"
    fi
}

resolve_ethtool_ifaces() {
    local input="$1"
    local base="$input"
    local parent=""
    local slaves=""

    # VLAN interface, e.g. vlan50 or bond0.50
    parent=$(vlan_parent "$base" 2>/dev/null || true)
    if [[ -n "$parent" ]]; then
        echo "Layer-3 interface : $input"
        echo "VLAN parent       : $parent"
        base="$parent"
    else
        echo "Layer-3 interface : $input"
    fi

    # Bond master
    if [[ -d "/sys/class/net/${base}/bonding" ]]; then
        echo "Bond master       : $base"
        slaves=$(bond_slaves "$base" 2>/dev/null | xargs echo || true)

        if [[ -n "$slaves" ]]; then
            echo "ethtool interface(s): $slaves"
            printf '%s\n' $slaves
            return
        fi

        echo "WARNING: $base appears to be a bond, but no slave NICs were found"
        echo "$base"
        return
    fi

    # If DG_IFACE was accidentally set to a bond slave, show the master too.
    if [[ -L "/sys/class/net/${base}/master" ]]; then
        echo "Interface master  : $(basename "$(readlink "/sys/class/net/${base}/master")")"
    fi

    echo "ethtool interface(s): $base"
    echo "$base"
}

if [[ -n "${DG_IFACE:-}" ]]; then
    IFACE="${DG_IFACE}"
    echo "Interface source  : DG_IFACE override"
elif [[ -n "${DG_DEST_IP:-}" ]]; then
    IFACE=$(resolve_route_iface "${DG_DEST_IP}")
    echo "Interface source  : resolved from DG_DEST_IP=${DG_DEST_IP}"
else
    IFACE=$(resolve_route_iface "")
    echo "WARNING: Neither DG_IFACE nor DG_DEST_IP set — using default route interface: ${IFACE}"
    echo "         Set DG_DEST_IP=<primary_ip> or DG_IFACE=<iface> for accurate results"
fi

# Capture only real interface names from the resolver output.
RESOLVE_OUT=$(resolve_ethtool_ifaces "${IFACE}")
echo "$RESOLVE_OUT"
ETHTOOL_IFACES=$(echo "$RESOLVE_OUT" | awk '/^ethtool interface\(s\):/{for(i=3;i<=NF;i++) print $i}' | xargs echo)
ETHTOOL_IFACES="${ETHTOOL_IFACES:-$IFACE}"

for ETH_IFACE in $ETHTOOL_IFACES; do
    subhdr "Ring buffer sizes for ${ETH_IFACE} (ethtool -g)"
    sudo ethtool -g "${ETH_IFACE}" 2>/dev/null || echo "ethtool -g not available, unsupported, or insufficient privileges"

    subhdr "Interrupt coalescing for ${ETH_IFACE} (ethtool -c)"
    sudo ethtool -c "${ETH_IFACE}" 2>/dev/null || echo "ethtool -c not available, unsupported, or insufficient privileges"

    subhdr "NIC statistics for ${ETH_IFACE} — drops/errors/fifo/overflow"
    sudo ethtool -S "${ETH_IFACE}" 2>/dev/null | grep -iE "drop|miss|error|fifo|overflow|discard" | head -50 || true
done

# Also show bond health when the L3 interface resolves to a bond.
BOND_CANDIDATE="$(vlan_parent "$IFACE" 2>/dev/null || true)"
BOND_CANDIDATE="${BOND_CANDIDATE:-$IFACE}"
if [[ -d "/sys/class/net/${BOND_CANDIDATE}/bonding" ]]; then
    subhdr "Bond status for ${BOND_CANDIDATE}"
    cat "/proc/net/bonding/${BOND_CANDIDATE}" 2>/dev/null || true
fi

# =============================================================================
hdr "6. ORACLE SQLNET.ORA — SDU / TDU / RECV_BUF_SIZE"
# =============================================================================

TNS_ADMIN="${TNS_ADMIN:-${ORACLE_HOME}/network/admin}"
echo "TNS_ADMIN: ${TNS_ADMIN}"

subhdr "sqlnet.ora"
if [[ -f "${TNS_ADMIN}/sqlnet.ora" ]]; then
    grep -iE "SDU|TDU|RECV_BUF|SEND_BUF|BUFFER|COMPRESSION|EXPIRE_TIME|INBOUND_CONNECT" \
        "${TNS_ADMIN}/sqlnet.ora" || echo "(no matching params found)"
else
    echo "File not found: ${TNS_ADMIN}/sqlnet.ora"
fi


TNS_DB_ADMIN="${TNS_DB_ADMIN:-${ORACLE_HOME}/network/admin}"
echo "TNS_DB_ADMIN: ${TNS_DB_ADMIN}"


subhdr "tnsnames.ora — SDU per connect descriptor"
if [[ -f "${TNS_DB_ADMIN}/tnsnames.ora" ]]; then
    grep -iE "SDU|TDU|RECV_BUF|SEND_BUF" "${TNS_DB_ADMIN}/tnsnames.ora" || \
        echo "(no SDU/TDU overrides found in tnsnames.ora)"
else
    echo "File not found: ${TNS_DB_ADMIN}/tnsnames.ora"
fi

subhdr "listener.ora"
if [[ -f "${TNS_ADMIN}/listener.ora" ]]; then
    grep -iE "SDU|TDU|RECV_BUF|SEND_BUF|HOST|PORT" "${TNS_ADMIN}/listener.ora" | head -20
else
    echo "File not found: ${TNS_ADMIN}/listener.ora"
fi

# =============================================================================
hdr "7. ORACLE DATABASE — DATAGUARD RECEIVE/APPLY (STANDBY)"
# =============================================================================

run_sql() {
    "${SQLPLUS}" -S "/ as sysdba" <<-ENDSQL
SET LINESIZE 220
SET PAGESIZE 200
SET TRIMOUT ON
SET TRIMSPOOL ON
$1
EXIT;
ENDSQL
}

subhdr "7a. Database role, open mode, protection mode"
run_sql "
SELECT NAME, DB_UNIQUE_NAME, DATABASE_ROLE, OPEN_MODE,
       PROTECTION_MODE, PROTECTION_LEVEL,
       SWITCHOVER_STATUS, DATAGUARD_BROKER, GUARD_STATUS
FROM   V\$DATABASE;
"

subhdr "7b. Managed standby process state (RFS, MRP, LSP)"
run_sql "
-- BLOCKS, DELAY_MINS, KNOWN_AGENTS, ACTIVE_AGENTS not in 19c V\$MANAGED_STANDBY
-- CLIENT_DBID, GROUP#, RESETLOG_ID added in 19c
SELECT PROCESS, PID, STATUS,
       CLIENT_PROCESS, CLIENT_PID, CLIENT_DBID,
       GROUP#, THREAD#, SEQUENCE#, BLOCK#,
       RESETLOG_ID
FROM   V\$MANAGED_STANDBY
ORDER  BY PROCESS, SEQUENCE#;
"

subhdr "7c. RFS thread detail"
run_sql "
SELECT THREAD#, STATUS, SEQUENCE#, BLOCKS,
       CON_ID
FROM   V\$RFS_THREAD
ORDER  BY THREAD#;
" 2>/dev/null || echo "(V\$RFS_THREAD not available on this version)"

subhdr "7d. Standby redo log (SRL) inventory and status"
run_sql "
SELECT GROUP#, THREAD#, SEQUENCE#,
       BYTES/1024/1024 AS SIZE_MB,
       BLOCKSIZE, USED, ARCHIVED, STATUS,
       FIRST_TIME, LAST_TIME
FROM   V\$STANDBY_LOG
ORDER  BY THREAD#, GROUP#;
"

subhdr "7e. SRL adequacy check (count vs online redo log groups per thread)"
run_sql "
-- Rule of thumb: SRL count >= (online redo groups per thread) + 1, per thread
SELECT 'Online redo groups' AS TYPE, THREAD#, COUNT(*) AS CNT
FROM   V\$LOG
GROUP  BY THREAD#
UNION ALL
SELECT 'Standby redo logs'  AS TYPE, THREAD#, COUNT(*) AS CNT
FROM   V\$STANDBY_LOG
GROUP  BY THREAD#
ORDER  BY THREAD#, TYPE;
"

subhdr "7f. DataGuard stats (transport lag, apply lag)"
run_sql "
SELECT NAME, VALUE, UNIT, TIME_COMPUTED
FROM   V\$DATAGUARD_STATS
ORDER  BY NAME;
" 2>/dev/null || echo "(V\$DATAGUARD_STATS not available)"

subhdr "7g. Recently received archived logs (last 30 min)"
run_sql "
SELECT THREAD#, SEQUENCE#, BLOCKS, BLOCK_SIZE,
       BLOCKS*BLOCK_SIZE/1024/1024  AS SIZE_MB,
       FIRST_TIME, NEXT_TIME,
       COMPLETION_TIME, APPLIED, REGISTRAR, STANDBY_DEST
FROM   V\$ARCHIVED_LOG
WHERE  REGISTRAR = 'RFS'
AND    COMPLETION_TIME >= SYSDATE - 30/1440
ORDER  BY THREAD#, SEQUENCE#;
"

subhdr "7h. Gap detection — sequences received vs applied"
run_sql "
SELECT THREAD#,
       MAX(SEQUENCE#) AS MAX_RECEIVED,
       (SELECT MAX(SEQUENCE#) FROM V\$ARCHIVED_LOG a2
        WHERE  a2.THREAD# = a.THREAD# AND a2.APPLIED = 'YES'
        AND    a2.REGISTRAR = 'RFS') AS MAX_APPLIED,
       MAX(SEQUENCE#) -
       (SELECT MAX(SEQUENCE#) FROM V\$ARCHIVED_LOG a2
        WHERE  a2.THREAD# = a.THREAD# AND a2.APPLIED = 'YES'
        AND    a2.REGISTRAR = 'RFS')  AS GAP
FROM   V\$ARCHIVED_LOG a
WHERE  REGISTRAR = 'RFS'
GROUP  BY THREAD#;
"

subhdr "7i. Local archive dest status (standby-side)"
run_sql "
-- TARGET, ARCHIVER, SCHEDULE do not exist in V\$ARCHIVE_DEST_STATUS
-- Use TYPE and RECOVERY_MODE instead
SELECT DEST_ID, DEST_NAME, STATUS, TYPE,
       DATABASE_MODE, RECOVERY_MODE,
       DESTINATION, DB_UNIQUE_NAME,
       ARCHIVED_THREAD#, ARCHIVED_SEQ#,
       APPLIED_THREAD#,  APPLIED_SEQ#,
       SYNCHRONIZATION_STATUS, SYNCHRONIZED, GAP_STATUS,
       SRL, ERROR
FROM   V\$ARCHIVE_DEST_STATUS
WHERE  STATUS != 'INACTIVE'
ORDER  BY DEST_ID;
"

subhdr "7j. DB recovery file dest usage"
run_sql "
SELECT NAME, SPACE_LIMIT/1024/1024/1024   AS LIMIT_GB,
       SPACE_USED/1024/1024/1024           AS USED_GB,
       SPACE_RECLAIMABLE/1024/1024/1024    AS RECLAIMABLE_GB,
       NUMBER_OF_FILES
FROM   V\$RECOVERY_FILE_DEST;
" 2>/dev/null || echo "(V\$RECOVERY_FILE_DEST not available)"

subhdr "7k. Key DataGuard parameters"
run_sql "
SELECT NAME, VALUE
FROM   V\$PARAMETER
WHERE  NAME IN (
    'db_unique_name',
    'log_archive_dest_1',
    'log_archive_dest_state_1',
    'log_archive_max_processes',
    'db_recovery_file_dest',
    'db_recovery_file_dest_size',
    'standby_file_management',
    'fal_server','fal_client',
    'archive_lag_target'
)
ORDER  BY NAME;
"

subhdr "7l. Recent alert log entries — RFS/MRP/gap/error lines"
DIAG_TRACE=$("${SQLPLUS}" -S "/ as sysdba" <<'ENDSQL'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT VALUE FROM V$DIAG_INFO WHERE NAME = 'Diag Trace';
EXIT;
ENDSQL
)
DIAG_TRACE=$(echo "${DIAG_TRACE}" | tr -d ' ')
if [[ -d "${DIAG_TRACE}" ]]; then
    ALOG="${DIAG_TRACE}/alert_${SID}.log"
    if [[ -f "${ALOG}" ]]; then
        echo "Alert log: ${ALOG}"
        tail -200 "${ALOG}" | grep -iE "RFS|MRP|ORA-16|ORA-00|transport|archive|GAP|error|timeout|disconnect" | tail -40 || \
            echo "(no matching entries in last 200 lines)"
    else
        echo "Alert log not found at: ${ALOG}"
    fi
else
    echo "Could not determine diag trace path"
fi

# =============================================================================
hdr "8. DISK I/O THROUGHPUT ON ARCHIVE DEST (spot check)"
# =============================================================================

subhdr "df — archive / FRA mount point space"
df -h 2>/dev/null | grep -iE "arch|fra|redo|oracle|db" | head -20 || df -h | tail -20

subhdr "iostat — 3 x 5-second samples on all block devices"
iostat -xdm 5 3 2>/dev/null | grep -v "^$" || \
  vmstat -d 2>/dev/null | head -30 || \
  echo "iostat not available"

# =============================================================================
hdr "SUMMARY / QUICK REFERENCE"
# =============================================================================
echo ""
echo "Key files checked:"
echo "  sqlnet.ora  : ${TNS_ADMIN}/sqlnet.ora"
echo "  tnsnames.ora: ${TNS_ADMIN}/tnsnames.ora"
echo "  listener.ora: ${TNS_ADMIN}/listener.ora"
echo ""
echo "Standby-specific checklist:"
echo "  SRL count     : should be >= (online redo groups per thread) + 1, per thread (see 7e)"
echo "  Apply lag     : review 7f — if growing, MRP or disk I/O is the bottleneck"
echo "  Transport lag : review 7f — if growing while apply lag is 0, network is bottleneck"
echo "  RFS state     : should show IDLE or RECEIVING (see 7b) — WAIT* states indicate stall"
echo "  Recv-Q        : non-zero on Oracle sockets (see section 4) confirms kernel buffer pressure"
echo "  SDU           : must match primary sqlnet.ora value (65535 recommended)"
echo ""
echo "Full output saved to: ${OUTFILE}"

