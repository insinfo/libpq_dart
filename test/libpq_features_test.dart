// Typed values, parameters, savepoints, COPY, LISTEN/NOTIFY, encodings, session
// settings, and the pool's limits.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:libpq_dart/libpq_dart.dart';
import 'package:test/test.dart';

import 'test_config.dart';

void main() {
  late LibPqAsync db;

  setUp(() async => db = await LibPqAsync.connect(conninfo));
  tearDown(() => db.close());

  Future<Object?> one(String expression,
          [List<Object?> params = const []]) async =>
      (await db.execute('select $expression as v', params: params)).first['v'];

  group('typed values', () {
    test('numbers, booleans and text', () async {
      expect(await one('1::int2'), 1);
      expect(await one('2147483647::int4'), 2147483647);
      expect(await one('9007199254740993::int8'), 9007199254740993);
      expect(await one('-5::int4'), -5);
      expect(await one('12345::oid'), 12345);
      expect(await one('1.5::float8'), 1.5);
      expect(await one("'NaN'::float8"), isNaN);
      expect(await one("'Infinity'::float8"), double.infinity);
      expect(await one('true'), true);
      expect(await one('false'), false);
      expect(await one("'ação'::text"), 'ação');
      expect(await one("'x'::varchar"), 'x');
      expect(await one("'a'::char(3)"), 'a  ');
      expect(await one('null::int4'), isNull);
    });

    test('numeric keeps every digit, as text', () async {
      expect(await one('1.50::numeric'), '1.50');
      expect(await one("'123456789012345678901234567890.123'::numeric"),
          '123456789012345678901234567890.123');
    });

    test('dates are UTC with the fields the server shows', () async {
      expect(await one("'2024-03-01'::date"), DateTime.utc(2024, 3, 1));
      expect(await one("'2024-03-01 12:34:56'::timestamp"),
          DateTime.utc(2024, 3, 1, 12, 34, 56));
      expect(await one("'2024-03-01 12:34:56.123456'::timestamp"),
          DateTime.utc(2024, 3, 1, 12, 34, 56, 123, 456));
      expect(await one("'2024-03-01 12:34:56.5'::timestamp"),
          DateTime.utc(2024, 3, 1, 12, 34, 56, 500));
    });

    test('timestamptz is the same instant, whatever the session zone',
        () async {
      for (final zone in ['UTC', 'America/Sao_Paulo', 'Asia/Kolkata']) {
        await db.execute("set timezone to '$zone'");
        expect(await one("'2024-03-01 12:00:00+00'::timestamptz"),
            DateTime.utc(2024, 3, 1, 12),
            reason: zone);
      }
    });

    test('a date DateTime cannot represent stays the text, without an error',
        () async {
      expect(await one("'infinity'::date"), 'infinity');
      expect(await one("'-infinity'::timestamp"), '-infinity');
      expect(await one("'infinity'::timestamptz"), 'infinity');
      expect(await one("'0044-03-15 BC'::date"), '0044-03-15 BC');
    });

    test('a DateStyle other than ISO is corrected when connecting', () async {
      final other = await LibPqAsync.connect(
          '$conninfo options=\'-c DateStyle=SQL,DMY\'');
      addTearDown(other.close);
      final r = await other.execute("select '2024-03-01'::date as v");
      expect(r.first['v'], DateTime.utc(2024, 3, 1));
    });

    test('json and jsonb are decoded', () async {
      expect(await one('\'{"a": [1, 2]}\'::json'), {
        'a': [1, 2]
      });
      expect(await one("'[1, {\"b\": null}]'::jsonb"), [
        1,
        {'b': null}
      ]);
      expect(await one('(select json_agg(g) from generate_series(1, 2) g)'),
          [1, 2]);
    });

    test('bytea is Uint8List', () async {
      final value = await one(r"'\x00ff10'::bytea");
      expect(value, isA<Uint8List>());
      expect(value, [0, 255, 16]);
      expect(await one("''::bytea"), isEmpty);
    });

    test('arrays have the type of their elements, and can hold NULL', () async {
      final ints = await one('array[1, null, 3]');
      expect(ints, isA<List<int?>>());
      expect(ints, [1, null, 3]);
      expect(await one("array['a', null, 'c,d', 'e\"f', 'g\\h', 'NULL']"),
          ['a', null, 'c,d', 'e"f', r'g\h', 'NULL']);
      expect(await one('array[true, false]'), [true, false]);
      expect(await one('array[1.5::float8]'), [1.5]);
      expect(await one('array[1.50::numeric]'), ['1.50']);
      expect(
          await one("array['2024-03-01'::date]"), [DateTime.utc(2024, 3, 1)]);
      expect(await one('array[[1, 2], [3, 4]]'), [
        [1, 2],
        [3, 4]
      ]);
      expect(await one("'{}'::int4[]"), isEmpty);
      expect(await one("'[0:1]={5,6}'::int4[]"), [5, 6]);
      expect(await one('array[\'{"a":1}\'::jsonb]'), [
        {'a': 1}
      ]);
      expect(await one(r"array['\x01'::bytea]"), [
        [1]
      ]);
    });

    test('types without a natural Dart type are the server text', () async {
      expect(await one("'192.168.1.1/24'::inet"), '192.168.1.1/24');
      expect(await one("'1 day'::interval"), '1 day');
      expect(await one("'12:34:56'::time"), '12:34:56');
      expect(await one("'[1,5)'::int4range"), '[1,5)');
      expect(await one("B'101'::bit(3)"), '101');
      expect(await one("gen_random_uuid()"), isA<String>());
    });

    test('toColumnMap and toColumnMaps, the last duplicate wins', () async {
      final r = await db.execute("select 1 as a, 'x' as b, 2 as a");
      expect(r.first.toColumnMap(), {'a': 2, 'b': 'x'});
      expect(r.toColumnMaps(), [
        {'a': 2, 'b': 'x'}
      ]);
    });

    test('typed: false keeps the text', () async {
      final text = await LibPqAsync.connect(conninfo, typed: false);
      addTearDown(text.close);
      expect((await text.execute('select 1 as v, true as t')).rows.single,
          ['1', 't']);
    });

    test('the synchronous API decodes too, on request', () {
      final pq = LibPq(conninfo);
      addTearDown(pq.dispose);
      final result = pq.exec("select 1 as a, true as b, null::text as c");
      addTearDown(result.dispose);
      expect(result.getTyped(0, 0), 1);
      expect(result.toColumnMaps().single, {'a': 1, 'b': true, 'c': null});
      expect(result.asMapList().single, {'a': '1', 'b': 't', 'c': null});
    });
  });

  group('parameters', () {
    test('a List is an array, for ANY', () async {
      final r = await db.execute(
          r'select g from generate_series(1, 5) g where g = any($1) order by g',
          params: [
            [2, 4]
          ]);
      expect(r.map((row) => row['g']), [2, 4]);
    });

    test('text arrays with quotes, NULL and a Set', () async {
      expect(
          await one(r'$1::text[]', [
            ['a"b', r'c\d', null, 'e,f']
          ]),
          ['a"b', r'c\d', null, 'e,f']);
      expect(
          await one(r'$1::int[]', [
            {1, 2}
          ]),
          [1, 2]);
      expect(await one(r'$1::int[]', [<int>[]]), isEmpty);
      expect(
          await one(r'$1::int[]', [
            [
              [1, 2],
              [3, 4]
            ]
          ]),
          [
            [1, 2],
            [3, 4]
          ]);
    });

    test('a Map is JSON', () async {
      expect(
          await one(r'$1::jsonb', [
            {'a': 1}
          ]),
          {'a': 1});
    });

    test('bytes with zeros go in binary', () async {
      final data = Uint8List.fromList([0, 1, 0, 255]);
      expect(await one(r'$1::bytea', [data]), data);
      expect(
          await one(r'$1::bytea[]', [
            [data]
          ]),
          [data]);
    });

    test('a DateTime keeps its instant, UTC or local', () async {
      final instant = DateTime.utc(2024, 3, 1, 12, 34, 56);
      await db.execute("set timezone to 'America/Sao_Paulo'");
      expect(await one(r'$1::timestamptz', [instant]), instant);
      expect(await one(r'$1::timestamptz', [instant.toLocal()]), instant);
    });

    test('booleans and numbers', () async {
      expect(await one(r'$1::bool', [true]), true);
      expect(await one(r'$1::int8', [5]), 5);
      expect(await one(r'$1::float8', [1.5]), 1.5);
      expect(await one(r'$1::numeric', [BigInt.parse('123456789012345678901')]),
          '123456789012345678901');
    });
  });

  group('question marks', () {
    test('are numbered', () {
      expect(questionMarksToNumbered('select ?, ? from t where a = ?'),
          r'select $1, $2 from t where a = $3');
    });

    test('are left alone in strings, identifiers, comments and dollar quotes',
        () {
      const sql = r"""select '?', "a?b", E'it\'s ?', $tag$ ? $tag$, $$ ? $$ -- ?
/* ? /* ? */ ? */ , ?""";
      expect(questionMarksToNumbered(sql),
          sql.replaceFirst(', ?', r', $1', sql.lastIndexOf(', ?')));
    });

    test('?? is a literal question mark, for the JSON operators', () {
      expect(questionMarksToNumbered("select a ?? 'k' from t where b = ?"),
          r"select a ? 'k' from t where b = $1");
    });

    test(r'a $1 that is not a tag is left alone', () {
      expect(questionMarksToNumbered(r'select $1, ?'), r'select $1, $1');
    });

    test('work against the server', () async {
      final r = await db.execute(
          questionMarksToNumbered('select ?::int + 1 as v'),
          params: [1]);
      expect(r.first['v'], 2);
    });
  });

  group('savepoints', () {
    setUp(() => db.execute('create temporary table t_s (id int)'));

    Future<List<Object?>> ids() async => [
          for (final r in await db.execute('select id from t_s order by id'))
            r['id']
        ];

    test('an error in one is rolled back, and the transaction goes on',
        () async {
      await db.transaction((tx) async {
        await tx.execute('insert into t_s values (1)');
        await expectLater(tx.savepoint((sp) async {
          await sp.execute('insert into t_s values (2)');
          await sp.execute('select 1/0');
        }),
            throwsA(isA<LibPqException>()
                .having((e) => e.sqlState, 'sqlState', '22012')));
        await tx.execute('insert into t_s values (3)');
      });
      expect(await ids(), [1, 3]);
    });

    test('one that succeeds keeps its work and returns its value', () async {
      final value = await db.transaction((tx) => tx.savepoint((sp) async {
            await sp.execute('insert into t_s values (1)');
            return 'done';
          }));
      expect(value, 'done');
      expect(await ids(), [1]);
    });

    test('they nest', () async {
      await db.transaction((tx) async {
        await tx.savepoint((outer) async {
          await outer.execute('insert into t_s values (1)');
          await expectLater(outer.savepoint((inner) async {
            await inner.execute('insert into t_s values (2)');
            throw StateError('stop');
          }), throwsStateError);
          await outer.execute('insert into t_s values (3)');
        });
      });
      expect(await ids(), [1, 3]);
    });

    test('an exception of the transaction rolls everything back', () async {
      await expectLater(db.transaction((tx) async {
        await tx.savepoint((sp) => sp.execute('insert into t_s values (1)'));
        throw StateError('stop');
      }), throwsStateError);
      expect(await ids(), isEmpty);
    });

    test('the status of the transaction is exposed', () async {
      expect(db.transactionStatus, PqTransactionStatus.idle);
      await db.transaction((tx) async {
        await tx.execute('select 1');
        expect(db.transactionStatus, PqTransactionStatus.inTransaction);
        try {
          await tx.savepoint((sp) async {
            await expectLater(sp.execute('select 1/0'), throwsA(anything));
            expect(db.transactionStatus, PqTransactionStatus.failed);
            throw StateError('leave the savepoint');
          });
        } on StateError catch (_) {
          // Expected.
        }
        expect(db.transactionStatus, PqTransactionStatus.inTransaction);
      });
      expect(db.transactionStatus, PqTransactionStatus.idle);
    });

    test('isolation level and read only', () async {
      await expectLater(
          db.transaction<void>((tx) async {
            final r = await tx.execute('show transaction_isolation');
            expect(r.first['transaction_isolation'], 'serializable');
            await expectLater(
                tx.execute('create table libpq_read_only (id int)'),
                throwsA(isA<LibPqException>()
                    .having((e) => e.sqlState, 'sqlState', '25006')));
            throw StateError('roll back');
          }, isolationLevel: PqIsolationLevel.serializable, readOnly: true),
          throwsStateError);
    });
  });

  group('COPY', () {
    setUp(() => db.execute(
        'create temporary table t_c (id int primary key, name text, at date)'));

    test('copyRows writes values of every kind', () async {
      final count = await db.copyRows('t_c', [
        'id',
        'name',
        'at'
      ], [
        [1, 'plain', DateTime.utc(2024, 3, 1)],
        [2, 'tab\there\nnew line\\back', null],
        [3, null, null],
        [4, 'ação ☕', null],
      ]);
      expect(count, 4);
      final r = await db.execute('select * from t_c order by id');
      expect(r.rows, [
        [1, 'plain', DateTime.utc(2024, 3, 1)],
        [2, 'tab\there\nnew line\\back', null],
        [3, null, null],
        [4, 'ação ☕', null],
      ]);
    });

    test('copyRows with many rows, past several chunks', () async {
      const n = 50000;
      final count = await db.copyRows('t_c', ['id', 'name'],
          Iterable.generate(n, (i) => [i, 'name $i ${'x' * 20}']));
      expect(count, n);
      expect((await db.execute('select count(*) as n from t_c')).first['n'], n);
    });

    test('copyFrom sends the bytes as they are', () async {
      final data = Stream.fromIterable([
        utf8.encode('1,a\n2,'),
        utf8.encode('b\n'),
      ]);
      final count = await db.copyFrom(
          "COPY t_c (id, name) FROM STDIN (FORMAT csv)", data);
      expect(count, 2);
    });

    test('a server error fails it, and the connection goes on', () async {
      await expectLater(
          db.copyRows('t_c', [
            'id'
          ], [
            [1],
            [1]
          ]),
          throwsA(isA<LibPqException>()
              .having((e) => e.sqlState, 'sqlState', '23505')
              .having((e) => e.constraint, 'constraint', 't_c_pkey')));
      expect((await db.execute('select 1 as v')).first['v'], 1);
    });

    test('a source that fails aborts it, and nothing is written', () async {
      Stream<List<int>> failing() async* {
        yield utf8.encode('1\n');
        throw StateError('the source failed');
      }

      await expectLater(
          db.copyFrom('COPY t_c (id) FROM STDIN', failing()), throwsStateError);
      expect((await db.execute('select count(*) as n from t_c')).first['n'], 0);
      expect(db.isConnected, isTrue);
    });

    test('a wrong number of values fails before anything breaks', () async {
      await expectLater(
          db.copyRows('t_c', [
            'id',
            'name'
          ], [
            [1]
          ]),
          throwsArgumentError);
      expect((await db.execute('select 1 as v')).first['v'], 1);
    });

    test('copyTo delivers the output, past several chunks', () async {
      await db.execute(
          "insert into t_c (id, name) select g, repeat('x', 100) from generate_series(1, 2000) g");
      final bytes = BytesBuilder();
      var chunks = 0;
      await for (final chunk in db.copyTo('COPY t_c (id, name) TO STDOUT')) {
        bytes.add(chunk);
        chunks++;
      }
      final lines =
          const LineSplitter().convert(utf8.decode(bytes.takeBytes()));
      expect(lines.length, 2000);
      expect(chunks, greaterThan(1));
    });

    test('copyToText', () async {
      await db.execute("insert into t_c (id, name) values (1, 'a')");
      expect(await db.copyToText('COPY t_c (id, name) TO STDOUT'), '1\ta\n');
    });

    test('stopping a copyTo early, and the connection goes on', () async {
      final stream = db.copyTo(
          "COPY (select g, repeat('x', 500) from generate_series(1, 2000000) g) TO STDOUT");
      await for (final _ in stream) {
        break;
      }
      expect((await db.execute('select 1 as v')).first['v'], 1);
    });

    test('a COPY through execute fails, and the connection goes on', () async {
      await expectLater(db.execute('COPY t_c (id) FROM STDIN'),
          throwsA(isA<LibPqException>()));
      await expectLater(db.execute('COPY t_c (id) TO STDOUT'),
          throwsA(isA<LibPqException>()));
      expect((await db.execute('select 1 as v')).first['v'], 1);
    });

    test('a statement that is not a COPY is refused', () async {
      await expectLater(db.copyFrom('select 1', const Stream.empty()),
          throwsA(isA<LibPqException>()));
      await expectLater(
          db.copyTo('select 1').toList(), throwsA(isA<LibPqException>()));
      expect((await db.execute('select 1 as v')).first['v'], 1);
    });

    test('inside a transaction, a rollback undoes it', () async {
      await expectLater(db.transaction((tx) async {
        await tx.copyRows('t_c', [
          'id'
        ], [
          [1]
        ]);
        final text = await tx.execute('select count(*) as n from t_c');
        expect(text.first['n'], 1);
        throw StateError('stop');
      }), throwsStateError);
      expect((await db.execute('select count(*) as n from t_c')).first['n'], 0);
    });

    test('the synchronous API copies too', () {
      final pq = LibPq(conninfo);
      addTearDown(pq.dispose);
      pq.exec('create temporary table t_sc (id int, name text)').dispose();
      expect(pq.copyFrom('COPY t_sc FROM STDIN', [utf8.encode('1\ta\n2\tb\n')]),
          2);
      expect(utf8.decode(pq.copyTo('COPY t_sc TO STDOUT')), '1\ta\n2\tb\n');
      expect(() => pq.copyFrom('select 1', const []),
          throwsA(isA<LibPqException>()));
      expect(
          () => pq.exec('COPY t_sc TO STDOUT'), throwsA(isA<LibPqException>()));
      expect(pq.execMapList('select 1 as v'), [
        {'v': '1'}
      ]);
    });
  });

  group('LISTEN / NOTIFY', () {
    test('a notification reaches the listener, with its payload and pid',
        () async {
      final sender = await LibPqAsync.connect(conninfo);
      addTearDown(sender.close);
      final pid =
          (await sender.execute('select pg_backend_pid() as p')).first['p'];
      final received = Completer<PqNotification>();
      final sub = db.listen('libpq_test').listen(received.complete);
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await sender.notify('libpq_test', 'olá ☕');
      final n = await received.future.timeout(const Duration(seconds: 5));
      expect(n.channel, 'libpq_test');
      expect(n.payload, 'olá ☕');
      expect(n.processId, pid);
    });

    test('channels are separate, and names are quoted', () async {
      final sender = await LibPqAsync.connect(conninfo);
      addTearDown(sender.close);
      final seen = <String>[];
      final a = db.listen('Canal "A"').listen((n) => seen.add(n.payload));
      final b = db.listen('canal_b').listen((n) => seen.add('b:${n.payload}'));
      addTearDown(a.cancel);
      addTearDown(b.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await sender.notify('Canal "A"', '1');
      await sender.notify('canal_b', '2');
      await sender.notify('nobody', '3');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(seen, containsAll(['1', 'b:2']));
      expect(seen.length, 2);
    });

    test('the connection runs commands meanwhile, and gets its own', () async {
      final seen = <String>[];
      final sub = db.listen('libpq_self').listen((n) => seen.add(n.payload));
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect((await db.execute('select 1 as v')).first['v'], 1);
      await db.notify('libpq_self', 'me');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(seen, ['me']);
    });

    test('after cancelling, nothing more arrives (UNLISTEN)', () async {
      final sender = await LibPqAsync.connect(conninfo);
      addTearDown(sender.close);
      final seen = <String>[];
      final sub = db.listen('libpq_off').listen((n) => seen.add(n.payload));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await sub.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sender.notify('libpq_off', 'late');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(seen, isEmpty);
      final r =
          await db.execute('select count(*) as n from pg_listening_channels()');
      expect(r.first['n'], 0);
    });

    test('notifications sent in a transaction arrive at its commit', () async {
      final sender = await LibPqAsync.connect(conninfo);
      addTearDown(sender.close);
      final seen = <String>[];
      final sub = db.listen('libpq_tx').listen((n) => seen.add(n.payload));
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await sender.transaction((tx) async {
        await tx.notify('libpq_tx', 'kept');
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(seen, isEmpty);
      });
      await expectLater(sender.transaction((tx) async {
        await tx.notify('libpq_tx', 'rolled back');
        throw StateError('stop');
      }), throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(seen, ['kept']);
    });

    test('the raw stream, for a LISTEN you run yourself', () async {
      final seen = <String>[];
      final sub = db.notifications.listen((n) => seen.add(n.channel));
      addTearDown(sub.cancel);
      await db.execute('LISTEN libpq_raw');
      await db.execute("NOTIFY libpq_raw, 'x'");
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(seen, ['libpq_raw']);
    });

    test('a connection the server closes gives the stream an error', () async {
      final other = await LibPqAsync.connect(conninfo);
      addTearDown(other.close);
      final pid =
          (await other.execute('select pg_backend_pid() as p')).first['p'];
      final failed = Completer<Object>();
      final done = Completer<void>();
      other
          .listen('libpq_lost')
          .listen((_) {}, onError: failed.complete, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await db.execute('select pg_terminate_backend($pid)');
      final error = await failed.future.timeout(const Duration(seconds: 5));
      expect(error,
          isA<LibPqException>().having((e) => e.sqlState, 'sqlState', '08006'));
      await done.future.timeout(const Duration(seconds: 5));
      expect(other.isConnected, isFalse);
    });

    test('close ends the listeners', () async {
      final other = await LibPqAsync.connect(conninfo);
      final done = Completer<void>();
      other.listen('libpq_close').listen((_) {}, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await other.close();
      await done.future.timeout(const Duration(seconds: 5));
    });

    test('the synchronous API collects them when asked', () async {
      final pq = LibPq(conninfo);
      addTearDown(pq.dispose);
      pq.exec('LISTEN libpq_sync').dispose();
      await db.notify('libpq_sync', 'hi');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final seen = pq.takeNotifications();
      expect(seen.single.payload, 'hi');
      expect(pq.takeNotifications(), isEmpty);
    });
  });

  group('encodings and session settings', () {
    test('win1252: client_encoding and the codec', () async {
      final win = await LibPqAsync.connect("$conninfo client_encoding=WIN1252",
          encoding: const Windows1252Codec());
      addTearDown(win.close);
      const text = 'ação € “aspas” ç';
      final r = await win
          .execute(r'select $1::text as v, length($1) as n', params: [text]);
      expect(r.first['v'], text);
      expect(r.first['n'], text.length);
    });

    test('the Windows-1252 codec refuses what it cannot encode', () {
      const codec = Windows1252Codec();
      expect(codec.decode(codec.encode('€ç')), '€ç');
      expect(() => codec.encode('☕'), throwsArgumentError);
    });

    test('session statements run when connecting', () async {
      final other = await LibPqAsync.connect(conninfo, sessionStatements: [
        "SET search_path TO pg_catalog, public",
        "SET timezone TO 'America/Sao_Paulo'",
        "SET application_name TO 'libpq_test'",
      ]);
      addTearDown(other.close);
      expect((await other.execute('show timezone')).first['TimeZone'],
          'America/Sao_Paulo');
      expect((await other.execute('show application_name')).first.values.single,
          'libpq_test');
    });

    test('a session statement that fails fails the connection', () async {
      await expectLater(
          LibPqAsync.connect(conninfo, sessionStatements: ['SET nothing TO 1']),
          throwsA(isA<LibPqException>()));
    });

    test('a default query timeout', () async {
      final other = await LibPqAsync.connect(conninfo,
          queryTimeout: const Duration(milliseconds: 200));
      addTearDown(other.close);
      await expectLater(other.execute('select pg_sleep(5)'),
          throwsA(isA<TimeoutException>()));
      expect((await other.execute('select 1 as v')).first['v'], 1);
    });
  });

  group('errors', () {
    test('carry the constraint, the table and the SQLSTATE', () async {
      await db.execute(
          'create temporary table t_e (id int constraint t_e_u unique)');
      await db.execute('insert into t_e values (1)');
      await expectLater(
          db.execute('insert into t_e values (1)'),
          throwsA(isA<LibPqException>()
              .having((e) => e.sqlState, 'sqlState', '23505')
              .having((e) => e.constraint, 'constraint', 't_e_u')
              .having((e) => e.table, 'table', 't_e')
              .having((e) => e.detail, 'detail', isNotNull)
              .having((e) => '$e', 'toString', contains('23505'))));
    });

    test('a lost connection has SQLSTATE 08006', () async {
      final other = await LibPqAsync.connect(conninfo);
      addTearDown(other.close);
      final pid =
          (await other.execute('select pg_backend_pid() as p')).first['p'];
      await db.execute('select pg_terminate_backend($pid)');
      final first = await other
          .execute('select 1')
          .then<Object?>((r) => r, onError: (Object e) => e);
      expect(
          first,
          isA<LibPqException>()
              .having((e) => e.sqlState, 'sqlState', anyOf('08006', '57P01')));
      await expectLater(
          other.execute('select 1'),
          throwsA(isA<LibPqException>()
              .having((e) => e.sqlState, 'sqlState', '08006')));
    });
  });

  group('pool', () {
    test('session statements and onOpen run for each connection', () async {
      var opened = 0;
      final pool = LibPqAsyncPool(conninfo,
          maxConnections: 2,
          sessionStatements: ["SET application_name TO 'libpq_pool'"],
          onOpen: (c) async {
        opened++;
        await c.execute('select 1');
      });
      addTearDown(pool.close);
      final names = await Future.wait([
        for (var i = 0; i < 2; i++)
          pool.execute(
              'select pg_sleep(0.1), current_setting(\'application_name\') as n')
      ]);
      expect(names.map((r) => r.first['n']), everyElement('libpq_pool'));
      expect(opened, 2);
    });

    test('values are typed, as in a connection', () async {
      final pool = LibPqAsyncPool(conninfo);
      addTearDown(pool.close);
      expect((await pool.execute('select 1 as v')).first['v'], 1);
    });

    test('a connection past maxCommandCount is replaced', () async {
      final pool =
          LibPqAsyncPool(conninfo, maxConnections: 1, maxCommandCount: 3);
      addTearDown(pool.close);
      final pids = <Object?>{};
      for (var i = 0; i < 9; i++) {
        pids.add(
            (await pool.execute('select pg_backend_pid() as p')).first['p']);
      }
      expect(pids.length, greaterThanOrEqualTo(3));
      expect(pool.openConnections, lessThanOrEqualTo(1));
    });

    test('a connection past maxConnectionAge is replaced', () async {
      final pool = LibPqAsyncPool(conninfo,
          maxConnections: 1,
          maxConnectionAge: const Duration(milliseconds: 100));
      addTearDown(pool.close);
      final first =
          (await pool.execute('select pg_backend_pid() as p')).first['p'];
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final second =
          (await pool.execute('select pg_backend_pid() as p')).first['p'];
      expect(second, isNot(first));
    });

    test('an idle connection the server closed is replaced, without an error',
        () async {
      final pool = LibPqAsyncPool(conninfo,
          maxConnections: 1, idleTestThreshold: Duration.zero);
      addTearDown(pool.close);
      final pid =
          (await pool.execute('select pg_backend_pid() as p')).first['p'];
      await db.execute('select pg_terminate_backend($pid)');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final next =
          (await pool.execute('select pg_backend_pid() as p')).first['p'];
      expect(next, isNot(pid));
    });

    test('acquireTimeout fails a caller that waits too long', () async {
      final pool = LibPqAsyncPool(conninfo,
          maxConnections: 1, acquireTimeout: const Duration(milliseconds: 100));
      addTearDown(pool.close);
      final busy = pool.execute('select pg_sleep(0.5)');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await expectLater(
          pool.execute('select 1'), throwsA(isA<TimeoutException>()));
      await busy;
      expect((await pool.execute('select 1 as v')).first['v'], 1);
    });

    test('a callback that leaves a transaction open does not hand it over',
        () async {
      final pool = LibPqAsyncPool(conninfo, maxConnections: 1);
      addTearDown(pool.close);
      await pool.withConnection((c) => c.execute('begin'));
      final r = await pool.execute(
          "select current_setting('transaction_read_only') as v, pg_current_xact_id_if_assigned() as x");
      expect(r.first['x'], isNull);
      await pool.withConnection((c) async {
        expect(c.transactionStatus, PqTransactionStatus.idle);
      });
    });

    test('stream holds a connection until it ends', () async {
      final pool = LibPqAsyncPool(conninfo, maxConnections: 1);
      addTearDown(pool.close);
      final rows = await pool
          .stream('select g from generate_series(1, 1000) g')
          .toList();
      expect(rows.length, 1000);
      expect(pool.idleConnections, 1);
    });

    test('stopping a stream early returns the connection', () async {
      final pool = LibPqAsyncPool(conninfo, maxConnections: 1);
      addTearDown(pool.close);
      await for (final _ in pool.stream(
          'select g from generate_series(1, 100000000) g',
          batchSize: 16)) {
        break;
      }
      expect((await pool.execute('select 1 as v')).first['v'], 1);
    });

    test('copyRows and notify', () async {
      final pool = LibPqAsyncPool(conninfo, maxConnections: 1);
      addTearDown(pool.close);
      await pool.execute(
          'drop table if exists libpq_pool_copy; create table libpq_pool_copy (id int)');
      addTearDown(() => db.execute('drop table if exists libpq_pool_copy'));
      expect(
          await pool.copyRows('public.libpq_pool_copy', [
            'id'
          ], [
            [1],
            [2]
          ]),
          2);
      final seen = Completer<String>();
      final sub =
          db.listen('libpq_pool_n').listen((n) => seen.complete(n.payload));
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await pool.notify('libpq_pool_n', 'x');
      expect(await seen.future.timeout(const Duration(seconds: 5)), 'x');
    });
  });
}
