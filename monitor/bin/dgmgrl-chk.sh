#!/usr/bin/env bash


cd $(dirname $0)/..
pwd

mkdir -p logs

for instance in ORCL01 ORCL02
do
	echo 
	echo '###############################################'
	echo "## $instance"
	echo '###############################################'
	echo

	. /usr/local/bin/oraenv <<< $instance

	dgmgrl / as sysdba <<-EODG | tee logs/dg-check-$instance.log
	
		spool logs/dg-check-$instance.log

		SHOW CONFIGURATION VERBOSE

		VALIDATE NETWORK CONFIGURATION FOR ALL

		VALIDATE DATABASE VERBOSE $instance

		VALIDATE DATABASE VERBOSE $instance SPFILE

		VALIDATE STATIC CONNECT IDENTIFIER FOR ALL 

		EXIT

	EODG

	sqlplus -L -S /nolog <<-EOS | tee logs/dg-parameters-$instance.log

		connect / as sysdba
		set tab off
		@getparm log_archive_dest
		@getparm dg
		@getparm %guard
		exit

	EOS

done
