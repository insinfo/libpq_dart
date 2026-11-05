import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:libpq_dart/libpq_dart.dart';
import 'package:test/test.dart';

import 'test_config.dart';

/// The longest the event loop stayed blocked while [action] ran.
Future<Duration> longestStall(Future<void> Function() action) async {
  var longest = Duration.zero;
  final watch = Stopwatch()..start();
  var last = watch.elapsed;
  final timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
    final gap = watch.elapsed - last;
    if (gap > longest) longest = gap;
    last = watch.elapsed;
  });
  try {
    await action();
  } finally {
    timer.cancel();
  }
  return longest;
}

void main() {
  late LibPqAsync db;

  setUp(() async => db = await LibPqAsync.connect(conninfo));
  tearDown(() => db.close());

  group('connect', () {
    test('reports the server and libpq versions', () {
      expect(db.isConnected, isTrue);
      expect(db.serverVersion, matches(RegExp(r'^\d+\.\d+\.\d+$')));
      expect(db.protocol, 3);
      expect(db.libpqVersion, greaterThan(90000));
    });

    test('a refused connection fails with the reason', () async {
      await expectLater(
          LibPqAsync.connect('host=localhost port=1 dbname=x'),
          throwsA(isA<LibPqException>()
              .having((e) => e.message, 'message', isNotEmpty)));
    });

    test('a library that does not exist fails, naming it', () async {
      await expectLater(
          LibPqAsync.connect(conninfo, libraryPath: 'does-not-exist.dll'),
          throwsA(isA<LibPqException>().having(
              (e) => e.message, 'message', contains('does-not-exist'))));
    });

    test(
        'a server that never answers: connectTimeout ends it, and the event '
        'loop keeps running', () async {
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(silent.close);
      silent.listen((client) => client.listen((_) {}, onError: (_) {}));
      final stall = await longestStall(() async {
        await expectLater(
            LibPqAsync.connect(
                'host=127.0.0.1 port=${silent.port} dbname=x sslmode=disable',
                connectTimeout: const Duration(seconds: 2)),
            throwsA(isA<LibPqException>()));
      });
      expect(stall, lessThan(const Duration(milliseconds: 500)));
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('a connect_timeout in the conninfo prevails', () async {
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(silent.close);
      silent.listen((client) => client.listen((_) {}, onError: (_) {}));
      final watch = Stopwatch()..start();
      await expectLater(
          LibPqAsync.connect(
              'host=127.0.0.1 port=${silent.port} dbname=x sslmode=disable '
              'connect_timeout=2',
              connectTimeout: const Duration(seconds: 60)),
          throwsA(isA<LibPqException>()));
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('execute', () {
    test('rows, names, types and maps', () async {
      final r = await db.execute("select 1::int4 as a, 'x'::text as b");
      expect(r.columns, ['a', 'b']);
      expect(r.columnTypes, [23, 25]);
      expect(r.rows, [
        ['1', 'x']
      ]);
      expect(r.length, 1);
      expect(r.first['b'], 'x');
      expect(r.first.toMap(), {'a': '1', 'b': 'x'});
      expect(r.toMaps().single, {'a': '1', 'b': 'x'});
      expect(() => r.first['c'], throwsA(isA<LibPqException>()));
      expect(r.commandTag, 'SELECT 1');
      expect(r.affectedRows, 1);
    });

    test('SQL NULL is null', () async {
      final r = await db.execute("select null::text as a, ''::text as b");
      expect(r.rows.single, [null, '']);
    });

    test('parameters: null, numbers, text, dates and bytes', () async {
      final data = Uint8List.fromList([0, 1, 0, 255]);
      final r = await db.execute(
          r'select $1::text a, $2::int b, $3::text c, $4::timestamp d, $5::bytea e',
          params: [null, 5, 'ação ☕', DateTime.utc(2024, 3, 1), data]);
      final row = r.first;
      expect(row['a'], isNull);
      expect(row['b'], '5');
      expect(row['c'], 'ação ☕');
      expect(row['d'], '2024-03-01 00:00:00');
      expect(row.bytea('e'), data);
    });

    test('a script without parameters runs whole', () async {
      final r = await db.execute('select 1; select 2 as two');
      expect(r.first['two'], '2');
    });

    test('commands without rows', () async {
      final r = await db.execute('create temporary table t_c (id int)');
      expect(r.isEmpty, isTrue);
      expect(r.affectedRows, 0);
      expect(r.commandTag, 'CREATE TABLE');
    });

    test('errors carry SQLSTATE, and the connection goes on', () async {
      await expectLater(
          db.execute('select * from table_that_does_not_exist'),
          throwsA(isA<LibPqException>()
              .having((e) => e.sqlState, 'sqlState', '42P01')
              .having((e) => e.severity, 'severity', 'ERROR')));
      expect((await db.execute('select 2 as v')).first['v'], '2');
      expect(db.isConnected, isTrue);
    });

    test('concurrent calls run in order, each with its own reply', () async {
      final results = await Future.wait([
        for (var i = 0; i < 50; i++)
          db.execute(r'select $1::int as i', params: [i])
      ]);
      for (var i = 0; i < 50; i++) {
        expect(results[i].first['i'], '$i');
      }
    });

    test('large results arrive whole', () async {
      final r = await db.execute(
          "select g, repeat('x', 100) as v from generate_series(1, 20000) g");
      expect(r.length, 20000);
      expect(r.rows.last[0], '20000');
    });
  });

  group('the event loop is not blocked', () {
    test('while a query runs', () async {
      final stall = await longestStall(() => db.execute('select pg_sleep(1)'));
      expect(stall, lessThan(const Duration(milliseconds: 300)));
    });

    test('while connecting and closing', () async {
      final stall = await longestStall(() async {
        final other = await LibPqAsync.connect(conninfo);
        await other.close();
      });
      expect(stall, lessThan(const Duration(milliseconds: 500)));
    });

    test('while a large result is decoded', () async {
      final stall = await longestStall(() => db.execute(
          "select g, repeat('x', 200) from generate_series(1, 100000) g"));
      // Far less than the time the query takes: only the final copy is here.
      expect(stall, lessThan(const Duration(seconds: 1)));
    });
  });

  group('cancel and timeout', () {
    test('cancel ends the running command with 57014', () async {
      final running = db.execute('select pg_sleep(30)');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await db.cancel(), isTrue);
      await expectLater(
          running,
          throwsA(isA<LibPqException>()
              .having((e) => e.sqlState, 'sqlState', '57014')));
      expect((await db.execute('select 1 as v')).first['v'], '1');
    });

    test('a timeout cancels the query and the connection goes on', () async {
      final watch = Stopwatch()..start();
      await expectLater(
          db.execute('select pg_sleep(30)',
              timeout: const Duration(milliseconds: 300)),
          throwsA(isA<TimeoutException>()));
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      expect((await db.execute('select 1 as v')).first['v'], '1');
    });

    test('a timeout that does not expire changes nothing', () async {
      final r = await db.execute('select 1 as v',
          timeout: const Duration(seconds: 10));
      expect(r.first['v'], '1');
    });
  });

  group('stream', () {
    test('delivers every row, in order, past several batches', () async {
      final seen = <String?>[];
      await for (final row in db.stream(
          r'select g as n from generate_series(1, $1::int) g',
          params: [1000],
          batchSize: 64)) {
        seen.add(row['n']);
      }
      expect(seen.length, 1000);
      expect(seen.first, '1');
      expect(seen.last, '1000');
    });

    test('an empty result ends the stream', () async {
      expect(await db.stream('select 1 where false').toList(), isEmpty);
    });

    test('a command that returns no rows ends the stream', () async {
      expect(await db.stream('create temporary table t_s (id int)').toList(),
          isEmpty);
    });

    test('an error reaches the listener, and the connection goes on', () async {
      await expectLater(
          db.stream('select * from table_that_does_not_exist').toList(),
          throwsA(isA<LibPqException>()
              .having((e) => e.sqlState, 'sqlState', '42P01')));
      expect((await db.execute('select 1 as v')).first['v'], '1');
    });

    test('an error in the middle delivers the rows before it', () async {
      final seen = <String?>[];
      Object? error;
      await for (final row in db
          .stream('select 1 / (3 - g) as v from generate_series(1, 5) g',
              batchSize: 1)
          .handleError((Object e) => error = e)) {
        seen.add(row['v']);
      }
      expect(seen, isNotEmpty);
      expect((error as LibPqException?)?.sqlState, '22012');
      expect((await db.execute('select 1 as v')).first['v'], '1');
    });

    test('other commands wait for the stream', () async {
      final order = <String>[];
      final streaming = db
          .stream('select g from generate_series(1, 200) g', batchSize: 10)
          .forEach((_) => order.isEmpty ? order.add('row') : null);
      final after = db.execute('select 1').then((_) => order.add('command'));
      await Future.wait([streaming, after]);
      expect(order, ['row', 'command']);
    });

    test('stopping early cancels the query, and the connection goes on',
        () async {
      final watch = Stopwatch()..start();
      await for (final _ in db.stream(
          'select g from generate_series(1, 100000000) g',
          batchSize: 16)) {
        break;
      }
      expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
      expect((await db.execute('select 1 as v')).first['v'], '1');
    });

    test('a paused listener stops the reading', () async {
      var received = 0;
      late StreamSubscription<PqRow> sub;
      sub = db
          .stream('select g from generate_series(1, 100000) g', batchSize: 8)
          .listen((_) {
        received++;
        if (received == 1) sub.pause();
      });
      await Future<void>.delayed(const Duration(milliseconds: 500));
      // One batch was on its way when it paused, nothing more.
      expect(received, lessThanOrEqualTo(16));
      await sub.cancel();
    });
  });

  group('transaction', () {
    setUp(() => db.execute('create temporary table t_t (id int)'));

    Future<List<String?>> ids() async => [
          for (final r in await db.execute('select id from t_t order by id'))
            r['id']
        ];

    test('commits, and returns the value', () async {
      final value = await db.transaction((tx) async {
        await tx.execute('insert into t_t values (1)');
        return 'ok';
      });
      expect(value, 'ok');
      expect(await ids(), ['1']);
    });

    test('an exception rolls back, and is rethrown', () async {
      await expectLater(
          db.transaction((tx) async {
            await tx.execute('insert into t_t values (1)');
            throw StateError('stop');
          }),
          throwsStateError);
      expect(await ids(), isEmpty);
    });

    test('a failed statement caught by the callback: the commit fails',
        () async {
      await expectLater(
          db.transaction((tx) async {
            await tx.execute('insert into t_t values (1)');
            try {
              await tx.execute('select 1/0');
            } on LibPqException catch (_) {}
          }),
          throwsA(isA<LibPqException>()
              .having((e) => e.sqlState, 'sqlState', '25P02')));
      expect(await ids(), isEmpty);
    });

    test('commands from other callers wait until it ends', () async {
      final order = <String>[];
      final gate = Completer<void>();
      final tx = db.transaction((tx) async {
        await tx.execute('insert into t_t values (1)');
        await gate.future;
        order.add('transaction');
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final outside = db.execute('select 1').then((_) => order.add('outside'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      gate.complete();
      await Future.wait([tx, outside]);
      expect(order, ['transaction', 'outside']);
    });

    test('the connection inside the callback fails instead of deadlocking',
        () async {
      await expectLater(
          db.transaction((tx) => db.execute('select 1')), throwsStateError);
      await expectLater(
          db.transaction((tx) => db.transaction((t) async {})),
          throwsStateError);
      expect(await ids(), isEmpty);
    });

    test('statements not awaited one by one still run in order', () async {
      await db.transaction((tx) async {
        await Future.wait([
          for (var i = 1; i <= 5; i++)
            tx.execute(r'insert into t_t values ($1)', params: [i])
        ]);
      });
      expect(await ids(), ['1', '2', '3', '4', '5']);
    });

    test('the session cannot be used after the end', () async {
      late PqSession session;
      await db.transaction((tx) async => session = tx);
      await expectLater(session.execute('select 1'), throwsStateError);
    });

    test('a stream runs inside the transaction', () async {
      await db.transaction((tx) async {
        await tx.execute('insert into t_t values (7)');
        final rows = await db.stream('select id from t_t').toList();
        expect(rows.single['id'], '7');
      });
    });
  });

  group('close', () {
    test('waits for what is queued', () async {
      final other = await LibPqAsync.connect(conninfo);
      final running = other.execute('select pg_sleep(0.2), 1 as v');
      await other.close();
      expect((await running).first['v'], '1');
    });

    test('can be called twice; afterwards commands are refused', () async {
      final other = await LibPqAsync.connect(conninfo);
      await other.close();
      await other.close();
      expect(other.isConnected, isFalse);
      await expectLater(other.execute('select 1'), throwsStateError);
      expect(await other.cancel(), isFalse);
    });

    test('a command that does not end cannot hold it forever', () async {
      final other = await LibPqAsync.connect(conninfo);
      final running = other.execute('select pg_sleep(4)');
      final failed = expectLater(running, throwsA(anything));
      final watch = Stopwatch()..start();
      await other.close(timeout: const Duration(milliseconds: 300));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      await failed;
    });
  });

  group('a connection the server closed', () {
    Future<void> terminate(LibPqAsync victim) async {
      final pid =
          (await victim.execute('select pg_backend_pid() as p')).first['p'];
      final admin = await LibPqAsync.connect(conninfo);
      await admin.execute('select pg_terminate_backend($pid)');
      await admin.close();
    }

    test('the next command fails, and later ones are refused', () async {
      final other = await LibPqAsync.connect(conninfo);
      addTearDown(other.close);
      await terminate(other);
      await expectLater(
          other.execute('select 1'), throwsA(isA<LibPqException>()));
      expect(other.isConnected, isFalse);
      await expectLater(
          other.execute('select 1'), throwsA(isA<LibPqException>()));
    });

    test('a query in progress fails instead of waiting', () async {
      final other = await LibPqAsync.connect(conninfo);
      addTearDown(other.close);
      final pid =
          (await other.execute('select pg_backend_pid() as p')).first['p'];
      final running = other.execute('select pg_sleep(30)');
      final failed = expectLater(running, throwsA(isA<LibPqException>()));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await db.execute('select pg_terminate_backend($pid)');
      await failed;
      expect(other.isConnected, isFalse);
    });

    test('close still ends', () async {
      final other = await LibPqAsync.connect(conninfo);
      await terminate(other);
      await other.close().timeout(const Duration(seconds: 5));
    });
  });

  group('pool', () {
    test('runs queries in parallel', () async {
      final pool = LibPqAsyncPool(conninfo, maxConnections: 4);
      addTearDown(pool.close);
      final watch = Stopwatch()..start();
      await Future.wait(
          [for (var i = 0; i < 4; i++) pool.execute('select pg_sleep(0.5)')]);
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 1800)));
      expect(pool.openConnections, 4);
    });

    test('never opens more than maxConnections, and queues the rest', () async {
      final pool = LibPqAsyncPool(conninfo, maxConnections: 2);
      addTearDown(pool.close);
      final pids = await Future.wait([
        for (var i = 0; i < 20; i++)
          pool.execute('select pg_backend_pid() as p')
      ]);
      expect(pool.openConnections, lessThanOrEqualTo(2));
      expect({for (final r in pids) r.first['p']}.length, lessThanOrEqualTo(2));
      expect(pool.idleConnections, pool.openConnections);
    });

    test('a transaction holds its connection', () async {
      final pool = LibPqAsyncPool(conninfo, maxConnections: 2);
      addTearDown(pool.close);
      final value = await pool.transaction((tx) async {
        await tx.execute('create temporary table t_p (id int)');
        await tx.execute('insert into t_p values (1)');
        return (await tx.execute('select count(*) as n from t_p')).first['n'];
      });
      expect(value, '1');
    });

    test('a lost connection is replaced', () async {
      final pool = LibPqAsyncPool(conninfo, maxConnections: 1);
      addTearDown(pool.close);
      final pid =
          (await pool.execute('select pg_backend_pid() as p')).first['p'];
      await db.execute('select pg_terminate_backend($pid)');
      await expectLater(
          pool.execute('select 1'), throwsA(isA<LibPqException>()));
      final next = await pool.execute('select pg_backend_pid() as p');
      expect(next.first['p'], isNot(pid));
    });

    test('a failed connection frees its slot for whoever waits', () async {
      final pool =
          LibPqAsyncPool('host=localhost port=1 dbname=x', maxConnections: 1);
      addTearDown(pool.close);
      final results = await Future.wait([
        for (var i = 0; i < 3; i++)
          pool
              .execute('select 1')
              .then<Object?>((r) => r, onError: (Object e) => e)
      ]);
      expect(results, everyElement(isA<LibPqException>()));
      expect(pool.openConnections, 0);
    });

    test('close refuses new work and whoever waits', () async {
      final pool = LibPqAsyncPool(conninfo, maxConnections: 1);
      await pool.execute('select 1');
      await pool.close();
      await expectLater(pool.execute('select 1'), throwsStateError);
    });
  });
}
