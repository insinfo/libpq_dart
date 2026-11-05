// The statement cache and the binary format: the values are the same as in text,
// whatever the type, and a statement that went stale is not the caller's problem.
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:libpq_dart/libpq_dart.dart';
import 'package:test/test.dart';

import 'test_config.dart';

/// Values of every type with a binary decoder.
const _binaryExpressions = [
  // Integers.
  '1::int2', '(-32768)::int2', '32767::int2',
  '2147483647::int4', '(-2147483648)::int4',
  '9223372036854775807::int8', '(-9223372036854775808)::int8',
  '4294967295::oid', '0::int4',
  // Floats.
  '1.1::float8', '(-1.5e300)::float8', '5e-324::float8', '0::float8',
  "'-0'::float8", "'Infinity'::float8", "'-Infinity'::float8",
  // Booleans and text.
  'true', 'false',
  "'plain'::text", "''::text", "'çãé☕\u{1F600}'::text", "'a,b\"c\\d'::text",
  "'x'::varchar(5)", "'ab'::char(4)", "'n'::name",
  // Bytes.
  "'\\x00ff10'::bytea", "''::bytea",
  // JSON.
  "'{\"a\":[1,2.5,null,\"ç\"]}'::json", "'{\"a\":1}'::jsonb", "'[1,2]'::jsonb",
  "'3'::jsonb", "'null'::jsonb", "'\"s\"'::json",
  // Dates, in and out of the range of DateTime.
  "'2024-03-01'::date", "'1969-12-31'::date", "'2000-01-01'::date",
  "'0001-01-01'::date", "'0001-12-31 BC'::date", "'0044-03-15 BC'::date",
  "'4713-01-01 BC'::date", "'275760-09-12'::date", "'5874897-12-31'::date",
  "'infinity'::date", "'-infinity'::date",
  "'2024-03-01 12:34:56.123456'::timestamp",
  "'1969-12-31 23:59:59.999999'::timestamp",
  "'2000-01-01 00:00:00'::timestamp", "'0044-03-15 12:00:00 BC'::timestamp",
  "'294276-12-31 23:59:59'::timestamp",
  "'infinity'::timestamp", "'-infinity'::timestamp",
  "'2024-03-01 12:00:00+00'::timestamptz",
  "'2024-03-01 12:00:00.5-03'::timestamptz",
  "'0044-03-15 12:00:00 BC'::timestamptz", "'infinity'::timestamptz",
  "'-infinity'::timestamptz",
  // The rest.
  "'0EBC8A1E-6DF1-4A5D-9C3B-000000FFAB12'::uuid",
  // Exact decimals.
  '0::numeric', '0.00::numeric', '1::numeric', '(-1)::numeric', '1000::numeric',
  '10000::numeric', '100000.00100::numeric', '0.0001::numeric',
  '(-0.00012)::numeric',
  '123456789012345678901234567890.123456789::numeric', '1e100::numeric',
  '1e-100::numeric', "'NaN'::numeric", "'Infinity'::numeric",
  "'-Infinity'::numeric",
  '9999.9999::numeric', '10000.0001::numeric', '1.10::numeric(10,4)',
  // Arrays.
  "'{1,2,NULL}'::int4[]", "'{{1,2},{3,4}}'::int4[]",
  "'{{{1},{2}},{{3},{4}}}'::int8[]",
  "'{}'::int4[]", "'[0:1]={5,6}'::int4[]", "'{1}'::int2[]", "'{7}'::oid[]",
  "'{t,f,NULL}'::bool[]", "'{1.5,NULL}'::float8[]",
  "'{a,\"b,c\",\"d\\\"e\",\"\\\\\",NULL,\"NULL\",\"ç\"}'::text[]",
  "'{x}'::varchar[]",
  "'{ab}'::char(3)[]", "'{n}'::name[]", "'{}'::text[]",
  "'{\"\\\\x00ff\",NULL}'::bytea[]",
  "array[1.50,null,'NaN']::numeric[]",
  "array['2024-03-01'::date,null,'infinity']",
  "array['2024-03-01 12:00'::timestamp,'infinity']",
  "array['2024-03-01 12:00+00'::timestamptz]", "'{}'::date[]",
  "array[array['2024-03-01'::date],array['2024-03-02'::date]]",
  "array['0ebc8a1e-6df1-4a5d-9c3b-000000ffab12'::uuid,null]",
  "array['{\"a\":1}'::json,null]", "array['[1]'::jsonb]",
];

/// Values of the types without one: their statement stays in text.
const _textExpressions = [
  "'10.0.0.1/8'::inet",
  "'1 day 02:00:00'::interval",
  "'12:00:00'::time",
  "'12:00:00+03'::timetz",
  '1.1::float4',
  "'{1.1}'::float4[]",
  "'12.50'::money",
  "'[1,5)'::int4range",
  'row(1,2)',
  "'x'::\"char\"",
  "'<a/>'::xml",
  "'a b'::tsvector",
  "'{10.0.0.1}'::inet[]",
  "'08:00:2b:01:02:03'::macaddr",
  "'(1,2)'::point",
  "'{}'::aclitem[]",
];

void _expectSame(Object? actual, Object? expected, String reason) {
  if (expected is double && expected.isNaN) {
    expect((actual as double).isNaN, isTrue, reason: reason);
    return;
  }
  expect(actual, equals(expected), reason: reason);
  if (expected is Uint8List) {
    expect(actual, isA<Uint8List>(), reason: reason);
  } else if (expected != null) {
    expect(actual.runtimeType, expected.runtimeType, reason: reason);
  }
}

void main() {
  late LibPqAsync text;
  late LibPqAsync binary;

  setUp(() async {
    text = await LibPqAsync.connect(conninfo);
    binary = await LibPqAsync.connect(conninfo,
        statementCacheSize: 16, binary: true);
  });

  tearDown(() async {
    await text.close();
    await binary.close();
  });

  /// The statements prepared on [db]. The comment keeps this one out of the
  /// cache it looks at.
  Future<List<String>> prepared(LibPqAsync db) async {
    final r = await db.execute('/* not cached */ select statement from '
        "pg_prepared_statements where name like 'libpq\\_dart\\_%'");
    return [for (final row in r) row['statement'] as String];
  }

  group('the values are the same as in text', () {
    for (final expression in _binaryExpressions) {
      test(expression, () async {
        final sql = 'select $expression as v';
        final inText = await text.execute(sql);
        // Twice: when prepared, and from the cache.
        for (var i = 0; i < 2; i++) {
          final inBinary = await binary.execute(sql);
          expect(inBinary.binary, isTrue, reason: 'must be in binary');
          expect(inBinary.columnTypes, inText.columnTypes);
          _expectSame(inBinary.first['v'], inText.first['v'], sql);
        }
      });
    }

    test('NaN', () async {
      final r = await binary.execute("select 'NaN'::float8 as v");
      expect(r.binary, isTrue);
      expect((r.first['v'] as double).isNaN, isTrue);
    });

    test('SQL NULL of each type', () async {
      final r = await binary.execute('select null::int4 as a, null::text as b, '
          'null::date as c, null::numeric as d, null::int4[] as e');
      expect(r.binary, isTrue);
      expect(r.rows.single, [null, null, null, null, null]);
    });

    test('random numerics', () async {
      final random = Random(42);
      final values = <String>[
        for (var i = 0; i < 500; i++)
          [
            if (random.nextBool()) '-',
            for (var d = random.nextInt(30); d >= 0; d--) random.nextInt(10),
            if (random.nextBool()) '.',
            if (random.nextBool())
              for (var d = random.nextInt(30); d >= 0; d--) random.nextInt(10),
          ].join().replaceAll(RegExp(r'\.$'), ''),
      ];
      const sql = r'select unnest($1::text[])::numeric as v';
      final inText = await text.execute(sql, params: [values]);
      final inBinary = await binary.execute(sql, params: [values]);
      expect(inBinary.binary, isTrue);
      expect(inBinary.rows, inText.rows);
    });

    test('with a session of another time zone', () async {
      const sql = "select '2024-03-01 12:00:00+00'::timestamptz as v, "
          "'2024-03-01 12:00'::timestamp as w";
      await binary.execute("SET timezone TO 'America/Sao_Paulo'");
      final r = await binary.execute(sql);
      expect(r.binary, isTrue);
      expect(r.first['v'], DateTime.utc(2024, 3, 1, 12));
      expect(r.first['w'], DateTime.utc(2024, 3, 1, 12));
    });

    test('parameters of every kind', () async {
      final bytes = Uint8List.fromList([0, 255, 7]);
      const sql = r'select $1::int4 as a, $2::text as b, $3::bytea as c, '
          r'$4::int4[] as d, $5::jsonb as e, $6::timestamptz as f, $7::int4 as g';
      final params = [
        5,
        'ç',
        bytes,
        [1, 2],
        {'k': 1},
        DateTime.utc(2024, 3, 1),
        null,
      ];
      final inBinary = await binary.execute(sql, params: params);
      final inText = await text.execute(sql, params: params);
      expect(inBinary.binary, isTrue);
      expect(inBinary.rows, inText.rows);
    });

    test('a value in WIN1252', () async {
      final db = await LibPqAsync.connect('$conninfo client_encoding=WIN1252',
          encoding: const Windows1252Codec(),
          statementCacheSize: 4,
          binary: true);
      addTearDown(db.close);
      final r = await db.execute(r'select $1::text as v', params: ['çã']);
      expect(r.binary, isTrue);
      expect(r.first['v'], 'çã');
    });
  });

  group('a statement with another type stays in text', () {
    for (final expression in _textExpressions) {
      test(expression, () async {
        final sql = 'select $expression as v';
        final r = await binary.execute(sql);
        expect(r.binary, isFalse);
        expect(r.first['v'], (await text.execute(sql)).first['v']);
      });
    }

    test('one such column among others', () async {
      final r = await binary
          .execute("select 1 as a, '10.0.0.1'::inet as b, 'x'::text as c");
      expect(r.binary, isFalse);
      expect(r.rows.single, [1, '10.0.0.1', 'x']);
    });

    test('a type the server cannot send in binary', () async {
      final r = await binary.execute(
          'select relacl from pg_class where relacl is not null limit 1');
      expect(r.binary, isFalse);
      expect(r.first['relacl'], isNotNull);
    });

    test('an enum, and a statement without rows', () async {
      await binary.execute("create type pg_temp.b_mood as enum ('ok')");
      final r = await binary.execute("select 'ok'::pg_temp.b_mood as v");
      expect(r.binary, isFalse);
      expect(r.first['v'], 'ok');
      await binary.execute('create temporary table b_rows (id int)');
      final insert =
          await binary.execute(r'insert into b_rows values ($1)', params: [1]);
      expect(insert.affectedRows, 1);
      expect(insert.rows, isEmpty);
    });
  });

  group('infinity with binary', () {
    test('an exception fails the command, not the connection', () async {
      final db = await LibPqAsync.connect(conninfo,
          statementCacheSize: 4, binary: true, infinity: PqInfinity.exception);
      addTearDown(db.close);
      for (final expression in [
        "'infinity'::date",
        "'-infinity'::timestamp",
        "'infinity'::timestamptz",
        "'5874897-12-31'::date",
        "array['infinity'::date]",
      ]) {
        await expectLater(
            db.execute('select $expression as v'),
            throwsA(isA<LibPqException>()
                .having((e) => e.sqlState, 'sqlState', '22008')));
      }
      await expectLater(
          db.stream("select 'infinity'::date as v").toList(),
          throwsA(isA<LibPqException>()
              .having((e) => e.sqlState, 'sqlState', '22008')));
      expect((await db.execute("select '2024-03-01'::date as v")).first['v'],
          DateTime.utc(2024, 3, 1));
    });

    test('the text keeps dates in text', () async {
      final db = await LibPqAsync.connect(conninfo,
          statementCacheSize: 4, binary: true, infinity: PqInfinity.text);
      addTearDown(db.close);
      final r = await db.execute("select 'infinity'::date as v");
      expect(r.binary, isFalse);
      expect(r.first['v'], 'infinity');
      expect((await db.execute('select 1 as v')).binary, isTrue);
    });
  });

  group('the cache', () {
    test('a statement is prepared once', () async {
      const sql = r'select $1::int4 as v';
      for (var i = 0; i < 3; i++) {
        expect((await binary.execute(sql, params: [i])).first['v'], i);
      }
      expect(await prepared(binary), [sql]);
    });

    test('text only: prepared, without the binary format', () async {
      final db = await LibPqAsync.connect(conninfo, statementCacheSize: 4);
      addTearDown(db.close);
      const sql = r'select $1::int4 as v';
      for (var i = 0; i < 2; i++) {
        final r = await db.execute(sql, params: [i]);
        expect(r.binary, isFalse);
        expect(r.first['v'], i);
      }
      expect(await prepared(db), [sql]);
    });

    test('nothing is prepared by default', () async {
      await text.execute(r'select $1::int4 as v', params: [1]);
      expect(await prepared(text), isEmpty);
    });

    test('what has no plan, and scripts, are not cached', () async {
      await binary.execute('BEGIN');
      await binary.execute('SET LOCAL statement_timeout TO 1000');
      await binary.execute('SAVEPOINT b_point');
      await binary.execute('RELEASE SAVEPOINT b_point');
      await binary.execute('COMMIT');
      await binary.execute('create temporary table b_script (id int)');
      final script = await binary
          .execute('insert into b_script values (1); select id from b_script');
      expect(script.binary, isFalse);
      expect(script.rows.single, [1]);
      expect(await prepared(binary), isEmpty);
    });

    test('a final semicolon and any case are cached', () async {
      final r = await binary.execute('  SeLeCt 1 as v ;  ');
      expect(r.binary, isTrue);
      expect(await prepared(binary), hasLength(1));
    });

    test('the least recently used one leaves', () async {
      final db = await LibPqAsync.connect(conninfo, statementCacheSize: 2);
      addTearDown(db.close);
      await db.execute('select 1 as a');
      await db.execute('select 2 as b');
      await db.execute('select 1 as a'); // Now the most recently used.
      await db.execute('select 3 as c'); // select 2 leaves.
      final kept = await prepared(db);
      expect(kept, unorderedEquals(['select 1 as a', 'select 3 as c']));
      expect((await db.execute('select 2 as b')).first['b'], 2);
      expect(await prepared(db), hasLength(2));
    });

    test('leaving during a transaction waits for its end', () async {
      final db = await LibPqAsync.connect(conninfo, statementCacheSize: 1);
      addTearDown(db.close);
      await db.transaction((tx) async {
        await tx.execute('select 1 as a');
        // A DEALLOCATE of a name it does not know would abort the transaction.
        await tx.execute('DEALLOCATE ALL');
        await tx.execute('select 2 as b');
        await tx.execute('select 3 as c');
      });
      expect(db.transactionStatus, PqTransactionStatus.idle);
      await db.execute('select 4 as d');
      expect(await prepared(db), ['select 4 as d']);
    });
  });

  group('a stale statement', () {
    for (final (name, reset) in [
      ('DEALLOCATE ALL', 'DEALLOCATE ALL'),
      ('DISCARD ALL', 'DISCARD ALL'),
    ]) {
      test('after $name runs again', () async {
        const sql = r'select $1::int4 as v';
        await binary.execute(sql, params: [1]);
        await binary.execute(reset);
        expect((await binary.execute(sql, params: [2])).first['v'], 2);
        expect(await prepared(binary), [sql]);
      });
    }

    test('with new columns runs again, with them', () async {
      await binary.execute('create temporary table b_stale (id int)');
      await binary.execute('insert into b_stale values (1)');
      const sql = 'select * from b_stale';
      expect((await binary.execute(sql)).rows.single, [1]);
      await binary.execute('alter table b_stale add column name text');
      final r = await binary.execute(sql);
      expect(r.columns, ['id', 'name']);
      expect(r.rows.single, [1, null]);
    });

    test('with a new type changes its format', () async {
      await binary.execute('create temporary table b_type (v int)');
      await binary.execute('insert into b_type values (1)');
      const sql = 'select v from b_type';
      expect((await binary.execute(sql)).binary, isTrue);
      await binary.execute(
          "alter table b_type alter column v type inet using '10.0.0.1'::inet");
      final r = await binary.execute(sql);
      expect(r.binary, isFalse);
      expect(r.first['v'], '10.0.0.1');
    });

    test('in a transaction fails it, and works after it', () async {
      await binary.execute('create temporary table b_tx (id int)');
      const sql = 'select * from b_tx';
      await binary.execute(sql);
      await binary.execute('alter table b_tx add column name text');
      await expectLater(
          binary.transaction((tx) => tx.execute(sql)),
          throwsA(isA<LibPqException>()
              .having((e) => e.sqlState, 'sqlState', '0A000')));
      expect(binary.transactionStatus, PqTransactionStatus.idle);
      expect((await binary.execute(sql)).columns, ['id', 'name']);
    });

    test('in a stream runs again', () async {
      await binary.execute('create temporary table b_stream (id int)');
      await binary.execute('insert into b_stream values (1), (2)');
      const sql = 'select * from b_stream order by id';
      expect(await binary.stream(sql).map((r) => r['id']).toList(), [1, 2]);
      await binary.execute('alter table b_stream add column name text');
      final rows = await binary.stream(sql).toList();
      expect(rows.map((r) => r.values), [
        [1, null],
        [2, null],
      ]);
      await binary.execute('DEALLOCATE ALL');
      expect(await binary.stream(sql).length, 2);
    });

    test('in a stream in a transaction fails, and works after it', () async {
      await binary.execute('create temporary table b_txs (id int)');
      const sql = 'select * from b_txs';
      await binary.stream(sql).toList();
      await binary.execute('alter table b_txs add column name text');
      await expectLater(
          binary.transaction((tx) => tx.stream(sql).toList()),
          throwsA(isA<LibPqException>()
              .having((e) => e.sqlState, 'sqlState', '0A000')));
      expect(await binary.stream(sql).toList(), isEmpty);
    });
  });

  group('errors', () {
    test('a syntax error is reported, and nothing is cached', () async {
      await expectLater(
          binary.execute('select from from'),
          throwsA(isA<LibPqException>()
              .having((e) => e.sqlState, 'sqlState', '42601')
              .having((e) => e.sql, 'sql', 'select from from')));
      expect(await prepared(binary), isEmpty);
      expect((await binary.execute('select 1 as v')).first['v'], 1);
    });

    test('a constraint fails each time, and the statement stays', () async {
      await binary.execute('create temporary table b_uniq (id int unique)');
      const sql = r'insert into b_uniq values ($1)';
      await binary.execute(sql, params: [1]);
      for (var i = 0; i < 2; i++) {
        await expectLater(
            binary.execute(sql, params: [1]),
            throwsA(isA<LibPqException>()
                .having((e) => e.sqlState, 'sqlState', '23505')
                .having((e) => e.constraint, 'constraint', isNotNull)));
      }
      expect((await binary.execute(sql, params: [2])).affectedRows, 1);
      expect(await prepared(binary), [sql]);
    });

    test('too few parameters', () async {
      await expectLater(
          binary.execute(r'select $1::int4, $2::int4', params: [1]),
          throwsA(isA<LibPqException>()));
      expect((await binary.execute('select 1 as v')).first['v'], 1);
    });

    test('a savepoint survives a failed prepared statement', () async {
      await binary.execute('create temporary table b_sp (id int unique)');
      await binary.transaction((tx) async {
        const sql = r'insert into b_sp values ($1)';
        await tx.execute(sql, params: [1]);
        await expectLater(tx.savepoint((sp) => sp.execute(sql, params: [1])),
            throwsA(isA<LibPqException>()));
        await tx.execute(sql, params: [2]);
      });
      final r = await binary.execute('select id from b_sp order by id');
      expect(r.rows, [
        [1],
        [2],
      ]);
    });

    test('a statement in an aborted transaction', () async {
      await expectLater(binary.transaction((tx) async {
        await expectLater(tx.execute('select 1/0'), throwsA(anything));
        await tx.execute('select 2 as v');
      }),
          throwsA(isA<LibPqException>()
              .having((e) => e.sqlState, 'sqlState', '25P02')));
      expect((await binary.execute('select 2 as v')).first['v'], 2);
    });

    test('a timeout cancels it, and the connection goes on', () async {
      await expectLater(
          binary.execute('select pg_sleep(30)',
              timeout: const Duration(milliseconds: 100)),
          throwsA(isA<TimeoutException>()));
      expect((await binary.execute('select 1 as v')).first['v'], 1);
    });
  });

  group('the rest of the API', () {
    test('a stream decodes in binary, as in text', () async {
      const sql = "select i, i::text as t, 'x'::bytea as b, "
          "'2024-03-01'::date + i as d, i::numeric / 8 as n, "
          'array[i, null] as a from generate_series(1, 1000) i';
      final inText = await text.stream(sql, batchSize: 7).toList();
      final inBinary = await binary.stream(sql, batchSize: 7).toList();
      expect(inBinary.map((r) => r.values), inText.map((r) => r.values));
      expect(await prepared(binary), [sql]);
    });

    test('a stream cancelled halfway', () async {
      const sql = 'select i from generate_series(1, 100000) i';
      final first = await binary.stream(sql, batchSize: 10).first;
      expect(first['i'], 1);
      expect((await binary.execute('select 2 as v')).first['v'], 2);
    });

    test('COPY and NOTIFY go on working', () async {
      await binary.execute('create temporary table b_copy (id int, n text)');
      await binary.copyRows('b_copy', [
        'id',
        'n'
      ], [
        [1, 'a'],
      ]);
      expect(await binary.copyToText('COPY b_copy TO STDOUT'), '1\ta\n');
      final received = binary.listen('b_channel').first;
      await binary.notify('b_channel', 'hi');
      expect((await received).payload, 'hi');
      await expectLater(binary.execute('COPY b_copy TO STDOUT'),
          throwsA(isA<LibPqException>()));
      expect((await binary.execute('select 1 as v')).first['v'], 1);
    });

    test('a pool', () async {
      final pool = LibPqAsyncPool(conninfo,
          maxConnections: 2, statementCacheSize: 8, binary: true);
      addTearDown(pool.close);
      final results = await Future.wait([
        for (var i = 0; i < 20; i++)
          pool.execute(r'select $1::int4 as v, $2::text as t',
              params: [i, 'ç$i'])
      ]);
      for (var i = 0; i < 20; i++) {
        expect(results[i].binary, isTrue);
        expect(results[i].rows.single, [i, 'ç$i']);
      }
      final rows =
          await pool.stream('select i from generate_series(1, 5) i').toList();
      expect(rows.map((r) => r['i']), [1, 2, 3, 4, 5]);
    });

    test('settings that cannot work together', () async {
      await expectLater(
          LibPqAsync.connect(conninfo, binary: true), throwsArgumentError);
      await expectLater(
          LibPqAsync.connect(conninfo,
              statementCacheSize: 1, binary: true, typed: false),
          throwsArgumentError);
      await expectLater(LibPqAsync.connect(conninfo, statementCacheSize: -1),
          throwsRangeError);
      expect(() => LibPqAsyncPool(conninfo, binary: true), throwsArgumentError);
    });
  });
}
