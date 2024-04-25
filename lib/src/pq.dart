import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:libpq_dart/src/disposable.dart';
import 'package:libpq_dart/src/extensions/extensions.dart';
import 'package:libpq_dart/src/generated_bindings.dart';
import 'package:libpq_dart/src/pq_exception.dart';
import 'package:ffi/ffi.dart' as ffi;
import 'result.dart';

/// a LibPq wrapper
class LibPq implements IDisposable {
  Pointer<pg_conn> conn = nullptr;
  Pointer<Char> connInfo = nullptr;
  late LibpqBindings pq;
  int _protocol = 0;
  String _version = '';

  /// default is Utf8Codec(allowMalformed: true)
  Encoding encoding;

  int get protocol {
    return _protocol;
  }

  String get version {
    return _version;
  }

  LibPq(String info,
      {DynamicLibrary? dynamicLibrary, String? dllPath, Encoding? encoding})
      : encoding = encoding ?? Utf8Codec(allowMalformed: true) {
    final winPath = r'libpq.dll';
    final linuxPath = r'libpq.so';
    var path = winPath;
    if (Platform.isWindows) {
      path = winPath;
    } else if (Platform.isLinux) {
      path = linuxPath;
    } else {
      throw Exception('Platform not implemented');
    }
    if (dllPath != null) {
      path = dllPath;
    }

    final dl = dynamicLibrary ?? DynamicLibrary.open(path);
    pq = LibpqBindings(dl);
    connInfo = info.toNativeUtf8().cast();
    conn = pq.PQconnectdb(connInfo);

    if (pq.PQstatus(conn) != ConnStatusType.CONNECTION_OK) {
      throw LibPqException(
          pq.PQerrorMessage(conn).asDartString(encoding: encoding));
    }

    int v = pq.PQserverVersion(conn);
    int major = v ~/ 10000;
    v -= major * 10000;
    int minor = v ~/ 100;
    v -= minor * 100;

    _version = "${major}.${minor}.${v}";
    _protocol = pq.PQprotocolVersion(conn);
  }

  String get lastErrorMessage {
    return pq.PQerrorMessage(conn).asDartString(encoding: encoding);
  }

  int get libpqVersion {
    return pq.PQlibVersion();
  }

  /// Excecute a sql query
  /// Example:
  /// ```dart
  ///   final result = pq.exec('SELECT * from pg_catalog.pg_user limit 1');
  ///   print(result.asMapList());
  ///   result.dispose();
  /// ```
  PqResult exec(String query, {Allocator allocator = ffi.malloc}) {
    final queryP = query.toNativeUtf8(allocator: allocator);
    final resultP = pq.PQexec(conn, queryP.cast());
    final result = PqResult(this, resultP, query);

    //
    allocator.free(queryP);
    return result;
  }

  /// Excecute a sql query with params
  /// Example:
  ///```dart
  /// final res = pq.execParams(r'insert into knowledge values($1, $2);', ['1','Isaque']);
  /// print('res ${res.affectedRows}');
  /// res.dispose();
  ///```
  PqResult execParams(String query, List<String> params,
      {Allocator allocator = ffi.malloc}) {
    if (params.isEmpty) {
      return exec(query);
    }
    final queryP = query.toNativeUtf8();

    int nParams = params.length;

    int resultFormat = 0;
    // Allocate memory for an array params pointers
    Pointer<Pointer<Char>> paramValues = allocator<Pointer<Char>>(nParams);

    // Allocate memory for each param and store the pointer in the array params pointers
    for (int i = 0; i < nParams; i++) {
      paramValues[i] = params[i].toNativeUtf8().cast();
    }

    Pointer<Int> paramLengths = allocator<Int>(nParams);
    Pointer<Int> paramFormats = allocator<Int>(nParams);
    for (int i = 0; i < nParams; i++) {
      paramLengths[i] = params[i].length;
      paramFormats[i] = 0;
    }

    final resultP = pq.PQexecParams(conn, queryP.cast(), nParams, nullptr,
        paramValues, paramLengths, paramFormats, resultFormat);
    //free
    allocator.free(queryP);
    allocator.free(paramValues);
    allocator.free(paramLengths);
    allocator.free(paramFormats);

    final result = PqResult(this, resultP, query);

    return result;
  }

  /// Excecute a sql query return data as list of Map and dispose (Release Resources)
  List<Map<String, dynamic>> execMapList(String query) {
    PqResult? result;
    try {
      result = exec(query);
      final data = result.asMapList();
      return data;
    } catch (e) {
      rethrow;
    } finally {
      result?.dispose();
    }
  }

  /// Returns the field type as a string
  String pqftypename(int ftype) {
    final queryP = "select typname from pg_catalog.pg_type where oid = $ftype"
        .toNativeUtf8();
    final res = pq.PQexec(conn, queryP.cast());
    final status = pq.PQresultStatus(res);
    if (status != ExecStatusType.PGRES_COMMAND_OK &&
        status != ExecStatusType.PGRES_TUPLES_OK) {
      final message =
          pq.PQresultErrorMessage(res).asDartString(encoding: encoding);
      pq.PQclear(res);
      throw LibPqException(message);
    }
    final name = pq.PQgetvalue(res, 0, 0).asDartString(encoding: encoding);
    pq.PQclear(res);
    return name;
  }

  /// Begin a transaction
  void startTransaction() {
    exec("START TRANSACTION").dispose();
  }

  /// Comit transaction
  void comitTransaction() {
    exec("COMMIT").dispose();
  }

  /// Rollback a transaction
  void rollbackTransaction() {
    exec("ROLLBACK").dispose();
  }

  @override
  void dispose() {
    if (conn != nullptr) {
      pq.PQfinish(conn);
      conn = nullptr;
    }
  }
}
