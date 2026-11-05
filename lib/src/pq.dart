import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi;
import 'package:libpq_dart/src/disposable.dart';
import 'package:libpq_dart/src/extensions/extensions.dart';
import 'package:libpq_dart/src/generated_bindings.dart';
import 'package:libpq_dart/src/pq_exception.dart';

import 'library_loader.dart';
import 'native_params.dart';
import 'pq_async.dart' show PqNotification;
import 'pq_values.dart' show PqInfinity;
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

  /// What a date `DateTime` cannot represent reads as, in `PqResult.getTyped`
  /// and `PqResult.toColumnMaps`.
  PqInfinity infinity;

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
      {DynamicLibrary? dynamicLibrary,
      String? dllPath,
      Encoding? encoding,
      this.infinity = PqInfinity.toNull})
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
    _leaveCopyMode(resultP);
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

  /// A `COPY` through [exec]: without this the connection would stay in COPY
  /// mode, refusing every other command. [PqResult] then reports the status.
  void _leaveCopyMode(Pointer<pg_result> result) {
    if (result == nullptr) return;
    final status = pq.PQresultStatus(result);
    if (status == ExecStatusType.PGRES_COPY_IN) {
      ffi.using((arena) => pq.PQputCopyEnd(
          conn, nativeString('Use copyFrom for COPY', utf8, arena)));
      _drain();
    } else if (status == ExecStatusType.PGRES_COPY_OUT) {
      final slot = ffi.malloc<Pointer<Char>>();
      while (pq.PQgetCopyData(conn, slot, 0) > 0) {
        pq.PQfreemem(slot.value.cast());
      }
      ffi.malloc.free(slot);
      _drain();
    }
  }

  void _drain() {
    while (true) {
      final result = pq.PQgetResult(conn);
      if (result == nullptr) return;
      pq.PQclear(result);
    }
  }

  /// Runs a `COPY ... FROM STDIN`, sending [chunks] as they are; returns the
  /// rows written.
  int copyFrom(String sql, Iterable<List<int>> chunks) {
    _checkOpen();
    final start = ffi
        .using((arena) => pq.PQexec(conn, nativeString(sql, encoding, arena)));
    final startStatus = start == nullptr ? -1 : pq.PQresultStatus(start);
    if (startStatus != ExecStatusType.PGRES_COPY_IN) {
      _leaveCopyMode(start);
      if (startStatus == ExecStatusType.PGRES_COPY_OUT ||
          startStatus == ExecStatusType.PGRES_COMMAND_OK ||
          startStatus == ExecStatusType.PGRES_TUPLES_OK) {
        pq.PQclear(start);
        throw LibPqException('This statement is not a COPY ... FROM STDIN',
            sql: sql);
      }
      PqResult(this, start, sql).dispose();
      throw LibPqException('This statement is not a COPY ... FROM STDIN',
          sql: sql);
    }
    pq.PQclear(start);

    Object? sourceError;
    try {
      for (final chunk in chunks) {
        if (chunk.isEmpty) continue;
        final sent = ffi.using((arena) {
          final buffer = arena<Uint8>(chunk.length);
          buffer.asTypedList(chunk.length).setAll(0, chunk);
          return pq.PQputCopyData(conn, buffer.cast(), chunk.length);
        });
        if (sent != 1) break; // The result below has the server's error.
      }
    } catch (e) {
      sourceError = e;
    }
    ffi.using((arena) => pq.PQputCopyEnd(
        conn,
        sourceError == null
            ? nullptr
            : nativeString(
                'The source failed: $sourceError', encoding, arena)));
    final end = pq.PQgetResult(conn);
    final PqResult result;
    try {
      result = PqResult(this, end, sql);
    } finally {
      _drain();
    }
    final count = result.affectedRows;
    result.dispose();
    if (sourceError != null) throw sourceError;
    return count;
  }

  /// Runs a `COPY ... TO STDOUT` and returns all of its output.
  Uint8List copyTo(String sql) {
    _checkOpen();
    final start = ffi
        .using((arena) => pq.PQexec(conn, nativeString(sql, encoding, arena)));
    final startStatus = start == nullptr ? -1 : pq.PQresultStatus(start);
    if (startStatus != ExecStatusType.PGRES_COPY_OUT) {
      _leaveCopyMode(start);
      if (startStatus == ExecStatusType.PGRES_COPY_IN ||
          startStatus == ExecStatusType.PGRES_COMMAND_OK ||
          startStatus == ExecStatusType.PGRES_TUPLES_OK) {
        pq.PQclear(start);
        throw LibPqException('This statement is not a COPY ... TO STDOUT',
            sql: sql);
      }
      PqResult(this, start, sql).dispose();
      throw LibPqException('This statement is not a COPY ... TO STDOUT',
          sql: sql);
    }
    pq.PQclear(start);

    final out = BytesBuilder(copy: true);
    final slot = ffi.malloc<Pointer<Char>>();
    try {
      while (true) {
        final length = pq.PQgetCopyData(conn, slot, 0);
        if (length <= 0) break;
        out.add(slot.value.cast<Uint8>().asTypedList(length));
        pq.PQfreemem(slot.value.cast());
      }
    } finally {
      ffi.malloc.free(slot);
    }
    final end = pq.PQgetResult(conn);
    try {
      PqResult(this, end, sql).dispose();
    } finally {
      _drain();
    }
    return out.takeBytes();
  }

  /// The notifications received so far, after a `LISTEN`. Nothing arrives by
  /// itself here: call it again to look for new ones, or use `LibPqAsync.listen`.
  List<PqNotification> takeNotifications() {
    _checkOpen();
    if (pq.PQconsumeInput(conn) == 0) {
      throw LibPqException(lastErrorMessage.trim(), sqlState: '08006');
    }
    final notifications = <PqNotification>[];
    while (true) {
      final notification = pq.PQnotifies(conn);
      if (notification == nullptr) return notifications;
      final value = notification.ref;
      notifications.add(PqNotification(
          value.relname.asDartString(encoding: encoding),
          value.extra.asDartString(encoding: encoding),
          value.be_pid));
      pq.PQfreemem(notification.cast());
    }
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
