# libpq_dart

[![CI](https://github.com/insinfo/libpq_dart/actions/workflows/dart.yml/badge.svg)](https://github.com/insinfo/libpq_dart/actions/workflows/dart.yml)
[![Pub Package](https://img.shields.io/pub/v/libpq_dart.svg)](https://pub.dev/packages/libpq_dart)

PostgreSQL client for Dart over [libpq](https://www.postgresql.org/docs/current/libpq.html), the official C library, through FFI.

| API | Use it for | The event loop while it runs |
| --- | --- | --- |
| `LibPqAsync`, `LibPqAsyncPool` | servers, anything that must stay responsive | keeps running |
| `LibPq`, `PqResult`, `LargeObject` | scripts and command-line tools | blocked |
| `LibpqBindings` | direct access to every libpq function | blocked by the blocking functions |

## Install

```yaml
dependencies:
  libpq_dart: ^2.0.0
```

The package does not ship the library: libpq must be installed.

| System | Package | Name searched |
| --- | --- | --- |
| Debian, Ubuntu | `apt install libpq5` | `libpq.so.5`, `libpq.so` |
| Fedora, RHEL | `dnf install libpq` | `libpq.so.5`, `libpq.so` |
| macOS | `brew install libpq` | `libpq.5.dylib`, `libpq.dylib`, Homebrew's folders |
| Windows | PostgreSQL's `bin` folder in `PATH` | `libpq.dll` |

To choose a file, set the `LIBPQ_PATH` environment variable, or pass `libraryPath` (`LibPqAsync`) or `dllPath` (`LibPq`). On Windows, `libpq.dll` needs its dependencies (`libssl`, `libcrypto`, `libintl`...) in the same search path.

## Asynchronous API

```dart
import 'package:libpq_dart/libpq_dart.dart';

final db = await LibPqAsync.connect(
    'host=localhost dbname=app user=app password=secret');

final result = await db.execute(
    r'select id, name from users where id = $1',
    params: [1]);
print(result.first['name']);

await db.close();
```

### How it works

libpq blocks the thread that calls it, and Dart has no way to watch libpq's socket without native code. So each connection has **its own isolate**, where the blocking calls happen. Your isolate only exchanges messages with it: connecting, running a query and decoding the rows all happen outside your event loop, so timers and HTTP requests keep running.

- Commands on one connection run one at a time, in the order they are called. For parallel queries, use several connections or the pool.
- An idle connection does not keep the process running, but call `close()`: it is what closes the session on the server.

### Results

`execute` returns a `PqAsyncResult`, already in Dart memory, with nothing to dispose. Values are the **server's text**; SQL NULL is `null`.

```dart
final r = await db.execute('select 1 as a, null as b');
r.columns;      // ['a', 'b']
r.columnTypes;  // type oids
r.rows;         // [['1', null]]
r.first['a'];   // '1'
r.toMaps();     // [{'a': '1', 'b': null}]
r.commandTag;   // 'SELECT 1'
r.affectedRows; // 1
```

### Parameters

They are numbered `$1`, `$2`... and never read as SQL. `null` is SQL NULL, a `Uint8List` goes in binary, a `DateTime` in ISO 8601, and any other value is its `toString()`, for the server to convert.

```dart
await db.execute(r'insert into files (name, body) values ($1, $2)',
    params: ['a.png', bytes]);
final row = (await db.execute('select body from files')).first;
final Uint8List? body = row.bytea('body');
```

Without parameters a statement goes through the simple protocol, so a script with several statements runs whole and returns its last result.

### Large results

`stream` reads rows as they arrive, without holding the whole result in memory. Pausing the stream stops the reading, and cancelling it cancels the query. Other commands on the connection wait until it ends.

```dart
await for (final row in db.stream('select * from huge_table')) {
  process(row['id']);
}
```

### Transactions

`BEGIN` before the callback, `COMMIT` after it, `ROLLBACK` if it throws. Commands from other callers wait until it ends. Inside the callback, use the session it receives: using the connection there fails at once instead of deadlocking.

```dart
final id = await db.transaction((tx) async {
  await tx.execute(r'update accounts set balance = balance - $1 where id = 1',
      params: [100]);
  final r = await tx.execute('select balance from accounts where id = 1');
  return r.first['balance'];
});
```

If a statement failed and the callback caught the error, the commit fails with SQLSTATE `25P02`: PostgreSQL has already rolled the transaction back.

### Timeouts and cancelling

```dart
await db.execute('select slow()', timeout: Duration(seconds: 5)); // TimeoutException
await db.cancel(); // the running command fails with SQLSTATE 57014
```

A timeout asks the server to cancel the query, and the connection stays usable. `connectTimeout` (15 s) applies when the conninfo has no `connect_timeout`. `close(timeout:)` does not wait forever for a command that does not end.

### Pool

Each connection of the pool has its own isolate, so queries run in parallel. Connections open when needed, up to `maxConnections`, and a lost one is replaced.

```dart
final pool = LibPqAsyncPool(conninfo, maxConnections: 8);
final results = await Future.wait([
  pool.execute('select 1'),
  pool.execute('select 2'),
]);
await pool.transaction((tx) async { /* ... */ });
await pool.withConnection((db) async { /* ... */ });
await pool.close();
```

### Errors

`LibPqException` has `message`, `sqlState` (`23505`, `42P01`...), `severity`, `detail`, `hint` and `sql`. When the server closes the connection, the command in progress fails and `isConnected` becomes false.

## Synchronous API

Each call blocks the isolate until libpq returns: use it where nothing else has to run meanwhile.

```dart
final pq = LibPq('host=localhost dbname=app user=app password=secret');

final result = pq.execParams(r'select name, age from users where id = $1', [1]);
print(result.getValue(0, 0)); // null for SQL NULL
print(result.asMapList());
print(result.affectedRows);
result.dispose(); // frees the native memory

pq.startTransaction();
pq.exec('update users set age = age + 1').dispose();
pq.commitTransaction();

pq.dispose();
```

### Large objects

```dart
final lo = LargeObject(pq);
final oid = lo.create();
lo.open(oid); // starts a transaction
lo.write(bytes, bytes.length);
final buffer = Uint8List(lo.size());
lo.read(buffer, buffer.length);
lo.close(); // commits
```

## Bindings

`LibpqBindings` has every function of `libpq-fe.h`, generated by `ffigen` from the headers in `libpq/include`. See [example/low_level.dart](example/low_level.dart).

```dart
final pq = LibpqBindings(openLibpq());
```

## Security

libpq's defaults are not the safest, and they apply here:

- **`sslmode`**: the default `prefer` falls back to plain text, and `require` does not check who the server is. On a network you do not control, use `sslmode=verify-full sslrootcert=/path/ca.pem`.
- **Password in clear text**: libpq sends it if the server asks, so someone in the middle of an unverified connection can get it. With libpq 16 or newer, `require_auth=scram-sha-256` refuses that.

Isolates cannot interrupt a blocking call: if the network dies without closing the connection, the command waits until the operating system gives up. libpq's `tcp_user_timeout` and `keepalives_*` settings bound that; your isolate is not affected, and `close()` still returns.

## Not supported

`COPY` and `LISTEN`/`NOTIFY` have no high-level API yet; `LibpqBindings` has their functions. Binary result format is not used: values come as text.

## Development

The tests need a PostgreSQL server:

```
set LIBPQ_PATH=C:\Program Files\PostgreSQL\16\bin\libpq.dll
set LIBPQ_TEST_CONNINFO=host=localhost dbname=test user=dart password=dart sslmode=disable
dart test --concurrency 1
```

The CI runs them on PostgreSQL 14 to 18 on Linux, and on Windows. To regenerate the bindings: `dart run ffigen`.
