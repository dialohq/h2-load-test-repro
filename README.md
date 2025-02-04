```bash
dune exec bin/client.exe -- --h2
```

```bash
dune exec bin/listen.exe -- --h2
```

Client prints 4 values in CSV format: packet number, time of the whole roundtrip (client -> server -> client), time of request (client -> server), time of response (server -> client)
