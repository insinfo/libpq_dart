## 2.0.0

### Asynchronous API

- `LibPqAsync`: a connection with its own isolate, so connecting and running queries never block the event loop. `execute` with parameters and a timeout, `stream` (single row mode, with backpressure), `transaction`, `cancel` and `close`
- `LibPqAsyncPool`: a pool of those connections, for parallel queries

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

- `LibPqException`: `sqlState`, `severity`, `detail` and `hint`
- `PqResult`: `getValue` (`null` for SQL NULL), `isNull`, `commandTag` and `getBytea`
- `LibPq.execParams` takes `null`, `Uint8List` (binary), `DateTime` and any other value through `toString()`
- `LibPq.isConnected`, and `commitTransaction` (`comitTransaction` is deprecated)
- `openLibpq`, the `LIBPQ_PATH` environment variable, and macOS support
- `PqResult.columnTypeName` keeps the names it has already asked for
- Tests, CI on PostgreSQL 14 to 18 and on Windows, examples and a full README

## 1.1.0

- implemented a hi level libpq wrapper

## 1.0.0

- Initial version
