# CEMT Reference

Runtime checks used to confirm resources are actually enabled and reachable
after installing them via CEDA.

## URIMAPs

```
CEMT INQUIRE URIMAP(RELSMGR1)
CEMT INQUIRE URIMAP(PROMGR1)
CEMT INQUIRE URIMAP(EVTMGR1)
CEMT INQUIRE URIMAP(CLASHRDR)
```

All should show `Ena`. If one shows `Dis`:

```
CEMT SET URIMAP(RELSMGR1) ENABLED
```

## DB2 connection

```
CEMT INQUIRE DB2CONN
```

Should show `Connectst(Connected)`. If `Notconnected`, this is the most
common cause of everything suddenly failing with abend `AEY9`:

```
CEMT SET DB2CONN CONNECTED
```

## DB2ENTRY

```
CEMT INQUIRE DB2ENTRY(CSMID)
```

Confirms `TRANSID(CWBA)`, `AUTHID(Z73460)`, `PLAN(Z73460)`.
