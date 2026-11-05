import 'dart:typed_data';

import 'package:libpq_dart/libpq_dart.dart';
import 'package:test/test.dart';

import 'test_config.dart';

void main() {
  late LibPq pq;

  setUp(() => pq = LibPq(conninfo));
  tearDown(() => pq.dispose());

  T withResult<T>(PqResult result, T Function(PqResult r) body) {
    try {
      return body(result);
    } finally {
      result.dispose();
    }
  }

  group('connection', () {
    test('a failed connection throws, with the reason', () {
      expect(
          () => LibPq('host=localhost port=1 dbname=x connect_timeout=2'),
          throwsA(isA<LibPqException>()
              .having((e) => e.message, 'message', isNotEmpty)));
    });

    test('a library that does not exist throws, naming it', () {
      expect(
          () => LibPq(conninfo, dllPath: 'does-not-exist.dll'),
          throwsA(isA<LibPqException>().having(
              (e) => e.message, 'message', contains('does-not-exist'))));
    });

    test('dispose can be called twice, and the connection is then refused', () {
      final other = LibPq(conninfo);
      expect(other.isConnected, isTrue);
      other.dispose();
      other.dispose();
      expect(other.isConnected, isFalse);
      expect(() => other.exec('select 1'), throwsStateError);
    });

    test('version and protocol', () {
      expect(pq.version, matches(RegExp(r'^\d+\.\d+\.\d+$')));
      expect(pq.protocol, 3);
      expect(pq.libpqVersion, greaterThan(90000));
    });
  });

  group('values', () {
    test('SQL NULL is null, not an empty string', () {
      withResult(pq.exec("select null::text as a, ''::text as b"), (r) {
        expect(r.isNull(0, 0), isTrue);
        expect(r.isNull(0, 1), isFalse);
        expect(r.getValue(0, 0), isNull);
        expect(r.getValue(0, 1), '');
        expect(r.asMapList().single, {'a': null, 'b': ''});
      });
    });

    test('affectedRows of a command without a count is 0', () {
      withResult(pq.exec('create temporary table t_a (id int)'), (r) {
        expect(r.affectedRows, 0);
        expect(r.commandTag, 'CREATE TABLE');
      });
      withResult(pq.exec('insert into t_a values (1), (2)'),
          (r) => expect(r.affectedRows, 2));
      withResult(
          pq.exec('select * from t_a'), (r) => expect(r.affectedRows, 2));
    });

    test('typed reads, boolean included', () {
      withResult(
          pq.exec('select true as a, false as b, 7 as c, 1.5::float8 as d'),
          (r) {
        expect(r.getBoolean(0, 0), isTrue);
        expect(r.getBoolean(0, 1), isFalse);
        expect(r.getInt(0, 2), 7);
        expect(r.getDouble(0, 3), 1.5);
      });
    });

    test('non-ASCII text round trips', () {
      const text = 'ação ☕ 日本語';
      withResult(
          pq.execParams(r'select $1::text as v, length($1) as n', [text]), (r) {
        expect(r.getValueAsString(0, 0), text);
        expect(r.getInt(0, 1), text.runes.length);
      });
    });

    test('getValueAsBytes is a copy that outlives the result', () {
      final result = pq.exec("select 'abc' as v");
      final bytes = result.getValueAsBytes(0, 0);
      result.dispose();
      pq.exec("select repeat('x', 100000)").dispose();
      expect(bytes, [97, 98, 99]);
    });

    test('a disposed result refuses to be read', () {
      final result = pq.exec('select 1');
      result.dispose();
      expect(() => result.getValue(0, 0), throwsStateError);
      expect(() => result.affectedRows, throwsStateError);
    });

    test('column names, indexes and types', () {
      withResult(pq.exec('select 1::int4 as a, 2::int8 as b'), (r) {
        expect(r.columnNames, ['a', 'b']);
        expect(r.columnIndex('b'), 1);
        expect(r.columnType(0), 23);
        expect(r.columnTypeName(1), 'int8');
        expect(r.getValueByColNameAsString(0, 'b'), '2');
        expect(() => r.columnIndex('c'), throwsA(isA<LibPqException>()));
        expect(() => r.getValue(5, 0), throwsA(isA<LibPqException>()));
      });
    });
  });

  group('parameters', () {
    test('null, numbers, booleans and dates', () {
      withResult(
          pq.execParams(
              r'select $1::text as a, $2::int as b, $3::bool as c, $4::timestamp as d',
              [null, 5, true, DateTime.utc(2024, 3, 1, 12)]), (r) {
        expect(r.getValue(0, 0), isNull);
        expect(r.getInt(0, 1), 5);
        expect(r.getBoolean(0, 2), isTrue);
        expect(r.getValue(0, 3), '2024-03-01 12:00:00');
      });
    });

    test('binary data with zeros round trips through bytea', () {
      final data = Uint8List.fromList([0, 1, 0, 255, 127, 0]);
      withResult(pq.execParams(r'select $1::bytea as v', [data]), (r) {
        expect(r.getBytea(0, 0), data);
      });
    });

    test('a value is not read as SQL: quotes are safe', () {
      const evil = "'; drop table pg_class; --";
      withResult(pq.execParams(r'select $1::text as v', [evil]),
          (r) => expect(r.getValue(0, 0), evil));
    });
  });

  group('errors', () {
    test('carry SQLSTATE, severity and the statement', () {
      expect(
          () => pq.exec('select * from table_that_does_not_exist'),
          throwsA(isA<LibPqException>()
              .having((e) => e.sqlState, 'sqlState', '42P01')
              .having((e) => e.severity, 'severity', 'ERROR')
              .having((e) => e.sql, 'sql', contains('does_not_exist'))
              .having((e) => '$e', 'toString', contains('[42P01]'))));
    });

    test('the connection goes on after an error', () {
      expect(() => pq.exec('select 1/0'), throwsA(isA<LibPqException>()));
      withResult(pq.exec('select 2'), (r) => expect(r.getInt(0, 0), 2));
    });
  });

  group('transactions', () {
    test('commit and rollback', () {
      pq.exec('create temporary table t_tx (id int)').dispose();
      pq.startTransaction();
      pq.exec('insert into t_tx values (1)').dispose();
      pq.rollbackTransaction();
      pq.startTransaction();
      pq.exec('insert into t_tx values (2)').dispose();
      pq.commitTransaction();
      expect(pq.execMapList('select id from t_tx'), [
        {'id': '2'}
      ]);
    });
  });

  group('large objects', () {
    test('write, read back, size, delete', () {
      final lo = LargeObject(pq);
      final oid = lo.create();
      final data = Uint8List.fromList(List.generate(1000, (i) => i % 256));

      lo.open(oid);
      expect(lo.write(data, data.length), data.length);
      expect(lo.size(), data.length);
      final read = Uint8List(data.length);
      expect(lo.read(read, read.length), data.length);
      expect(read, data);
      lo.close();

      lo.delete(oid);
      expect(() => lo.open(oid), throwsA(isA<LibPqException>()));
    });

    test('a length past the buffer is refused', () {
      final lo = LargeObject(pq);
      final oid = lo.create();
      lo.open(oid);
      expect(() => lo.write(Uint8List(1), 2), throwsRangeError);
      expect(() => lo.read(Uint8List(1), 2), throwsRangeError);
      lo.close();
      lo.delete(oid);
    });

    test('reading or writing a closed object is refused', () {
      final lo = LargeObject(pq);
      expect(() => lo.read(Uint8List(1), 1), throwsStateError);
      expect(() => lo.size(), throwsStateError);
    });
  });
}
