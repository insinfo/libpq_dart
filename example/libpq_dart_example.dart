import 'package:libpq_dart/libpq_dart.dart';

/// Set LIBPQ_PATH if libpq is not in the system's library search.
Future<void> main() async {
  const conninfo = 'host=localhost dbname=postgres user=postgres password=dart';

  // Asynchronous: the event loop keeps running while the query runs.
  final db = await LibPqAsync.connect(conninfo);
  final result = await db.execute(r'select $1::int + 1 as next', params: [41]);
  print('next = ${result.first['next']}');

  await db.transaction((tx) async {
    await tx.execute('create temporary table notes (body text)');
    await tx.execute(r'insert into notes values ($1)', params: ['hello']);
  });

  await for (final row in db.stream('select generate_series(1, 3) as n')) {
    print(row['n']);
  }
  await db.close();

  // Parallel queries: each connection of a pool has its own isolate.
  final pool = LibPqAsyncPool(conninfo, maxConnections: 4);
  final results = await Future.wait(
      [for (var i = 0; i < 4; i++) pool.execute('select pg_sleep(0.1)')]);
  print('${results.length} queries');
  await pool.close();

  // Synchronous: simple, for scripts. It blocks this isolate on every call.
  final sync = LibPq(conninfo);
  final rows = sync.execMapList('select version()');
  print(rows.first['version']);
  sync.dispose();
}
