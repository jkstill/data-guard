#!/bin/bash
# =============================================================================
# dg-diag-primary.sh — DataGuard Diagnostic Script (PRIMARY NODE)
#
# Covers:
#   - OS/kernel network buffer and TCP settings
#   - NIC ring buffers and interrupt coalescing
#   - Active socket state (Recv-Q / Send-Q)
#   - Oracle SQLNet SDU/TDU configuration
#   - Oracle DataGuard transport statistics and status
#   - LNS process state
#   - Redo generation rate
#   - netstat drop/prune counters
#
# Requirements:
#   - Run as oracle OS user (or any user with sudo)
#   - Oracle env vars set (ORACLE_HOME, ORACLE_SID), or pass SID as $1
#   - sqlplus / as sysdba must work
# =============================================================================

set -auo pipefail

SID="${1:-$ORACLE_SID}"

export PATH="$PATH:/usr/local/bin"
. /usr/local/bin/oraenv -s <<< "${SID}" >/dev/null
unset TWO_TASK
set -u

ORACLE_HOME="${ORACLE_HOME:-$(bash -c 'echo $ORACLE_HOME')}"
SQLPLUS="${ORACLE_HOME}/bin/sqlplus"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
OUTFILE="/tmp/dg_primary_diag_${TIMESTAMP}.txt"

# Redirect all output to file and stdout
exec > >(tee -a "$OUTFILE") 2>&1

line()  { echo ""; echo "═══════════════════════════════════════════════════════════════"; }
hdr()   { line; echo "  $1"; line; }
subhdr(){ echo ""; echo "── $1 ──"; }

echo "DataGuard PRIMARY Diagnostic Report"
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

subhdr "Bandwidth-Delay Product hint (if tc/iproute2 available)"
ip route show 2>/dev/null | head -20 || true

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

subhdr "All ESTABLISHED sockets to/from Oracle listener port (1521 default)"
ss -tnp 2>/dev/null | grep -E ':1521|:1522|oracle' | head -40 || true

# =============================================================================
hdr "5. NIC RING BUFFERS AND INTERRUPT COALESCING"
# =============================================================================

# Priority:
#   1. Explicit override: set DG_IFACE=ethX before running the script
#   2. Derive from DG_DEST_IP (the standby IP) via 'ip route get'
#   3. Fall back to default route interface with a warning
if [[ -n "${DG_IFACE:-}" ]]; then
    IFACE="${DG_IFACE}"
    echo "Interface : ${IFACE}  (from DG_IFACE override)"
elif [[ -n "${DG_DEST_IP:-}" ]]; then
    IFACE=$(ip route get "${DG_DEST_IP}" 2>/dev/null \
            | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' \
            | head -1)
    if [[ -z "${IFACE}" ]]; then
        echo "WARNING: Could not resolve interface for DG_DEST_IP=${DG_DEST_IP}, falling back to default route"
        IFACE=$(ip route show default 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
        IFACE="${IFACE:-eth0}"
    else
        echo "Interface : ${IFACE}  (resolved from DG_DEST_IP=${DG_DEST_IP})"
    fi
else
    IFACE=$(ip route show default 2>/dev/null \
            | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' \
            | head -1)
    IFACE="${IFACE:-eth0}"
    echo "WARNING: Neither DG_IFACE nor DG_DEST_IP set — using default route interface: ${IFACE}"
    echo "         Set DG_DEST_IP=<standby_ip> or DG_IFACE=<iface> for accurate results"
fi

subhdr "Ring buffer sizes (ethtool -g)"
sudo ethtool -g "${IFACE}" 2>/dev/null || echo "ethtool not available or insufficient privileges"

subhdr "Interrupt coalescing (ethtool -c)"
sudo ethtool -c "${IFACE}" 2>/dev/null || echo "ethtool -c not available"

subhdr "NIC driver and firmware info"
sudo ethtool -i "${IFACE}" 2>/dev/null || true

subhdr "NIC statistics — look for rx_dropped, rx_missed, rx_fifo_errors"
sudo ethtool -S "${IFACE}" 2>/dev/null | grep -iE "drop|miss|error|fifo|overflow|discard" | head -30 || true

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
echo "TNS_ADMIN: ${TNS_DB_ADMIN}"

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
hdr "7. ORACLE DATABASE — DATAGUARD TRANSPORT (PRIMARY)"
# =============================================================================

run_sql() {
    "${SQLPLUS}" -S "/ as sysdba" <<-ENDSQL
SET LINESIZE 200
SET PAGESIZE 200
SET TRIMOUT ON
SET TRIMSPOOL ON
$1
EXIT;
ENDSQL
}

subhdr "7a. Database role and protection mode"
run_sql "
SELECT NAME, DB_UNIQUE_NAME, DATABASE_ROLE, PROTECTION_MODE, PROTECTION_LEVEL,
       OPEN_MODE, SWITCHOVER_STATUS
FROM   V\$DATABASE;
"

subhdr "7b. LOG_ARCHIVE_DEST configuration"
run_sql "
-- NOTE: MAX_CONNECTIONS exists in 19c but is no longer meaningful (deprecated)
-- SYNC_STATUS removed in 19c; use TRANSMIT_MODE + AFFIRM instead
SELECT DEST_ID, DEST_NAME, STATUS, BINDING, TARGET, ARCHIVER,
       DESTINATION, DB_UNIQUE_NAME,
       TRANSMIT_MODE, AFFIRM, ASYNC_BLOCKS,
       NET_TIMEOUT, DELAY_MINS, REOPEN_SECS,
       COMPRESSION, VALID_NOW, VALID_ROLE,
       FAIL_DATE, FAILURE_COUNT, ERROR,
       APPLIED_SCN
FROM   V\$ARCHIVE_DEST
WHERE  TARGET = 'STANDBY'
    OR STATUS != 'INACTIVE'
ORDER  BY DEST_ID;
"

subhdr "7c. Archive destination status and error detail"
run_sql "
-- SCHEDULE column does not exist in V\$ARCHIVE_DEST_STATUS
-- 19c adds SYNCHRONIZATION_STATUS, SYNCHRONIZED, GAP_STATUS
SELECT DEST_ID, DEST_NAME, STATUS, TYPE,
       DATABASE_MODE, RECOVERY_MODE, PROTECTION_MODE,
       DESTINATION, DB_UNIQUE_NAME,
       ARCHIVED_THREAD#, ARCHIVED_SEQ#,
       APPLIED_THREAD#,  APPLIED_SEQ#,
       STANDBY_LOGFILE_COUNT, STANDBY_LOGFILE_ACTIVE,
       SYNCHRONIZATION_STATUS, SYNCHRONIZED, GAP_STATUS,
       SRL, ERROR
FROM   V\$ARCHIVE_DEST_STATUS
WHERE  STATUS != 'INACTIVE'
ORDER  BY DEST_ID;
"

subhdr "7d. Redo transport summary (V\$REDO_TRANSPORT_STATISTICS removed in 19c)"
run_sql "
-- V\$REDO_TRANSPORT_STATISTICS does not exist in 19c.
-- Transport throughput and failure detail is available via V\$ARCHIVE_DEST
-- and V\$ARCHIVE_DEST_STATUS combined.
SELECT d.DEST_ID,
       d.DEST_NAME,
       d.TRANSMIT_MODE,
       d.AFFIRM,
       d.FAILURE_COUNT,
       d.FAIL_DATE,
       d.FAIL_SEQUENCE,
       d.ERROR                          AS DEST_ERROR,
       s.ARCHIVED_SEQ#,
       s.APPLIED_SEQ#,
       s.ARCHIVED_SEQ# - s.APPLIED_SEQ# AS UNAPPLIED_LOGS,
       s.GAP_STATUS,
       s.SYNCHRONIZATION_STATUS,
       s.SYNCHRONIZED
FROM   V\$ARCHIVE_DEST        d
JOIN   V\$ARCHIVE_DEST_STATUS s ON s.DEST_ID = d.DEST_ID
WHERE  d.STATUS != 'INACTIVE'
  AND  d.TARGET = 'STANDBY'
ORDER  BY d.DEST_ID;
"

subhdr "7e. LNS process status"
run_sql "
-- RESETLOGS_ID renamed to RESETLOG_ID in 19c
-- DELAY_MINS and BLOCKS not in V\$MANAGED_STANDBY; CLIENT_DBID and GROUP# added
SELECT PROCESS, PID, STATUS,
       CLIENT_PROCESS, CLIENT_PID, CLIENT_DBID,
       GROUP#, THREAD#, SEQUENCE#, BLOCK#,
       RESETLOG_ID
FROM   V\$MANAGED_STANDBY
WHERE  PROCESS LIKE 'LNS%'
   OR  PROCESS LIKE 'LGWR%'
ORDER  BY PROCESS;
"

subhdr "7f. Current redo log state and size"
run_sql "
SELECT L.GROUP#, L.THREAD#, L.SEQUENCE#, L.BYTES/1024/1024 AS SIZE_MB,
       L.BLOCKSIZE, L.ARCHIVED, L.STATUS, L.FIRST_TIME, L.NEXT_TIME
FROM   V\$LOG L
ORDER  BY L.THREAD#, L.SEQUENCE#;
"

subhdr "7g. Redo generation rate (last 30 minutes, per thread)"
run_sql "
SELECT THREAD#,
       ROUND(SUM(BLOCKS * BLOCK_SIZE)/1024/1024, 2)        AS REDO_MB,
       ROUND(SUM(BLOCKS * BLOCK_SIZE)/1024/1024/1800, 4)   AS AVG_MB_PER_SEC,
       COUNT(*)                                             AS LOG_SWITCHES
FROM   V\$ARCHIVED_LOG
WHERE  FIRST_TIME >= SYSDATE - 30/1440
AND    STANDBY_DEST = 'NO'
GROUP  BY THREAD#;
"

subhdr "7h. Dataguard stats (transport lag, apply lag)"
run_sql "
SELECT NAME, VALUE, UNIT, TIME_COMPUTED
FROM   V\$DATAGUARD_STATS
ORDER  BY NAME;
" 2>/dev/null || echo "(V\$DATAGUARD_STATS not available)"

subhdr "7i. DataGuard parameters of interest"
run_sql "
SELECT NAME, VALUE, DESCRIPTION
FROM   V\$PARAMETER
WHERE  NAME IN (
    'log_archive_dest_1','log_archive_dest_2','log_archive_dest_3',
    'log_archive_dest_state_1','log_archive_dest_state_2','log_archive_dest_state_3',
    'log_archive_max_processes',
    'db_recovery_file_dest','db_recovery_file_dest_size',
    'archive_lag_target',
    'standby_file_management',
    'redo_transport_user',
    'db_unique_name'
)
ORDER  BY NAME;
"

subhdr "7j. Recent alert log entries (last 100 lines) — transport errors"
ALERT_LOG=$("${SQLPLUS}" -S "/ as sysdba" <<'ENDSQL'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT VALUE FROM V$DIAG_INFO WHERE NAME = 'Diag Trace';
EXIT;
ENDSQL
)
ALERT_LOG=$(echo "${ALERT_LOG}" | tr -d ' ')
if [[ -d "${ALERT_LOG}" ]]; then
    ALOG="${ALERT_LOG}/alert_${SID}.log"
    if [[ -f "${ALOG}" ]]; then
        echo "Alert log: ${ALOG}"
        tail -200 "${ALOG}" | grep -iE "LNS|RFS|ORA-16|transport|archive|error|GAP|timeout" | tail -40 || \
            echo "(no matching entries in last 200 lines)"
    else
        echo "Alert log not found at: ${ALOG}"
    fi
else
    echo "Could not determine alert log path"
fi

# =============================================================================
hdr "SUMMARY / QUICK REFERENCE"
# =============================================================================
echo ""
echo "Key files checked:"
echo "  sqlnet.ora  : ${TNS_ADMIN}/sqlnet.ora"
echo "  tnsnames.ora: ${TNS_ADMIN}/tnsnames.ora"
echo "  listener.ora: ${TNS_ADMIN}/listener.ora"
echo ""
echo "Recommended SDU value  : 65535  (set in sqlnet.ora AND tnsnames.ora on BOTH nodes)"
echo "Recommended rmem_max   : >= 2x peak redo burst size (measure from 7g above)"
echo "Recommended tcp_rmem   : 'min default max' where max matches rmem_max"
echo ""
echo "Full output saved to: ${OUTFILE}"

