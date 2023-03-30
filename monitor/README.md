
# Basic DG monitoring based on SQL from Oracle Docs

[/monitor-oracle-data-guard-configuration](https://docs.oracle.com/en/database/oracle/oracle-database/19/haovw/monitor-oracle-data-guard-configuration.html#GUID-41809D11-DDB1-4018-B300-221334CCC911)


## Primary

### DG Broker Check

Run `./bin/dgmgrl-chk.sh`

Output will be saved in the logs directory:

```text
./logs/dg-check-ORCL02.log
./logs/dg-check-ORCL01.log
./logs/dg-parameters-ORCL01.log
./logs/dg-parameters-ORCL02.log
```

### Error and Status Checks

SQL Scripts are found in `sql/primary`

Run `./bin/dg-primary-chk.sh`

Output will be saved in the logs directory:

```text
./logs/dg-primary-ORCL01-chk.log
./logs/dg-primary-ORCL02-chk.log
```

## Standby

### Error and Status Checks

Run `./bin/dg-standby-chk.sh`


Output will be saved in the logs directory:

```text
./logs/dg-standby-ORCL01-chk.log
./logs/dg-standby-ORCL02-chk.log
```

