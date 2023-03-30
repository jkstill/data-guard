#!/usr/bin/env bash

primaryHost=dbserver01

currHost=$(hostname -s)

[[ $currHost != $primaryHost ]] && {
	echo
	echo please run this on the primary host "$primaryHost"
	echo
	exit 1
}

mkdir -p  $(dirname $0)/../logs

cd $(dirname $0)/../sql/primary
pwd


#echo $workDir
# check for a SQL file

[[ -r ./dg-gap-chk.sql ]] || {
	echo
	echo could not read ./dg-gap-chk.sql
	echo 
	exit 2
}

sqlFiles="*.sql"

#echo $sqlFiles

banner () {
	echo 
	echo '#####################################'
	echo "## $@"
	echo '#####################################'
	echo 
}

banner2 () {
	echo 
	echo '====================================='
	echo "== $@"
	echo '====================================='
	echo 
}

for db in ORCL01 ORCL02
do


	. oraenv <<< $db > /dev/null

	logFile="../../logs/dg-primary-${ORACLE_SID}-chk.log"

	banner working on $ORACLE_SID | tee "$logFile"

	echo 
	for script in $sqlFiles
	do
		banner2 running SQL Script $script
		sqlplus -L -S /nolog <<-EOF

			connect / as sysdba

			set echo off term on head on feed on verify off
			set linesize 200 trimspool on 
			set pagesize 100
			ttitle off
			btitle off
		
			@@$script

			exit
		EOF

	done | tee -a "$logFile"
done


