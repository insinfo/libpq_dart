import 'dart:ffi';
import 'dart:io';
import 'package:freetype_dart/src/extensions/extensions.dart';
import 'package:freetype_dart/src/generated_bindings.dart';

//C:\tools\sigcheck.exe C:\msys64\mingw64\bin\libpq.dll
//dumpbin /dependents C:\msys64\mingw64\bin\libpq.dll
//pacman -S mingw-w64-x86_64-postgresql

void main(List<String> args) {
  var dl = DynamicLibrary.open(r'libpq\\bin\\libpq.dll');
  var pq = LibpqBindings(dl);
  var conninfo = 'user=dart password=dart host=127.0.0.1 dbname=postgres port=5435';
  var conn = pq.PQconnectdb(conninfo.toNativeUtf8().cast());
  if (pq.PQstatus(conn) != ConnStatusType.CONNECTION_OK)
    print(pq.PQerrorMessage(conn));

  var res = pq.PQexec(
      conn, "SELECT * from pg_catalog.pg_user limit 1".toNativeUtf8().cast());

  if (pq.PQresultStatus(res) != ExecStatusType.PGRES_TUPLES_OK) {
    print("failed: " + pq.PQerrorMessage(conn).toDartString());
    pq.PQclear(res);
    pq.PQfinish(conn);
  }

  var nFields = pq.PQnfields(res);
  for (var i = 0; i < nFields; i++) {
    stdout.write(" " + pq.PQfname(res, i).toDartString() + ' | ');
  }

  for (var i = 0; i < pq.PQntuples(res); i++) {
    print(' ');
    for (var j = 0; j < nFields; j++) {
      stdout.write(pq.PQgetvalue(res, i, j).toDartString() + ' | ');
    }
    print(' ');
  }

  pq.PQclear(res);
}
