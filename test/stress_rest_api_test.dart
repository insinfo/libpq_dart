// A REST API under load, as it runs in production: several server isolates
// sharing a port, each with its own pool, and several client isolates sending
// requests at once. It checks what load breaks: wrong replies, lost updates, a
// connection handed to two requests, connections left open, a blocked event loop.
//
// Small by default, so it can run in the CI. Heavier:
//   LIBPQ_STRESS_SERVERS=4 LIBPQ_STRESS_CLIENTS=6 LIBPQ_STRESS_REQUESTS=500 dart test -t stress
@Tags(['stress'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:libpq_dart/libpq_dart.dart';
import 'package:test/test.dart';

import 'test_config.dart';

int _env(String name, int fallback) =>
    int.tryParse(Platform.environment[name] ?? '') ?? fallback;

const _appName = 'libpq_stress';

class _ServerStart {
  _ServerStart(this.conninfo, this.poolSize, this.ready, this.port);
  final String conninfo;
  final int poolSize;
  final SendPort ready;
  final int port;
}

/// One server isolate: an HTTP server sharing the port, with its own pool.
Future<void> _serverMain(_ServerStart start) async {
  final pool = LibPqAsyncPool(start.conninfo,
      maxConnections: start.poolSize,
      acquireTimeout: const Duration(seconds: 60),
      queryTimeout: const Duration(seconds: 60),
      sessionStatements: ["SET application_name TO '$_appName'"]);
  final http = await HttpServer.bind(InternetAddress.loopbackIPv4, start.port,
      shared: true);

  // How long this isolate's event loop stayed blocked.
  var longestStall = Duration.zero;
  final clock = Stopwatch()..start();
  var last = clock.elapsed;
  final ticker = Timer.periodic(const Duration(milliseconds: 5), (_) {
    final gap = clock.elapsed - last;
    if (gap > longestStall) longestStall = gap;
    last = clock.elapsed;
  });

  final commands = ReceivePort();
  start.ready.send([commands.sendPort, http.port]);

  commands.listen((message) async {
    ticker.cancel();
    await http.close(force: true);
    await pool.close();
    commands.close();
    (message as SendPort).send(longestStall.inMilliseconds);
  });

  http.listen((request) async {
    final response = request.response;
    try {
      // Always read it: a connection is not reused before its body was read.
      final raw = await utf8.decodeStream(request);
      final body = await _route(pool, request, raw);
      response.statusCode = body.$1;
      response.headers.contentType = ContentType.json;
      // A 204 has no body.
      if (body.$2 != null) response.write(jsonEncode(body.$2));
    } on LibPqException catch (e) {
      response.statusCode = e.sqlState == '23505' ? 409 : 500;
      response.write(jsonEncode({'error': e.message, 'state': e.sqlState}));
    } catch (e) {
      response.statusCode = 500;
      response.write(jsonEncode({'error': '$e'}));
    }
    await response.close();
  });
}

Future<(int, Object?)> _route(
    LibPqAsyncPool pool, HttpRequest request, String raw) async {
  final segments = request.uri.pathSegments;
  final method = request.method;
  Map<String, dynamic> body() => jsonDecode(raw) as Map<String, dynamic>;

  if (segments.first == 'items') {
    if (segments.length == 1 && method == 'POST') {
      final data = body();
      final r = await pool.execute(
          r'insert into stress_items (client, seq, name, tags, attrs, created_at) '
          r'values ($1, $2, $3, $4, $5, now()) returning id',
          params: [
            data['client'],
            data['seq'],
            data['name'],
            data['tags'],
            data['attrs']
          ]);
      return (201, {'id': r.first['id']});
    }
    if (segments.length == 1 && method == 'GET') {
      final limit = int.parse(request.uri.queryParameters['limit'] ?? '20');
      final r = await pool.execute(
          r'select id, name, tags, attrs, created_at from stress_items '
          r'order by id desc limit $1',
          params: [limit]);
      return (
        200,
        [
          for (final row in r)
            {
              'id': row['id'] as int,
              'name': row['name'] as String,
              'tags': row['tags'] as List,
              'attrs': row['attrs'] as Map,
              'created_at': (row['created_at'] as DateTime).toIso8601String(),
            }
        ]
      );
    }
    final id = int.parse(segments[1]);
    if (method == 'GET') {
      final r = await pool.execute(
          r'select id, client, seq, name, tags, attrs, version from stress_items where id = $1',
          params: [id]);
      if (r.isEmpty) return (404, {'error': 'not found'});
      return (200, r.first.toColumnMap());
    }
    if (method == 'PUT') {
      final data = body();
      final r = await pool.execute(
          r'update stress_items set name = $1, version = version + 1 '
          r'where id = $2 returning version',
          params: [data['name'], id]);
      if (r.isEmpty) return (404, {'error': 'not found'});
      return (200, {'version': r.first['version']});
    }
    if (method == 'DELETE') {
      final r = await pool
          .execute(r'delete from stress_items where id = $1', params: [id]);
      return (r.affectedRows == 1 ? 204 : 404, null);
    }
  }
  // A transaction with a lock: every increment must count, in any order.
  if (segments.first == 'counter' && method == 'POST') {
    final value = await pool.transaction((tx) async {
      final r = await tx
          .execute('select value from stress_counter where id = 1 for update');
      final next = (r.first['value'] as int) + 1;
      await tx.execute(r'update stress_counter set value = $1 where id = 1',
          params: [next]);
      return next;
    });
    return (200, {'value': value});
  }
  // A failed savepoint must not cost the transaction.
  if (segments.first == 'savepoint' && method == 'POST') {
    final data = body();
    final saved = await pool.transaction((tx) async {
      await tx.execute(
          r'insert into stress_audit (client, seq, step) values ($1, $2, $3)',
          params: [data['client'], data['seq'], 'before']);
      try {
        await tx.savepoint((sp) => sp.execute('select 1/0'));
      } on LibPqException catch (_) {
        // Expected.
      }
      await tx.execute(
          r'insert into stress_audit (client, seq, step) values ($1, $2, $3)',
          params: [data['client'], data['seq'], 'after']);
      return true;
    });
    return (200, {'saved': saved});
  }
  // A rollback must leave nothing.
  if (segments.first == 'rollback' && method == 'POST') {
    try {
      await pool.transaction((tx) async {
        await tx.execute(
            r"insert into stress_audit (client, seq, step) values (-1, 0, 'never')");
        throw StateError('roll back');
      });
    } on StateError catch (_) {
      return (200, {'rolled_back': true});
    }
  }
  // Echo through the database: a reply for another request would show here.
  if (segments.first == 'echo') {
    final value = request.uri.queryParameters['v']!;
    final r = await pool.execute(r'select $1::text as v, pg_backend_pid() as p',
        params: [value]);
    return (200, {'v': r.first['v']});
  }
  if (segments.first == 'slow') {
    await pool.execute('select pg_sleep(0.02)');
    return (200, {'ok': true});
  }
  if (segments.first == 'report') {
    final r = await pool
        .execute('select g, md5(g::text) as h from generate_series(1, 2000) g');
    return (200, {'rows': r.length, 'last': r.rows.last[0]});
  }
  if (segments.first == 'error') {
    await pool.execute('select * from table_that_does_not_exist');
  }
  if (segments.first == 'bulk' && method == 'POST') {
    final data = body();
    final client = data['client'] as int;
    final seq = data['seq'] as int;
    final n = await pool.copyRows(
        'public.stress_audit',
        ['client', 'seq', 'step'],
        Iterable.generate(50, (i) => [client, seq, 'bulk $i']));
    return (201, {'written': n});
  }
  return (404, {'error': 'no route'});
}

class _ClientStart {
  _ClientStart(this.port, this.client, this.requests, this.inFlight, this.done);
  final int port;
  final int client;
  final int requests;
  final int inFlight;
  final SendPort done;
}

/// One client isolate: [inFlight] requests at once. Returns what went wrong.
Future<void> _clientMain(_ClientStart start) async {
  final http = HttpClient()..maxConnectionsPerHost = start.inFlight;
  final problems = <String>[];
  var counterCalls = 0;
  var savepoints = 0;
  var bulks = 0;
  var created = 0;
  var deleted = 0;
  var next = 0;

  Future<(int, dynamic)> call(String method, String path,
      [Map<String, Object?>? body]) async {
    // A request that never ends is a problem to report, not a test that hangs.
    return () async {
      final request = await http.openUrl(
          method, Uri.parse('http://127.0.0.1:${start.port}$path'));
      if (body != null) request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      return (response.statusCode, text.isEmpty ? null : jsonDecode(text));
    }()
        .timeout(const Duration(seconds: 90));
  }

  void check(bool ok, String what) {
    if (!ok && problems.length < 20) problems.add(what);
  }

  Future<void> scenario(int seq) async {
    final name = 'name ${start.client}/$seq ação ☕';
    switch (seq % 9) {
      case 0:
        // The whole life of an item, each step checking the last.
        final (s1, b1) = await call('POST', '/items', {
          'client': start.client,
          'seq': seq,
          'name': name,
          'tags': ['a', 'b"c', null],
          'attrs': {'n': seq}
        });
        check(s1 == 201, 'create: $s1 $b1');
        final id = b1['id'] as int;
        created++;
        final (s2, b2) = await call('GET', '/items/$id');
        check(
            s2 == 200 &&
                b2['client'] == start.client &&
                b2['seq'] == seq &&
                b2['name'] == name &&
                b2['tags'].toString() == '[a, b"c, null]' &&
                b2['attrs']['n'] == seq,
            'read: $s2 $b2');
        final (s3, b3) = await call('PUT', '/items/$id', {'name': '$name!'});
        check(s3 == 200 && b3['version'] == 2, 'update: $s3 $b3');
        final (s4, b4) = await call('GET', '/items/$id');
        check(s4 == 200 && b4['name'] == '$name!' && b4['version'] == 2,
            'read after update: $s4 $b4');
        if (seq.isEven) {
          final (s5, _) = await call('DELETE', '/items/$id');
          check(s5 == 204, 'delete: $s5');
          deleted++;
          final (s6, _) = await call('GET', '/items/$id');
          check(s6 == 404, 'read after delete: $s6');
        }
      case 1:
        final (s, b) = await call('POST', '/counter');
        check(s == 200 && b['value'] is int, 'counter: $s $b');
        counterCalls++;
      case 2:
        final value = 'v-${start.client}-$seq';
        final (s, b) = await call('GET', '/echo?v=$value');
        check(s == 200 && b['v'] == value,
            'a reply for another request: asked $value, got $b');
      case 3:
        final (s, b) = await call(
            'POST', '/savepoint', {'client': start.client, 'seq': seq});
        check(s == 200 && b['saved'] == true, 'savepoint: $s $b');
        savepoints++;
      case 4:
        final (s, b) = await call('POST', '/rollback');
        check(s == 200 && b['rolled_back'] == true, 'rollback: $s $b');
      case 5:
        final (s, b) = await call('GET', '/report');
        check(s == 200 && b['rows'] == 2000 && b['last'] == 2000,
            'report: $s $b');
      case 6:
        final (s, b) = await call('GET', '/error');
        check(s == 500 && b['state'] == '42P01', 'error: $s $b');
      case 7:
        final (s, b) =
            await call('POST', '/bulk', {'client': start.client, 'seq': seq});
        check(s == 201 && b['written'] == 50, 'bulk: $s $b');
        bulks++;
      case 8:
        final (s, b) = await call('GET', '/slow');
        check(s == 200 && b['ok'] == true, 'slow: $s $b');
        final (s2, b2) = await call('GET', '/items?limit=10');
        check(s2 == 200 && b2 is List, 'list: $s2 $b2');
    }
  }

  Future<void> worker() async {
    while (next < start.requests) {
      final seq = next++;
      try {
        await scenario(seq);
      } catch (e) {
        check(false, 'request $seq: $e');
      }
    }
  }

  await Future.wait([for (var i = 0; i < start.inFlight; i++) worker()]);
  http.close(force: true);
  start.done.send({
    'problems': problems,
    'counter': counterCalls,
    'savepoints': savepoints,
    'bulks': bulks,
    'created': created,
    'deleted': deleted,
  });
}

void main() {
  final servers = _env('LIBPQ_STRESS_SERVERS', 2);
  final clients = _env('LIBPQ_STRESS_CLIENTS', 3);
  final requests = _env('LIBPQ_STRESS_REQUESTS', 150);
  final inFlight = _env('LIBPQ_STRESS_IN_FLIGHT', 8);
  final poolSize = _env('LIBPQ_STRESS_POOL', 4);

  late LibPqAsync admin;

  setUpAll(() async {
    admin = await LibPqAsync.connect(conninfo);
    await admin.execute('''
      drop table if exists stress_items, stress_audit, stress_counter;
      create table stress_items (
        id bigserial primary key, client int not null, seq int not null,
        name text not null, tags text[], attrs jsonb,
        created_at timestamptz not null, version int not null default 1);
      create table stress_audit (client int, seq int, step text);
      create table stress_counter (id int primary key, value int not null);
      insert into stress_counter values (1, 0);
    ''');
  });

  tearDownAll(() async {
    await admin.execute(
        'drop table if exists stress_items, stress_audit, stress_counter');
    await admin.close();
  });

  Future<int> serverConnections() async {
    final r = await admin.execute(
        'select count(*) as n from pg_stat_activity where application_name = \$1',
        params: [_appName]);
    return r.first['n'] as int;
  }

  test(
      '$servers servers, $clients clients x $inFlight in flight, '
      '$requests requests each', () async {
    final done = ReceivePort();
    final ready = ReceivePort();
    final readyEvents = StreamIterator(ready);
    final serverPorts = <SendPort>[];
    var port = 0;
    for (var i = 0; i < servers; i++) {
      await Isolate.spawn(
          _serverMain, _ServerStart(conninfo, poolSize, ready.sendPort, port),
          onError: done.sendPort);
      await readyEvents.moveNext();
      final message = readyEvents.current as List;
      serverPorts.add(message[0] as SendPort);
      // The first server chooses the port; the others share it.
      port = message[1] as int;
    }

    final results = <Map<dynamic, dynamic>>[];
    final finished = Completer<void>();
    done.listen((message) {
      // onError sends the error and its stack as a list.
      if (message is List) {
        if (!finished.isCompleted) {
          finished.completeError(StateError('A client died: $message'));
        }
        return;
      }
      results.add(message as Map);
      if (results.length == clients && !finished.isCompleted) {
        finished.complete();
      }
    });

    final watch = Stopwatch()..start();
    for (var i = 0; i < clients; i++) {
      await Isolate.spawn(
          _clientMain, _ClientStart(port, i, requests, inFlight, done.sendPort),
          onError: done.sendPort);
    }
    await finished.future.timeout(const Duration(minutes: 8));
    watch.stop();
    done.close();

    final stalls = <int>[];
    for (final server in serverPorts) {
      final reply = ReceivePort();
      server.send(reply.sendPort);
      stalls.add(await reply.first as int);
    }
    await readyEvents.cancel();
    ready.close();

    // The connections close asynchronously.
    var left = await serverConnections();
    for (var i = 0; i < 50 && left > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      left = await serverConnections();
    }

    final total = clients * requests;
    // ignore: avoid_print
    print('$total scenarios in ${watch.elapsed.inMilliseconds} ms '
        '(${(total / (watch.elapsedMilliseconds / 1000)).round()}/s); '
        'longest event loop stall per server: $stalls ms');

    final problems = [for (final r in results) ...(r['problems'] as List)];
    expect(problems, isEmpty, reason: problems.take(5).join('\n'));

    int sum(String key) => results.fold<int>(0, (a, r) => a + (r[key] as int));

    // Lost updates: every committed increment must be there.
    final counter =
        await admin.execute('select value from stress_counter where id = 1');
    expect(counter.first['value'], sum('counter'));

    // Each savepoint request kept both of its steps.
    final steps = await admin.execute(
        "select count(*) filter (where step = 'before') as b, "
        "count(*) filter (where step = 'after') as a, "
        "count(*) filter (where step = 'never') as n, "
        "count(*) filter (where step like 'bulk %') as k from stress_audit");
    final row = steps.first;
    expect(row['b'], sum('savepoints'));
    expect(row['a'], sum('savepoints'));
    expect(row['n'], 0, reason: 'a rolled back insert was saved');
    expect(row['k'], sum('bulks') * 50);

    final items = await admin.execute('select count(*) as n from stress_items');
    expect(items.first['n'], sum('created') - sum('deleted'));

    expect(left, 0, reason: 'connections left open after the servers closed');
    // The servers kept answering: their event loops were never blocked for
    // long. Far more than a query takes, so a blocking call would show.
    expect(stalls, everyElement(lessThan(2000)));
  }, timeout: const Timeout(Duration(minutes: 10)));
}
