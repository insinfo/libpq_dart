import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:libpq_dart/libpq_dart.dart';

/// Direct use of the generated bindings. Every call here blocks the isolate.
void main() {
  final pq = LibpqBindings(openLibpq());

  final conninfo = 'host=localhost dbname=postgres user=postgres password=dart'
      .toNativeUtf8();
  final conn = pq.PQconnectdb(conninfo.cast());
  malloc.free(conninfo);

  if (pq.PQstatus(conn) != ConnStatusType.CONNECTION_OK) {
    print(pq.PQerrorMessage(conn).asDartString());
    pq.PQfinish(conn);
    return;
  }

  final sql = 'select * from pg_catalog.pg_user limit 1'.toNativeUtf8();
  final res = pq.PQexec(conn, sql.cast());
  malloc.free(sql);

  if (pq.PQresultStatus(res) != ExecStatusType.PGRES_TUPLES_OK) {
    print('failed: ${pq.PQerrorMessage(conn).asDartString()}');
  } else {
    final fields = pq.PQnfields(res);
    for (var c = 0; c < fields; c++) {
      stdout.write('${pq.PQfname(res, c).asDartString()} | ');
    }
    stdout.writeln();
    for (var r = 0; r < pq.PQntuples(res); r++) {
      for (var c = 0; c < fields; c++) {
        stdout.write('${pq.PQgetvalue(res, r, c).asDartString()} | ');
      }
      stdout.writeln();
    }
  }

  pq.PQclear(res);
  pq.PQfinish(conn);
}
