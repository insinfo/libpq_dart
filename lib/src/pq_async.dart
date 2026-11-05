import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'extensions/extensions.dart';
import 'generated_bindings.dart';
import 'library_loader.dart';
import 'native_params.dart';
import 'pq_exception.dart';
import 'result.dart' show exceptionFromResult;

/// The result of a query run by [LibPqAsync], held in Dart memory: there is
/// nothing to dispose.
class PqAsyncResult extends Iterable<PqRow> {
  /// The column names.
  final List<String> columns;

  /// The type oid of each column.
  final List<int> columnTypes;

  /// The values, one list per row, as the server's text; SQL NULL is `null`.
  final List<List<String?>> rows;

  /// The command tag (`INSERT 0 1`, `SELECT 3`...).
  final String commandTag;

  /// The rows affected by the command, or returned by a `SELECT`; 0 for a
  /// command that has no such count.
  final int affectedRows;

  PqAsyncResult._(this.columns, this.columnTypes, this.rows, this.commandTag,
      this.affectedRows);

  late final Map<String, int> _indexes = {
    for (var i = 0; i < columns.length; i++) columns[i]: i
  };

  @override
  int get length => rows.length;

  @override
  bool get isEmpty => rows.isEmpty;

  @override
  Iterator<PqRow> get iterator =>
      rows.map((values) => PqRow._(this, values)).iterator;

  /// The rows as maps of column name to text.
  List<Map<String, String?>> toMaps() => [
        for (final row in rows)
          {for (var c = 0; c < columns.length; c++) columns[c]: row[c]}
      ];
}

/// One row of a [PqAsyncResult], or of [LibPqAsync.stream].
class PqRow {
  final PqAsyncResult _result;

  /// The values as the server's text; SQL NULL is `null`.
  final List<String?> values;

  PqRow._(this._result, this.values);

  /// The value of a column, by name.
  String? operator [](String column) {
    final index = _result._indexes[column];
    if (index == null) throw LibPqException('Column $column not found!');
    return values[index];
  }

  /// The bytes of a `bytea` column, by name; `null` for SQL NULL.
  Uint8List? bytea(String column) {
    final text = this[column];
    return text == null ? null : decodeBytea(text);
  }

  /// The row as a map of column name to text.
  Map<String, String?> toMap() => {
        for (var c = 0; c < _result.columns.length; c++)
          _result.columns[c]: values[c]
      };

  @override
  String toString() => toMap().toString();
}

/// What runs statements inside a [LibPqAsync.transaction].
abstract class PqSession {
  /// Runs [sql]. In [params], `null` is SQL NULL, a `Uint8List` goes in binary,
  /// a `DateTime` in ISO 8601, and any other value is its `toString()`.
  Future<PqAsyncResult> execute(String sql,
      {List<Object?> params = const [], Duration? timeout});
}

/// An asynchronous libpq connection: the event loop keeps running while it
/// connects and while a query runs.
///
/// libpq blocks the thread that calls it, and Dart cannot watch its socket
/// without native code. So each connection has its own isolate, where the
/// blocking calls happen; this class talks to it through messages and decodes
/// nothing itself. Commands run one at a time, in the order they are called;
/// for parallel queries use more connections, or `LibPqAsyncPool`.
///
/// ```dart
/// final db = await LibPqAsync.connect('host=localhost dbname=app user=app');
/// final result = await db.execute(r'select name from users where id = $1',
///     params: [1]);
/// print(result.first['name']);
/// await db.close();
/// ```
class LibPqAsync implements PqSession {
  LibPqAsync._(
      this._libraryPath,
      this._cancelAddress,
      this.serverVersion,
      this.protocol,
      this.libpqVersion,
      this._port,
      this._toWorker,
      this._isolate);

  final String? _libraryPath;
  final int _cancelAddress;

  /// The server version (`16.7.0`).
  final String serverVersion;

  /// The protocol version of the connection.
  final int protocol;

  /// The version of the libpq in use, as `PQlibVersion` gives it.
  final int libpqVersion;

  final RawReceivePort _port;
  final SendPort _toWorker;
  final Isolate _isolate;

  bool _closed = false;
  bool _workerExited = false;
  Object? _lostBecause;
  Future<void>? _closing;
  int _nextId = 1;
  final Map<int, void Function(Object? message)> _waiting = {};
  final Set<Future<void>> _cancels = {};

  /// The end of the queue: commands and transactions run one at a time.
  Future<void> _tail = Future<void>.value();

  /// Marks the zone of a [transaction] callback.
  static final Object _transactionKey = Object();

  /// Whether the connection can run commands. It turns false after [close],
  /// and after the server closed the connection, once a command noticed it.
  bool get isConnected => !_closed && _lostBecause == null;

  /// Connects, in a new isolate, without blocking this one.
  ///
  /// [conninfo] is a libpq connection string or `postgresql://` URI.
  /// [connectTimeout] applies when it has no `connect_timeout` of its own
  /// (libpq rounds a value of 1 s up to 2 s). [libraryPath] overrides the
  /// `LIBPQ_PATH` environment variable and the system's library search.
  /// [encoding] decodes the values; it must match `client_encoding`.
  static Future<LibPqAsync> connect(
    String conninfo, {
    Duration connectTimeout = const Duration(seconds: 15),
    String? libraryPath,
    Encoding encoding = const Utf8Codec(allowMalformed: true),
  }) async {
    final ready = Completer<List<Object?>>();
    final port = RawReceivePort();
    void Function(Object?) handler = (message) {};
    port.handler = (Object? message) => handler(message);
    handler = (message) {
      // The isolate's exit sends null, its uncaught errors two strings.
      if (!ready.isCompleted) {
        ready.complete(message is List ? message.cast() : const <Object?>[]);
      }
    };

    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
          _workerMain,
          _WorkerStart(port.sendPort, conninfo, connectTimeout.inSeconds,
              libraryPath, encoding),
          debugName: 'libpq connection',
          errorsAreFatal: true,
          onExit: port.sendPort,
          onError: port.sendPort);
    } catch (_) {
      port.close();
      rethrow;
    }

    final message = await ready.future;
    if (message.isEmpty || message[0] != _Reply.connected) {
      port.close();
      isolate.kill(priority: Isolate.immediate);
      throw _errorFromMessage(message);
    }
    final connection = LibPqAsync._(
        libraryPath,
        message[2] as int,
        message[3] as String,
        message[4] as int,
        message[5] as int,
        port,
        message[1] as SendPort,
        isolate);
    handler = connection._onMessage;
    // Idle, the connection does not keep the process running.
    port.keepIsolateAlive = false;
    return connection;
  }

  void _onMessage(Object? message) {
    if (message is List && message.isNotEmpty && message[0] is int) {
      final waiter = _waiting[message[0] as int];
      if (waiter != null) waiter(message);
      return;
    }
    // onExit sends null, onError a list of two strings.
    _workerGone(message == null
        ? LibPqException('The connection isolate ended')
        : LibPqException('The connection isolate failed: $message'));
  }

  void _workerGone(Object error) {
    _lostBecause ??= error;
    _workerExited = true;
    final waiters = _waiting.values.toList();
    _waiting.clear();
    for (final waiter in waiters) {
      waiter(_WorkerGone(error));
    }
    _port.close();
  }

  /// Sends a command and returns its first reply through [onReply].
  int _send(List<Object?> command, void Function(Object? message) onReply) {
    final id = _nextId++;
    _waiting[id] = onReply;
    _port.keepIsolateAlive = true;
    _toWorker.send([id, ...command]);
    return id;
  }

  void _done(int id) {
    _waiting.remove(id);
    if (_waiting.isEmpty && !_workerExited) _port.keepIsolateAlive = false;
  }

  /// Runs [operation] after everything queued before it.
  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  void _checkUsable() {
    if (_closed) throw StateError('This connection was closed');
    _checkNotLost();
  }

  void _checkNotLost() {
    final lost = _lostBecause;
    if (lost != null) {
      throw LibPqException('The connection was lost: $lost');
    }
  }

  @override
  Future<PqAsyncResult> execute(String sql,
      {List<Object?> params = const [], Duration? timeout}) async {
    if (Zone.current[_transactionKey] == this) {
      throw StateError('Inside a transaction, run statements through the '
          'session its callback receives: this one would wait for the '
          'transaction to end');
    }
    _checkUsable();
    return _enqueue(() => _run(sql, params, timeout));
  }

  Future<PqAsyncResult> _run(
      String sql, List<Object?> params, Duration? timeout) async {
    // Not _checkUsable: what was queued before close() still runs.
    _checkNotLost();
    final completer = Completer<PqAsyncResult>();
    final normalized = [for (final p in params) normalizeParam(p)];
    late int id;
    id = _send([_Command.execute, sql, normalized], (message) {
      _done(id);
      if (message is _WorkerGone) {
        completer.completeError(
            LibPqException('The connection was lost: ${message.error}'));
        return;
      }
      final reply = message as List<Object?>;
      _noteStatus(reply);
      if (reply[1] == _Reply.error) {
        completer.completeError(_errorFromReply(reply[3] as List<Object?>));
      } else {
        completer.complete(_resultFromReply(reply[3] as List<Object?>));
      }
    });
    if (timeout == null) return completer.future;

    // libpq cannot be interrupted from here: the server is asked to cancel,
    // and the command ends with its error.
    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      unawaited(cancel());
    });
    try {
      return await completer.future;
    } on LibPqException catch (e) {
      if (timedOut && e.sqlState == '57014') {
        throw TimeoutException('The query was cancelled', timeout);
      }
      rethrow;
    } finally {
      timer.cancel();
    }
  }

  void _noteStatus(List<Object?> reply) {
    if (reply[2] == false && _lostBecause == null) {
      _lostBecause = 'the server closed the connection';
    }
  }

  /// Runs [sql] in libpq's single row mode and delivers rows as they arrive,
  /// so a large result does not have to fit in memory. Rows are read ahead in
  /// batches of [batchSize], and only when the listener wants them (pausing the
  /// stream stops reading). Cancelling the subscription cancels the query.
  /// Other commands on this connection wait until the stream ends.
  Stream<PqRow> stream(String sql,
      {List<Object?> params = const [], int batchSize = 256}) {
    RangeError.checkNotNegative(batchSize - 1, 'batchSize - 1');
    if (_closed) {
      return Stream.error(StateError('This connection was closed'));
    }
    final inTransaction = Zone.current[_transactionKey] == this;
    late StreamController<PqRow> controller;
    var started = false;
    var finished = false;
    var awaitingBatch = false;
    int? id;
    final ended = Completer<void>();

    void finish([Object? error, StackTrace? stack]) {
      if (finished) return;
      finished = true;
      if (id != null) _done(id!);
      if (error != null) controller.addError(error, stack);
      unawaited(controller.close());
      if (!ended.isCompleted) ended.complete();
    }

    void requestBatch() {
      if (finished || awaitingBatch || controller.isPaused) return;
      awaitingBatch = true;
      _toWorker.send([id, _Command.streamNext, batchSize]);
    }

    PqAsyncResult? shape;
    void onReply(Object? message) {
      if (message is _WorkerGone) {
        finish(LibPqException('The connection was lost: ${message.error}'));
        return;
      }
      final reply = message as List<Object?>;
      _noteStatus(reply);
      awaitingBatch = false;
      if (reply[1] == _Reply.error) {
        finish(_errorFromReply(reply[3] as List<Object?>));
        return;
      }
      final data = reply[3] as List<Object?>;
      final rows = (data[2] as List).cast<List<String?>>();
      shape ??= PqAsyncResult._((data[0] as List).cast<String>(),
          (data[1] as List).cast<int>(), const [], '', 0);
      for (final row in rows) {
        controller.add(PqRow._(shape!, row));
      }
      if (reply[1] == _Reply.streamEnd) {
        finish();
      } else {
        requestBatch();
      }
    }

    void start() {
      started = true;
      Future<void> body() {
        if (finished) return Future<void>.value();
        try {
          _checkNotLost();
        } catch (e, s) {
          finish(e, s);
          return ended.future;
        }
        final normalized = [for (final p in params) normalizeParam(p)];
        awaitingBatch = true;
        id = _send([_Command.streamStart, sql, normalized, batchSize], onReply);
        return ended.future;
      }

      // Inside a transaction the transaction already holds the connection.
      if (inTransaction) {
        body();
      } else {
        unawaited(_enqueue(body));
      }
    }

    controller = StreamController<PqRow>(
      onListen: start,
      onResume: requestBatch,
      onCancel: () {
        if (!started || finished) {
          finish();
          return null;
        }
        // The rest of the result is discarded: the server is asked to stop,
        // and the worker reads what it had already sent.
        unawaited(cancel());
        _toWorker.send([id, _Command.streamCancel]);
        finished = true;
        final waiting = id;
        _waiting[waiting!] = (message) {
          _done(waiting);
          if (message is List) _noteStatus(message);
          if (!ended.isCompleted) ended.complete();
        };
        return ended.future;
      },
    );
    return controller.stream;
  }

  /// Runs [action] in a transaction: `BEGIN` before it, `COMMIT` after it, and
  /// `ROLLBACK` if it throws. The connection is held meanwhile, so commands
  /// from other callers wait. Inside [action], use the session it receives.
  Future<T> transaction<T>(Future<T> Function(PqSession session) action) async {
    if (Zone.current[_transactionKey] == this) {
      throw StateError('Transactions on one connection cannot be nested');
    }
    _checkUsable();
    return _enqueue(() async {
      await _run('BEGIN', const [], null);
      final session = _TransactionSession(this);
      final T value;
      try {
        value = await runZoned(() => action(session),
            zoneValues: {_transactionKey: this});
      } catch (_) {
        session._ended = true;
        try {
          await _run('ROLLBACK', const [], null);
        } catch (_) {
          // The original error matters more; the connection may be gone.
        }
        rethrow;
      }
      session._ended = true;
      final commit = await _run('COMMIT', const [], null);
      // PostgreSQL answers the COMMIT of a failed transaction with ROLLBACK.
      if (commit.commandTag == 'ROLLBACK') {
        throw LibPqException(
            'The transaction was aborted by an earlier error, and rolled back',
            sqlState: '25P02');
      }
      return value;
    });
  }

  /// Asks the server to cancel the command in progress; returns whether the
  /// request was sent. The command then ends with SQLSTATE 57014. It runs in
  /// its own short-lived isolate, because `PQcancel` blocks too.
  Future<bool> cancel() {
    if (_closed) return Future<bool>.value(false);
    final run = _spawnCancel(_libraryPath, _cancelAddress);
    final tracked = run.then<void>((_) {}, onError: (_) {});
    _cancels.add(tracked);
    unawaited(tracked.whenComplete(() => _cancels.remove(tracked)));
    return run;
  }

  /// Waits for what is queued, then closes the connection and its isolate.
  /// If a command does not end within [timeout] (a server that stopped
  /// answering), its future fails and the isolate is abandoned: it ends when
  /// libpq returns.
  Future<void> close({Duration timeout = const Duration(seconds: 5)}) {
    return _closing ??= _close(timeout);
  }

  Future<void> _close(Duration timeout) async {
    _closed = true;
    try {
      await _tail.timeout(timeout);
    } on TimeoutException {
      // Below: the isolate is abandoned.
    }
    try {
      await Future.wait(_cancels.toList()).timeout(timeout);
    } on TimeoutException {
      // PQcancel could not reach the server; it ends by itself.
    }

    if (!_workerExited) {
      final closed = Completer<void>();
      late int id;
      try {
        id = _send([_Command.close], (message) {
          _done(id);
          if (!closed.isCompleted) closed.complete();
        });
        await closed.future.timeout(timeout);
      } on TimeoutException {
        _done(id);
      } catch (_) {
        // The isolate is already gone.
      }
    }
    final waiters = _waiting.values.toList();
    _waiting.clear();
    for (final waiter in waiters) {
      waiter(_WorkerGone('the connection was closed'));
    }
    _isolate.kill(priority: Isolate.immediate);
    if (!_workerExited) _port.close();
  }
}

class _TransactionSession implements PqSession {
  _TransactionSession(this._connection);

  final LibPqAsync _connection;
  bool _ended = false;

  /// Statements of one callback run in the order they are called, also when
  /// they are not awaited one by one.
  Future<void> _tail = Future<void>.value();

  @override
  Future<PqAsyncResult> execute(String sql,
      {List<Object?> params = const [], Duration? timeout}) async {
    if (_ended) {
      throw StateError('This transaction has ended');
    }
    final result = _tail.then((_) => _connection._run(sql, params, timeout));
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}

class _WorkerGone {
  _WorkerGone(this.error);
  final Object error;
}

LibPqException _errorFromReply(List<Object?> e) => LibPqException(
      e[0] as String,
      sql: e[1] as String?,
      sqlState: e[2] as String?,
      severity: e[3] as String?,
      detail: e[4] as String?,
      hint: e[5] as String?,
    );

Exception _errorFromMessage(List<Object?> message) {
  if (message.length >= 2 && message[0] == _Reply.error) {
    return _errorFromReply(message[1] as List<Object?>);
  }
  return LibPqException('The connection isolate failed: $message');
}

PqAsyncResult _resultFromReply(List<Object?> data) => PqAsyncResult._(
      (data[0] as List).cast<String>(),
      (data[1] as List).cast<int>(),
      (data[2] as List).cast<List<String?>>(),
      data[3] as String,
      data[4] as int,
    );

/// A function of its own: the closure must capture nothing but these values.
Future<bool> _spawnCancel(String? path, int address) =>
    Isolate.run(() => _cancelInIsolate(path, address));

bool _cancelInIsolate(String? path, int address) {
  final pq = LibpqBindings(openLibpq(path));
  return using((arena) {
    const size = 256;
    return pq.PQcancel(
            Pointer<PGcancel>.fromAddress(address), arena<Char>(size), size) ==
        1;
  });
}

// ----------------------------------------------------------------- worker ---

abstract final class _Command {
  static const execute = 1;
  static const streamStart = 2;
  static const streamNext = 3;
  static const streamCancel = 4;
  static const close = 5;
}

abstract final class _Reply {
  static const connected = 'connected';
  static const error = 'error';
  static const ok = 'ok';
  static const streamBatch = 'batch';
  static const streamEnd = 'end';
}

class _WorkerStart {
  _WorkerStart(this.toMain, this.conninfo, this.connectTimeoutSeconds,
      this.libraryPath, this.encoding);

  final SendPort toMain;
  final String conninfo;
  final int connectTimeoutSeconds;
  final String? libraryPath;
  final Encoding encoding;
}

List<Object?> _errorFields(String message,
        {String? sql,
        String? sqlState,
        String? severity,
        String? detail,
        String? hint}) =>
    [message, sql, sqlState, severity, detail, hint];

List<Object?> _errorFieldsOf(LibPqException e) =>
    [e.message, e.sql, e.sqlState, e.severity, e.detail, e.hint];

/// Runs in the connection's isolate: everything that blocks happens here.
void _workerMain(_WorkerStart start) {
  final LibpqBindings pq;
  try {
    pq = LibpqBindings(openLibpq(start.libraryPath));
  } on LibPqException catch (e) {
    start.toMain.send([_Reply.error, _errorFieldsOf(e)]);
    return;
  }

  final conn = using((arena) {
    // The connect_timeout comes first: libpq expands the conninfo in dbname,
    // and later values win, so the one in the conninfo prevails.
    final keys = arena<Pointer<Char>>(3);
    final values = arena<Pointer<Char>>(3);
    keys[0] = nativeString('connect_timeout', utf8, arena);
    values[0] = nativeString('${start.connectTimeoutSeconds}', utf8, arena);
    keys[1] = nativeString('dbname', utf8, arena);
    values[1] = nativeString(start.conninfo, utf8, arena);
    keys[2] = nullptr;
    values[2] = nullptr;
    return pq.PQconnectdbParams(keys, values, 1);
  });

  if (pq.PQstatus(conn) != ConnStatusType.CONNECTION_OK) {
    final message =
        pq.PQerrorMessage(conn).asDartString(encoding: start.encoding).trim();
    pq.PQfinish(conn);
    start.toMain.send([_Reply.error, _errorFields(message)]);
    return;
  }

  final fromMain = RawReceivePort();
  final worker = _Worker(pq, conn, start.encoding, start.toMain, fromMain);
  fromMain.handler = worker.onCommand;

  final version = pq.PQserverVersion(conn);
  start.toMain.send([
    _Reply.connected,
    fromMain.sendPort,
    worker.cancelHandle.address,
    '${version ~/ 10000}.${version ~/ 100 % 100}.${version % 100}',
    pq.PQprotocolVersion(conn),
    pq.PQlibVersion(),
  ]);
}

class _Worker {
  _Worker(this.pq, this.conn, this.encoding, this.toMain, this.fromMain)
      : cancelHandle = pq.PQgetCancel(conn);

  final LibpqBindings pq;
  final Pointer<pg_conn> conn;
  final Encoding encoding;
  final SendPort toMain;
  final RawReceivePort fromMain;
  final Pointer<PGcancel> cancelHandle;

  bool get _connected => pq.PQstatus(conn) == ConnStatusType.CONNECTION_OK;

  void _reply(int id, String kind, List<Object?> data) =>
      toMain.send([id, kind, _connected, data]);

  void onCommand(Object? raw) {
    final message = raw as List<Object?>;
    final id = message[0] as int;
    try {
      switch (message[1] as int) {
        case _Command.execute:
          _execute(id, message[2] as String, (message[3] as List).cast());
        case _Command.streamStart:
          _streamStart(id, message[2] as String, (message[3] as List).cast(),
              message[4] as int);
        case _Command.streamNext:
          _streamNext(id, message[2] as int);
        case _Command.streamCancel:
          _drain();
          _reply(id, _Reply.streamEnd, const []);
        case _Command.close:
          pq.PQfreeCancel(cancelHandle);
          pq.PQfinish(conn);
          toMain.send([id, _Reply.ok, false, const <Object?>[]]);
          fromMain.close();
      }
    } on LibPqException catch (e) {
      _reply(id, _Reply.error, _errorFieldsOf(e));
    } catch (e) {
      _reply(id, _Reply.error, _errorFields('$e'));
    }
  }

  void _execute(int id, String sql, List<Object?> params) {
    final result = using((arena) {
      final text = nativeString(sql, encoding, arena);
      // Without parameters, the simple protocol: a script with several
      // statements runs whole, and PQexec returns the last result.
      if (params.isEmpty) return pq.PQexec(conn, text);
      final native = NativeParams.allocate(params, encoding, arena);
      return pq.PQexecParams(conn, text, native.count, nullptr, native.values,
          native.lengths, native.formats, 0);
    });
    if (result == nullptr) {
      throw LibPqException(
          pq.PQerrorMessage(conn).asDartString(encoding: encoding).trim(),
          sql: sql);
    }
    try {
      final status = pq.PQresultStatus(result);
      if (status != ExecStatusType.PGRES_COMMAND_OK &&
          status != ExecStatusType.PGRES_TUPLES_OK) {
        throw exceptionFromResult(pq, result, encoding, sql);
      }
      final rowCount = pq.PQntuples(result);
      final columnCount = pq.PQnfields(result);
      final rows = List<List<String?>>.generate(
          rowCount, (r) => _row(result, r, columnCount),
          growable: false);
      _reply(id, _Reply.ok, [
        _columnNames(result, columnCount),
        _columnTypes(result, columnCount),
        rows,
        pq.PQcmdStatus(result).asDartString(encoding: encoding),
        int.tryParse(pq.PQcmdTuples(result).asDartString(encoding: encoding)) ??
            0,
      ]);
    } finally {
      pq.PQclear(result);
    }
  }

  List<String?> _row(Pointer<pg_result> result, int row, int columnCount) {
    return List<String?>.generate(columnCount, (c) {
      if (pq.PQgetisnull(result, row, c) == 1) return null;
      final length = pq.PQgetlength(result, row, c);
      return encoding.decode(
          pq.PQgetvalue(result, row, c).cast<Uint8>().asTypedList(length));
    }, growable: false);
  }

  List<String> _columnNames(Pointer<pg_result> result, int count) => [
        for (var c = 0; c < count; c++)
          pq.PQfname(result, c).asDartString(encoding: encoding)
      ];

  List<int> _columnTypes(Pointer<pg_result> result, int count) =>
      [for (var c = 0; c < count; c++) pq.PQftype(result, c)];

  List<String> _streamColumns = const [];
  List<int> _streamTypes = const [];

  void _streamStart(int id, String sql, List<Object?> params, int batchSize) {
    _streamColumns = const [];
    _streamTypes = const [];
    final sent = using((arena) {
      final native = NativeParams.allocate(params, encoding, arena);
      return pq.PQsendQueryParams(
          conn,
          nativeString(sql, encoding, arena),
          native.count,
          nullptr,
          native.values,
          native.lengths,
          native.formats,
          0);
    });
    if (sent != 1 || pq.PQsetSingleRowMode(conn) != 1) {
      final message =
          pq.PQerrorMessage(conn).asDartString(encoding: encoding).trim();
      _drain();
      throw LibPqException(message, sql: sql);
    }
    _streamNext(id, batchSize);
  }

  /// Reads up to [batchSize] rows, blocking only until they arrive.
  void _streamNext(int id, int batchSize) {
    final rows = <List<String?>>[];
    while (rows.length < batchSize) {
      final result = pq.PQgetResult(conn);
      if (result == nullptr) {
        _reply(id, _Reply.streamEnd, [_streamColumns, _streamTypes, rows]);
        return;
      }
      try {
        final status = pq.PQresultStatus(result);
        if (status == ExecStatusType.PGRES_SINGLE_TUPLE ||
            status == ExecStatusType.PGRES_TUPLES_OK) {
          final columnCount = pq.PQnfields(result);
          if (_streamColumns.isEmpty && columnCount > 0) {
            _streamColumns = _columnNames(result, columnCount);
            _streamTypes = _columnTypes(result, columnCount);
          }
          if (status == ExecStatusType.PGRES_SINGLE_TUPLE) {
            rows.add(_row(result, 0, columnCount));
          }
        } else if (status != ExecStatusType.PGRES_COMMAND_OK) {
          final error = exceptionFromResult(pq, result, encoding, null);
          _drain();
          throw error;
        }
      } finally {
        pq.PQclear(result);
      }
    }
    _reply(id, _Reply.streamBatch, [_streamColumns, _streamTypes, rows]);
  }

  /// Consumes what is left of the current command: libpq requires it before
  /// the next one.
  void _drain() {
    while (true) {
      final result = pq.PQgetResult(conn);
      if (result == nullptr) return;
      pq.PQclear(result);
    }
  }
}
