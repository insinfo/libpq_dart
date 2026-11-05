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
  libpq_dart: ^2.1.0
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

`execute` returns a `PqAsyncResult`, already in Dart memory, with nothing to dispose. Values are decoded by their type, in the connection's isolate:

| PostgreSQL | Dart |
| --- | --- |
| `int2`, `int4`, `int8`, `oid` | `int` |
| `float4`, `float8` | `double` |
| `bool` | `bool` |
| `numeric` | `String`, the exact text |
| `date`, `timestamp` | `DateTime` in UTC, with the fields the server shows |
| `timestamptz` | `DateTime` in UTC, the same instant |
| `json`, `jsonb` | decoded `Map`, `List`... |
| `bytea` | `Uint8List` |
| arrays of these and of text types | `List<T?>` |
| everything else (`inet`, `interval`, `time`, ranges, enums...) | `String`, the server's text |

SQL NULL is `null`. A date `DateTime` cannot represent (`infinity`, or a year past its range) is `null` too, as in the other PostgreSQL drivers; `infinity: PqInfinity.text` gives the server's text and `PqInfinity.exception` fails the command. BC dates have the astronomical year: 44 BC is the year -43. With `typed: false` every value is the server's text.

```dart
final r = await db.execute('select 1 as a, null as b');
r.columns;        // ['a', 'b']
r.columnTypes;    // type oids
r.rows;           // [[1, null]]
r.first['a'];     // 1
r.first.toColumnMap(); // {'a': 1, 'b': null}
r.toColumnMaps(); // [{'a': 1, 'b': null}]
r.commandTag;     // 'SELECT 1'
r.affectedRows;   // 1
```

### Parameters

They are numbered `$1`, `$2`... and never read as SQL.

| Dart | Sent as |
| --- | --- |
| `null` | SQL NULL |
| `Uint8List` | bytes, in binary |
| `List`, `Set` | an array, so `= ANY($1)` works |
| `Map` | JSON |
| `DateTime` | ISO 8601 with its offset |
| anything else | its `toString()`, for the server to convert |

```dart
await db.execute(r'insert into files (name, body) values ($1, $2)',
    params: ['a.png', bytes]);
await db.execute(r'select * from users where id = any($1)', params: [[1, 2, 3]]);
```

A JSON array for a `json` column is ambiguous with a PostgreSQL array: pass it through `jsonEncode`.

Without parameters a statement goes through the simple protocol, so a script with several statements runs whole and returns its last result.

For code written with `?` placeholders, `questionMarksToNumbered(sql)` converts them, leaving alone what is inside strings, identifiers, comments and dollar quotes; `??` is a literal `?`.

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
final balance = await db.transaction((tx) async {
  await tx.execute(r'update accounts set balance = balance - $1 where id = 1',
      params: [100]);
  final r = await tx.execute('select balance from accounts where id = 1');
  return r.first['balance'];
}, isolationLevel: PqIsolationLevel.serializable);
```

`savepoint` runs a part that can fail without losing the rest. If it throws, it is rolled back, the error is rethrown, and the transaction goes on:

```dart
await db.transaction((tx) async {
  await tx.execute('insert into log values (1)');
  try {
    await tx.savepoint((sp) => sp.execute('insert into maybe_duplicate values (1)'));
  } on LibPqException catch (e) {
    if (e.sqlState != '23505') rethrow;
  }
  await tx.execute('insert into log values (2)');
});
```

If a statement failed outside a savepoint and the callback caught the error, the commit fails with SQLSTATE `25P02`: PostgreSQL has already rolled the transaction back. `db.transactionStatus` tells the status of the server after each command.

### COPY

The fastest way to load or export many rows. `copyRows` writes values, converted as parameters are; `copyFrom` and `copyTo` carry the bytes as they are, in any format.

```dart
final written = await db.copyRows('public.items', ['id', 'name'],
    [[1, 'first'], [2, null]]);

await db.copyFrom('COPY items FROM STDIN (FORMAT csv)', File('items.csv').openRead());

await for (final chunk in db.copyTo('COPY items TO STDOUT (FORMAT csv)')) {
  output.add(chunk);
}
final text = await db.copyToText('COPY items TO STDOUT');
```

A source is read as the server takes it, and pausing `copyTo` stops the reading. A source that fails aborts the `COPY`, and nothing is written. They also work inside a transaction, through the session.

### LISTEN and NOTIFY

```dart
final subscription = db.listen('events').listen((n) {
  print('${n.channel}: ${n.payload} from ${n.processId}');
});
await db.notify('events', 'hello');
await subscription.cancel(); // UNLISTEN
```

libpq has to be asked: while a connection has listeners, its isolate checks every `notificationPollInterval` (50 ms by default, in `connect`), so that is about how long a notification can wait. That check also notices a closed connection: the stream gets an error with SQLSTATE `08006` and ends. Nothing is delivered while a command runs on that connection, so use one of its own for listening, not one from a pool.

`db.notifications` has every notification of the connection, for a `LISTEN` you run yourself, and `db.notices` has the server's notices and warnings.

### Prepared statements and the binary format

Both are off by default, and work on `LibPqAsync` and `LibPqAsyncPool`:

```dart
final db = await LibPqAsync.connect(conninfo,
    statementCacheSize: 256, // statements kept prepared, per connection
    binary: true); // needs a statementCacheSize
```

`statementCacheSize` prepares each `select`, `insert`, `update`, `delete`, `with`, `values`, `table` or `merge` the first time it runs and reuses it, so the server does not parse it again. The first run costs one more round trip, and two with `binary`; the least recently used statement leaves when the cache is full. So it pays for statements that repeat with parameters, not for SQL built with literals. A script with several statements is not prepared, and runs whole.

`binary` asks for the values in binary. They are the same values as in text, which the tests compare type by type. A prepared statement tells its column types before it runs, so one with a column this driver does not read in binary (`inet`, `interval`, `float4`, an enum...) or the server cannot send that way (`aclitem`) stays in text, with no error. `PqAsyncResult.binary` tells which one a result used.

Median on a local server, no TLS, compiled to AOT, 10,000 rows per query:

| | text | `statementCacheSize` | with `binary` |
| --- | --- | --- | --- |
| Queries with a parameter, per second | 9,757 | 12,319 | 12,449 |
| Rows per second: int, text, float8 | 858,762 | 890,263 | 951,149 |
| Rows per second: timestamptz, date, numeric, bytea, int4[], uuid | 130,851 | 139,416 | 141,185 |
| Rows per second: int, text, float8, on 8 connections | 2,058,972 | 2,120,666 | 2,244,648 |

The gain is smaller when most of the time is the network or the query itself.

When it does not fit:

- A pooler in transaction mode, like PgBouncer, can give each transaction another server connection, which does not have the statement.
- A statement whose result columns changed (`ALTER TABLE`), or that the server lost (`DEALLOCATE ALL`, `DISCARD ALL`), is prepared and run again. Inside a transaction it cannot be, as the server has already aborted it: the transaction fails with SQLSTATE `0A000` or `26000`, and the next attempt works.

`LibPq`, the synchronous API, has neither; `LibpqBindings` has `PQprepare` and `PQexecPrepared`.

### Timeouts and cancelling

```dart
await db.execute('select slow()', timeout: Duration(seconds: 5)); // TimeoutException
await db.cancel(); // the running command fails with SQLSTATE 57014
```

A timeout asks the server to cancel the query, and the connection stays usable. `connectTimeout` (15 s) applies when the conninfo has no `connect_timeout`. `close(timeout:)` does not wait forever for a command that does not end.

### Pool

Each connection of the pool has its own isolate, so queries run in parallel. Connections open when needed, up to `maxConnections`.

```dart
final pool = LibPqAsyncPool(
  conninfo,
  maxConnections: 8,
  acquireTimeout: Duration(seconds: 30), // waiting for a free connection
  queryTimeout: Duration(seconds: 30),
  idleTestThreshold: Duration(minutes: 1), // select 1 before reusing an idle one
  maxConnectionAge: Duration(hours: 12),
  maxCommandCount: 100000,
  sessionStatements: ["SET search_path TO public, sales"],
  onOpen: (connection) async { /* runs once per connection */ },
);
final results = await Future.wait([
  pool.execute('select 1'),
  pool.execute('select 2'),
]);
await pool.transaction((tx) async { /* ... */ });
await pool.withConnection((db) async { /* ... */ });
await pool.copyRows('items', ['id'], [[1]]);
await for (final row in pool.stream('select * from items')) { /* ... */ }
await pool.close();
```

A lost connection is replaced, one past its limits is closed instead of reused, and one returned with a transaction open is closed, so it cannot reach the next caller. `openConnections`, `idleConnections` and `waitingCallers` tell its state.

### Session settings and encodings

`sessionStatements` run right after connecting, and if one fails the connection fails. Time zone and application name also work there, or in the conninfo (`application_name=app`).

For a server or session in `WIN1252`, use the codec with the setting:

```dart
final db = await LibPqAsync.connect('host=... client_encoding=WIN1252',
    encoding: const Windows1252Codec());
```

### Errors

`LibPqException` has `message`, `sqlState` (`23505`, `42P01`...), `severity`, `detail`, `hint`, `constraint`, `table`, `column` and `sql`. A lost connection has `sqlState` `08006`: the command in progress fails, and `isConnected` becomes false.

## Synchronous API

Each call blocks the isolate until libpq returns: use it where nothing else has to run meanwhile.

```dart
final pq = LibPq('host=localhost dbname=app user=app password=secret');

final result = pq.execParams(r'select name, age from users where id = $1', [1]);
print(result.getValue(0, 0)); // the server's text; null for SQL NULL
print(result.getTyped(0, 1)); // decoded by its type, as in the asynchronous API
print(result.asMapList());    // values as the server's text
print(result.toColumnMaps()); // values decoded by their type
print(result.affectedRows);
result.dispose(); // frees the native memory

pq.startTransaction();
pq.exec('update users set age = age + 1').dispose();
pq.commitTransaction();

pq.dispose();
```

`copyFrom`, `copyTo` and `takeNotifications` do what their asynchronous names do, blocking.

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

## Development

The tests need a PostgreSQL server:

```
set LIBPQ_PATH=C:\Program Files\PostgreSQL\16\bin\libpq.dll
set LIBPQ_TEST_CONNINFO=host=localhost dbname=test user=dart password=dart sslmode=disable
dart test --concurrency 1
```

`test/stress_rest_api_test.dart` is a REST API under load: several server isolates sharing a port, each with its pool, and clients sending requests at once. It checks for replies to the wrong request, lost updates, rollbacks that saved something and connections left open. It is small by default; `LIBPQ_STRESS_SERVERS`, `LIBPQ_STRESS_CLIENTS`, `LIBPQ_STRESS_REQUESTS`, `LIBPQ_STRESS_IN_FLIGHT` and `LIBPQ_STRESS_POOL` make it heavier, and `LIBPQ_STRESS_BINARY=1` runs it with prepared statements and the binary format.

The CI runs them on PostgreSQL 14 to 18 on Linux, and on Windows. To regenerate the bindings: `dart run ffigen`.
