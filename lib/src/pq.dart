import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart' as ffi;
import 'package:libpq_dart/src/disposable.dart';
import 'package:libpq_dart/src/extensions/extensions.dart';
import 'package:libpq_dart/src/generated_bindings.dart';
import 'package:libpq_dart/src/pq_exception.dart';

import 'library_loader.dart';
import 'native_params.dart';
import 'result.dart';

/// A synchronous libpq connection.
///
/// Every call blocks the isolate until libpq returns: connecting, and every
/// query, stop the event loop (timers, sockets, HTTP requests) for as long as
/// they take. Use it in command-line tools and scripts; in a server, or
/// wherever the event loop must keep running, use `LibPqAsync`.
class LibPq implements IDisposable {
  Pointer<pg_conn> conn = nullptr;

  /// Kept for compatibility: always `nullptr`, the string is freed after
  /// connecting.
  Pointer<Char> connInfo = nullptr;
  late LibpqBindings pq;
  int _protocol = 0;
  String _version = '';
  final Map<int, String> _typeNames = {};

  /// default is Utf8Codec(allowMalformed: true)
  Encoding encoding;

  int get protocol {
    return _protocol;
  }

  String get version {
    return _version;
  }

  /// Connects with a conninfo string (`host=... dbname=...` or a
  /// `postgresql://` URI). Opens libpq from [dynamicLibrary], [dllPath], the
  /// `LIBPQ_PATH` environment variable or the system's library search.
  LibPq(String info,
      {DynamicLibrary? dynamicLibrary, String? dllPath, Encoding? encoding})
      : encoding = encoding ?? const Utf8Codec(allowMalformed: true) {
    pq = LibpqBindings(dynamicLibrary ?? openLibpq(dllPath));
    conn = ffi.using(
        (arena) => pq.PQconnectdb(nativeString(info, this.encoding, arena)));

    if (pq.PQstatus(conn) != ConnStatusType.CONNECTION_OK) {
      final message = lastErrorMessage;
      // PQconnectdb returns a PGconn even when it fails.
      pq.PQfinish(conn);
      conn = nullptr;
      throw LibPqException(message);
    }

    int v = pq.PQserverVersion(conn);
    int major = v ~/ 10000;
    v -= major * 10000;
    int minor = v ~/ 100;
    v -= minor * 100;

    _version = "$major.$minor.$v";
    _protocol = pq.PQprotocolVersion(conn);
  }

  void _checkOpen() {
    if (conn == nullptr) {
      throw StateError('This connection was disposed');
    }
  }

  /// Whether the connection is usable. It turns false after the server closed
  /// the connection, once a call has noticed it.
  bool get isConnected =>
      conn != nullptr && pq.PQstatus(conn) == ConnStatusType.CONNECTION_OK;

  String get lastErrorMessage {
    if (conn == nullptr) return '';
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
    _checkOpen();
    final resultP = ffi.using(
        (arena) => pq.PQexec(conn, nativeString(query, encoding, arena)),
        allocator);
    return PqResult(this, resultP, query);
  }

  /// Excecute a sql query with params: `null` is SQL NULL, a `Uint8List` goes
  /// in binary, a `DateTime` in ISO 8601, any other value is its `toString()`.
  /// Example:
  ///```dart
  /// final res = pq.execParams(r'insert into knowledge values($1, $2);', ['1','Isaque']);
  /// print('res ${res.affectedRows}');
  /// res.dispose();
  ///```
  PqResult execParams(String query, List<Object?> params,
      {Allocator allocator = ffi.malloc}) {
    _checkOpen();
    final resultP = ffi.using((arena) {
      final native = NativeParams.allocate(params, encoding, arena);
      return pq.PQexecParams(
          conn,
          nativeString(query, encoding, arena),
          native.count,
          nullptr,
          native.values,
          native.lengths,
          native.formats,
          0);
    }, allocator);
    return PqResult(this, resultP, query);
  }

  /// Excecute a sql query return data as list of Map and dispose (Release Resources)
  List<Map<String, dynamic>> execMapList(String query) {
    final result = exec(query);
    try {
      return result.asMapList();
    } finally {
      result.dispose();
    }
  }

  /// Returns the field type as a string
  String pqftypename(int ftype) {
    final known = _typeNames[ftype];
    if (known != null) return known;
    final result =
        exec('select typname from pg_catalog.pg_type where oid = $ftype');
    try {
      if (result.empty) {
        throw LibPqException('Unknown type oid $ftype');
      }
      return _typeNames[ftype] = result.getValueAsString(0, 0);
    } finally {
      result.dispose();
    }
  }

  /// Begin a transaction
  void startTransaction() {
    exec("START TRANSACTION").dispose();
  }

  /// Commit transaction
  void commitTransaction() {
    exec("COMMIT").dispose();
  }

  /// Use [commitTransaction].
  @Deprecated('Use commitTransaction')
  void comitTransaction() => commitTransaction();

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
