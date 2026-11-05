## 2.1.0

- `statementCacheSize` in `LibPqAsync.connect` and `LibPqAsyncPool`: statements are prepared the first time they run and reused, in a cache by connection, so the server does not parse them again. A statement the server lost (`DEALLOCATE ALL`, `DISCARD ALL`) or whose columns changed is prepared again and run again outside a transaction. Off by default, as a pooler in transaction mode cannot keep prepared statements
- `binary` in `LibPqAsync.connect` and `LibPqAsyncPool`: cached statements return their values in the binary format. The values are the same as in text: a statement with a column it cannot read that way (`inet`, `interval`, `float4`, an enum, `aclitem`...) stays in text, decided before running. `PqAsyncResult.binary` tells which one a result used
- A date `DateTime` cannot represent (`infinity`, `-infinity`, a year past its range) is `null`, as in the other PostgreSQL drivers; it was the server's text, so `as DateTime` failed. The `infinity` setting of `LibPqAsync.connect`, `LibPqAsyncPool` and `LibPq` chooses `PqInfinity.text` or `PqInfinity.exception`
- BC dates are a `DateTime` with the astronomical year (44 BC is the year -43), as in the other PostgreSQL drivers; they were the server's text
- A value that could not be decoded in the middle of a `stream` left the rest of the result unread, which failed the next command

## 2.0.0

### Asynchronous API

- `LibPqAsync`: a connection with its own isolate, so connecting and running queries never block the event loop. `execute` with parameters and a timeout, `stream` (single row mode, with backpressure), `transaction` with `savepoint`, isolation level and read only, `cancel` and `close`
- Values decoded by their type, as the other PostgreSQL drivers do: `int`, `double`, `bool`, `DateTime`, decoded JSON, `Uint8List` and arrays; `numeric` keeps its exact text; `typed: false` keeps the server's text. `PqRow.toColumnMap` and `PqAsyncResult.toColumnMaps`
- Parameters: `null`, `Uint8List` in binary, `List` and `Set` as arrays (`= ANY($1)`), `Map` as JSON and `DateTime` with its offset. `questionMarksToNumbered` converts `?` placeholders
- COPY: `copyRows`, `copyFrom`, `copyTo`, `copyToText`, with backpressure, also inside a transaction
- LISTEN and NOTIFY: `listen`, `notify`, `notifications`, and `notices` for the server's notices, which libpq would print to stderr
- `LibPqAsyncPool`: a pool of those connections for parallel queries, with `acquireTimeout`, `queryTimeout`, `idleTestThreshold`, `maxConnectionAge`, `maxCommandCount`, `sessionStatements` and `onOpen`. A connection returned with a transaction open is closed
- `sessionStatements`, `queryTimeout`, `transactionStatus`, and `Windows1252Codec`

### Breaking

- `PqResult.asMapList()` and `LibPq.execMapList()` return `null` for SQL NULL; it was an empty string, so a NULL could not be told from `''`
- The minimum Dart SDK is 3.6
- On Linux, `libpq.so.5` is searched before `libpq.so`, which usually comes only with the development package
- `LibPq.connInfo` is always `nullptr`: the string is freed after connecting

### Fixed

- `LargeObject.read` never copied what it read: the caller's buffer stayed as it was
- `PqResult.getBoolean` threw on every value: the server sends `t` and `f`
- `PqResult.affectedRows` threw `FormatException` on a command without a count (`CREATE TABLE`, `SET`...); it is now 0
- `PqResult.getValueAsBytes` returned a view of native memory, which was invalid after `dispose()`, and stopped at the first zero byte
- Reading a disposed `PqResult`, or using a disposed `LibPq`, crashed or returned garbage; it now throws `StateError`
- A failed connection left the `PGconn` open
- Memory leaks: the conninfo string, every parameter of `execParams` and the file names of `LargeObject.export` and `import`
- `execParams` encoded the statement and the parameters as UTF-8 whatever `encoding` the connection had, and ignored the `allocator` for some of them
- A `null` result from libpq (a lost connection) was reported as "Result is nullptr" instead of libpq's message
- `LargeObject.write` and `read` read past the buffer when `length` was larger than it; `import` did not detect a failure, `create` ignored one
- `Platform not implemented` on macOS, and a library that could not be loaded gave no hint of what to do

### Added

- `LibPqException`: `sqlState` (`08006` for a lost connection), `severity`, `detail`, `hint`, `constraint`, `table` and `column`
- `PqResult`: `getValue` (`null` for SQL NULL), `getTyped`, `toColumnMaps`, `isNull`, `commandTag` and `getBytea`
- `LibPq.execParams` takes the same parameters as the asynchronous API
- `LibPq`: `copyFrom`, `copyTo` and `takeNotifications`; a `COPY` through `exec` fails and leaves the connection usable
- `LibPq.isConnected`, and `commitTransaction` (`comitTransaction` is deprecated)
- `openLibpq`, the `LIBPQ_PATH` environment variable, and macOS support
- `PqResult.columnTypeName` keeps the names it has already asked for
- Tests, a REST API stress test, CI on PostgreSQL 14 to 18 and on Windows, examples and a full README

## 1.1.0

- implemented a hi level libpq wrapper

## 1.0.0

- Initial version
