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
import 'pq_values.dart';
import 'result.dart' show exceptionFromResult;

/// The result of a query run by [LibPqAsync], held in Dart memory: there is
/// nothing to dispose.
class PqAsyncResult extends Iterable<PqRow> {
  /// The column names.
  final List<String> columns;

  /// The type oid of each column.
  final List<int> columnTypes;

  /// The values, one list per row. See `decodePgValue` for their types, or the
  /// server's text with `typed: false`. SQL NULL is `null`.
  final List<List<Object?>> rows;

  /// The command tag (`INSERT 0 1`, `SELECT 3`...).
  final String commandTag;

  /// The rows affected by the command, or returned by a `SELECT`; 0 for a
  /// command that has no such count.
  final int affectedRows;

  /// Whether the values came in the binary format (see `binary` in
  /// [LibPqAsync.connect]). They are the same either way.
  final bool binary;

  PqAsyncResult._(this.columns, this.columnTypes, this.rows, this.commandTag,
      this.affectedRows,
      [this.binary = false]);

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

  /// The rows as maps of column name to value; of columns with the same name,
  /// the last one wins.
  List<Map<String, dynamic>> toColumnMaps() => [
        for (final row in rows)
          {for (var c = 0; c < columns.length; c++) columns[c]: row[c]}
      ];

  /// The same as [toColumnMaps].
  List<Map<String, dynamic>> toMaps() => toColumnMaps();
}

/// One row of a [PqAsyncResult], or of [LibPqAsync.stream].
class PqRow {
  final PqAsyncResult _result;

  /// The values, in the order of the columns. SQL NULL is `null`.
  final List<Object?> values;

  PqRow._(this._result, this.values);

  /// The value of a column, by name.
  Object? operator [](String column) {
    final index = _result._indexes[column];
    if (index == null) throw LibPqException('Column $column not found!');
    return values[index];
  }

  /// The bytes of a `bytea` column, by name; `null` for SQL NULL.
  Uint8List? bytea(String column) {
    final value = this[column];
    if (value == null || value is Uint8List) return value as Uint8List?;
    return decodeBytea(value as String);
  }

  /// The row as a map of column name to value.
  Map<String, dynamic> toColumnMap() => {
        for (var c = 0; c < _result.columns.length; c++)
          _result.columns[c]: values[c]
      };

  /// The same as [toColumnMap].
  Map<String, dynamic> toMap() => toColumnMap();

  @override
  String toString() => toColumnMap().toString();
}

/// A notification received on a `LISTEN` channel.
class PqNotification {
  /// The channel it was sent on.
  final String channel;

  /// Its payload, empty when none was sent.
  final String payload;

  /// The process id of the session that sent it.
  final int processId;

  const PqNotification(this.channel, this.payload, this.processId);

  @override
  String toString() =>
      'PqNotification(channel: $channel, payload: $payload, pid: $processId)';
}

/// The transaction status of a session, as of the last command.
enum PqTransactionStatus {
  /// Not in a transaction.
  idle,

  /// A command is running.
  active,

  /// In a transaction that can commit.
  inTransaction,

  /// In a transaction an error aborted: only `ROLLBACK` works (or `ROLLBACK TO
  /// SAVEPOINT`), and a `COMMIT` would roll it back.
  failed,

  /// The connection is not usable.
  unknown,
}

/// The isolation level of a transaction.
enum PqIsolationLevel {
  readCommitted('READ COMMITTED'),
  repeatableRead('REPEATABLE READ'),
  serializable('SERIALIZABLE');

  const PqIsolationLevel(this.sql);
  final String sql;
}

/// What runs statements: a connection, or a transaction of one.
abstract class PqSession {
  /// Runs [sql]. Parameters are numbered `$1`, `$2`...; in [params], `null` is
  /// SQL NULL, a `Uint8List` goes in binary, a `List` as an array, a `Map` as
  /// JSON, a `DateTime` in ISO 8601, and any other value is its `toString()`.
  Future<PqAsyncResult> execute(String sql,
      {List<Object?> params = const [], Duration? timeout});

  /// Runs [sql] and delivers rows as they arrive; see [LibPqAsync.stream].
  Stream<PqRow> stream(String sql,
      {List<Object?> params = const [], int batchSize = 256});

  /// Runs a `COPY ... FROM STDIN`, sending [data] as it is (the caller controls
  /// the format); returns the rows written.
  Future<int> copyFrom(String sql, Stream<List<int>> data);

  /// Writes [rows] into [table] with `COPY` in text format, far faster than one
  /// `INSERT` per row. [columns] follow the order of the values, and names are
  /// quoted. Values are converted as query parameters. Returns the rows written.
  Future<int> copyRows(
      String table, List<String> columns, Iterable<List<Object?>> rows);

  /// Runs a `COPY ... TO STDOUT` and delivers its data as it arrives. Pausing
  /// the stream stops the reading; cancelling it cancels the command.
  Stream<Uint8List> copyTo(String sql);

  /// Sends a notification on [channel].
  Future<void> notify(String channel, [String payload = '']);
}

/// A running transaction, given to the callback of [LibPqAsync.transaction].
abstract class PqTransaction implements PqSession {
  /// Runs [action] in a `SAVEPOINT`: released when it completes; when it throws,
  /// rolled back to and the error rethrown, so the transaction can go on.
  Future<T> savepoint<T>(Future<T> Function(PqTransaction tx) action);
}

/// An asynchronous libpq connection: the event loop keeps running while it
/// connects and while a query runs.
///
/// libpq blocks the thread that calls it, and Dart cannot watch its socket
/// without native code. So each connection has its own isolate, where the
/// blocking calls and the decoding happen; this class talks to it through
/// messages. Commands run one at a time, in the order they are called; for
/// parallel queries use more connections, or `LibPqAsyncPool`.
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
      this._isolate,
      this._encoding,
      this.queryTimeout,
      this._pollInterval);

  final String? _libraryPath;
  final int _cancelAddress;
  final Encoding _encoding;
  final Duration _pollInterval;

  /// The server version (`16.7.0`).
  final String serverVersion;

  /// The protocol version of the connection.
  final int protocol;

  /// The version of the libpq in use, as `PQlibVersion` gives it.
  final int libpqVersion;

  /// The timeout of the commands that do not give their own.
  final Duration? queryTimeout;

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
  PqTransactionStatus _transactionStatus = PqTransactionStatus.idle;

  /// When the connection opened.
  final DateTime openedAt = DateTime.now();
  int _commandCount = 0;
  DateTime _lastUsedAt = DateTime.now();

  /// The commands this connection has run.
  int get commandCount => _commandCount;

  /// When the last command ended.
  DateTime get lastUsedAt => _lastUsedAt;

  /// The transaction status of the server, as of the last command.
  PqTransactionStatus get transactionStatus => _transactionStatus;

  /// The end of the queue: commands and transactions run one at a time.
  Future<void> _tail = Future<void>.value();

  /// Marks the zone of a [transaction] callback.
  static final Object _transactionKey = Object();

  /// Whether the connection can run commands. It turns false after [close],
  /// and after the server closed the connection, once a command noticed it (or
  /// the listener of a channel, which checks all the time).
  bool get isConnected => !_closed && _lostBecause == null;

  /// Connects, in a new isolate, without blocking this one.
  ///
  /// - [conninfo] is a libpq connection string or `postgresql://` URI.
  /// - [connectTimeout] applies when it has no `connect_timeout` of its own
  ///   (libpq rounds a value of 1 s up to 2 s).
  /// - [libraryPath] overrides the `LIBPQ_PATH` environment variable and the
  ///   system's library search.
  /// - [encoding] encodes and decodes text; it must match `client_encoding`.
  /// - [typed] decodes values by their type (see `decodePgValue`), as the other
  ///   PostgreSQL drivers do; `false` keeps the server's text.
  /// - [infinity] says what a date `DateTime` cannot represent reads as: `null`
  ///   by default, or the text or an exception.
  /// - [statementCacheSize] prepares each `select`, `insert`, `update`, `delete`,
  ///   `with`, `values`, `table` or `merge` the first time it runs, and keeps up
  ///   to this many, so the server does not parse them again. 0, the default,
  ///   prepares nothing: a pooler in transaction mode, like PgBouncer, cannot
  ///   keep prepared statements.
  /// - [binary] has those statements return their values in the binary format,
  ///   when the server can send, and this driver read, all their columns that
  ///   way; otherwise they stay in text. The values are the same. It needs a
  ///   [statementCacheSize].
  /// - [sessionStatements] run right after connecting (`SET search_path...`).
  ///   If one fails, the connection fails.
  /// - [queryTimeout] is the timeout of commands that do not give one.
  /// - [notificationPollInterval] is how often a connection with listeners looks
  ///   for notifications, and so the most they wait.
  static Future<LibPqAsync> connect(
    String conninfo, {
    Duration connectTimeout = const Duration(seconds: 15),
    String? libraryPath,
    Encoding encoding = const Utf8Codec(allowMalformed: true),
    bool typed = true,
    PqInfinity infinity = PqInfinity.toNull,
    int statementCacheSize = 0,
    bool binary = false,
    List<String> sessionStatements = const [],
    Duration? queryTimeout,
    Duration notificationPollInterval = const Duration(milliseconds: 50),
  }) async {
    checkStatementSettings(statementCacheSize, binary, typed);
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
          _WorkerStart(
              port.sendPort,
              conninfo,
              connectTimeout.inSeconds,
              libraryPath,
              encoding,
              typed,
              infinity,
              statementCacheSize,
              binary,
              sessionStatements),
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
        isolate,
        encoding,
        queryTimeout,
        notificationPollInterval);
    handler = connection._onMessage;
    // Idle, the connection does not keep the process running.
    port.keepIsolateAlive = false;
    return connection;
  }

  void _onMessage(Object? message) {
    if (message is List && message.isNotEmpty && message[0] is int) {
      final id = message[0] as int;
      if (id == _notificationId) {
        _onNotificationMessage(message);
        return;
      }
      final waiter = _waiting[id];
      if (waiter != null) waiter(message);
      return;
    }
    // onExit sends null, onError a list of two strings.
    _workerGone(message == null
        ? 'the connection isolate ended'
        : 'the connection isolate failed: $message');
  }

  void _workerGone(Object reason) {
    _lostBecause ??= reason;
    _workerExited = true;
    _transactionStatus = PqTransactionStatus.unknown;
    final waiters = _waiting.values.toList();
    _waiting.clear();
    for (final waiter in waiters) {
      waiter(_WorkerGone(reason));
    }
    _failListeners(reason);
    _port.close();
  }

  void _updateKeepAlive() {
    if (_workerExited) return;
    _port.keepIsolateAlive = _waiting.isNotEmpty || _polling;
  }

  /// Sends a command and handles its replies through [onReply].
  int _send(List<Object?> command, void Function(Object? message) onReply) {
    final id = _nextId++;
    _waiting[id] = onReply;
    _updateKeepAlive();
    _toWorker.send([id, ...command]);
    return id;
  }

  void _done(int id) {
    _waiting.remove(id);
    _commandCount++;
    _lastUsedAt = DateTime.now();
    _updateKeepAlive();
  }

  LibPqException _lostError(Object reason, {String? sql}) =>
      LibPqException('The connection closed: $reason',
          sql: sql, sqlState: '08006');

  /// Sends a command and returns its reply, or fails with its error.
  Future<List<Object?>> _request(List<Object?> command, {String? sql}) {
    final completer = Completer<List<Object?>>();
    late int id;
    id = _send(command, (message) {
      _done(id);
      if (message is _WorkerGone) {
        completer.completeError(_lostError(message.reason, sql: sql));
        return;
      }
      final reply = (message as List).cast<Object?>();
      _noteStatus(reply);
      if (reply[1] == _Reply.error) {
        completer.completeError(_errorFromReply(reply[4] as List<Object?>));
      } else {
        completer.complete(reply);
      }
    });
    return completer.future;
  }

  void _noteStatus(List<Object?> reply) {
    _transactionStatus = PqTransactionStatus.values[reply[3] as int];
    if (reply[2] == false && _lostBecause == null) {
      _lostBecause = 'the server closed the connection';
      _failListeners(_lostBecause!);
    }
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
    if (lost != null) throw _lostError(lost);
  }

  bool get _inOwnTransaction => Zone.current[_transactionKey] == this;

  @override
  Future<PqAsyncResult> execute(String sql,
      {List<Object?> params = const [], Duration? timeout}) async {
    if (_inOwnTransaction) {
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
    final normalized = [for (final p in params) normalizeParam(p)];
    final result = _request([_Command.execute, sql, normalized], sql: sql)
        .then((reply) => _resultFromReply(reply[4] as List<Object?>));
    final limit = timeout ?? queryTimeout;
    if (limit == null) return result;

    // libpq cannot be interrupted from here: the server is asked to cancel,
    // and the command ends with its error.
    var timedOut = false;
    final timer = Timer(limit, () {
      timedOut = true;
      unawaited(cancel());
    });
    try {
      return await result;
    } on LibPqException catch (e) {
      if (timedOut && e.sqlState == '57014') {
        throw TimeoutException('The query was cancelled', limit);
      }
      rethrow;
    } finally {
      timer.cancel();
    }
  }

  /// A stream that pulls batches from the worker: only when the listener wants
  /// them, so pausing it stops the reading.
  Stream<T> _pull<T>({
    required List<Object?> Function() start,
    required List<Object?> next,
    required List<Object?> abandon,
    required void Function(StreamController<T> out, List<Object?> data) onData,
  }) {
    final inTransaction = _inOwnTransaction;
    late StreamController<T> controller;
    var started = false;
    var finished = false;
    var awaiting = false;
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

    void requestMore() {
      if (finished || awaiting || controller.isPaused) return;
      awaiting = true;
      _toWorker.send([id, ...next]);
    }

    void onReply(Object? message) {
      if (message is _WorkerGone) {
        finish(_lostError(message.reason));
        return;
      }
      final reply = (message as List).cast<Object?>();
      _noteStatus(reply);
      awaiting = false;
      if (reply[1] == _Reply.error) {
        finish(_errorFromReply(reply[4] as List<Object?>));
        return;
      }
      onData(controller, reply[4] as List<Object?>);
      if (reply[1] == _Reply.end) {
        finish();
      } else {
        requestMore();
      }
    }

    Future<void> body() {
      if (finished) return Future<void>.value();
      try {
        _checkNotLost();
      } catch (e, s) {
        finish(e, s);
        return ended.future;
      }
      awaiting = true;
      id = _send(start(), onReply);
      return ended.future;
    }

    controller = StreamController<T>(
      onListen: () {
        started = true;
        // Inside a transaction the transaction already holds the connection.
        if (inTransaction) {
          unawaited(body());
        } else {
          unawaited(_enqueue(body));
        }
      },
      onResume: requestMore,
      onCancel: () {
        if (!started || finished || id == null) {
          finish();
          return null;
        }
        // The rest is discarded: the server is asked to stop, and the worker
        // reads what it had already sent.
        unawaited(cancel());
        _toWorker.send([id, ...abandon]);
        finished = true;
        final waiting = id!;
        _waiting[waiting] = (message) {
          _done(waiting);
          if (message is List) _noteStatus(message.cast());
          if (!ended.isCompleted) ended.complete();
        };
        return ended.future;
      },
    );
    return controller.stream;
  }

  /// Runs [sql] in libpq's single row mode and delivers rows as they arrive,
  /// so a large result does not have to fit in memory. Rows are read ahead in
  /// batches of [batchSize], and only when the listener wants them (pausing the
  /// stream stops reading). Cancelling the subscription cancels the query.
  /// Other commands on this connection wait until the stream ends.
  @override
  Stream<PqRow> stream(String sql,
      {List<Object?> params = const [], int batchSize = 256}) {
    RangeError.checkNotNegative(batchSize - 1, 'batchSize - 1');
    if (_closed) return Stream.error(StateError('This connection was closed'));
    PqAsyncResult? shape;
    return _pull<PqRow>(
      start: () => [
        _Command.streamStart,
        sql,
        [for (final p in params) normalizeParam(p)],
        batchSize
      ],
      next: [_Command.streamNext, batchSize],
      abandon: const [_Command.abandon],
      onData: (out, data) {
        if (data.isEmpty) return;
        shape ??= PqAsyncResult._((data[0] as List).cast<String>(),
            (data[1] as List).cast<int>(), const [], '', 0);
        for (final row in data[2] as List) {
          out.add(PqRow._(shape!, (row as List).cast<Object?>()));
        }
      },
    );
  }

  @override
  Stream<Uint8List> copyTo(String sql) {
    if (_closed) return Stream.error(StateError('This connection was closed'));
    return _pull<Uint8List>(
      start: () => [_Command.copyOutStart, sql],
      next: const [_Command.copyOutNext],
      abandon: const [_Command.abandonCopyOut],
      onData: (out, data) {
        if (data.isNotEmpty) out.add(data[0] as Uint8List);
      },
    );
  }

  /// The whole output of a `COPY ... TO STDOUT`, as text.
  Future<String> copyToText(String sql) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in copyTo(sql)) {
      bytes.add(chunk);
    }
    return _encoding.decode(bytes.takeBytes());
  }

  /// Runs [operation] holding the connection, or at once in a transaction.
  Future<T> _holding<T>(Future<T> Function() operation) async {
    if (_inOwnTransaction) return operation();
    _checkUsable();
    return _enqueue(operation);
  }

  @override
  Future<int> copyFrom(String sql, Stream<List<int>> data) =>
      _holding(() => _copyFrom(sql, data));

  Future<int> _copyFrom(String sql, Stream<List<int>> data) async {
    _checkNotLost();
    await _request([_Command.copyInStart, sql], sql: sql);
    try {
      await for (final chunk in data) {
        if (chunk.isEmpty) continue;
        // One chunk at a time, so a large source cannot fill the port.
        await _request([
          _Command.copyInData,
          chunk is Uint8List ? chunk : Uint8List.fromList(chunk)
        ], sql: sql);
      }
    } catch (e) {
      // Tell the server, or the connection stays in COPY mode.
      if (_lostBecause == null) {
        try {
          await _request([_Command.copyInEnd, 'The source failed: $e'],
              sql: sql);
        } on LibPqException catch (_) {
          // The server answers an aborted COPY with an error, as expected, or
          // the COPY had already ended with its own.
        }
      }
      rethrow;
    }
    final reply = await _request([_Command.copyInEnd, null], sql: sql);
    return (reply[4] as List<Object?>)[0] as int;
  }

  @override
  Future<int> copyRows(
      String table, List<String> columns, Iterable<List<Object?>> rows) {
    final names = columns.map(_quoteIdentifier).join(', ');
    final target = table.split('.').map(_quoteIdentifier).join('.');
    final sql = 'COPY $target ($names) FROM STDIN';
    return copyFrom(sql, _copyChunks(rows, columns.length));
  }

  Stream<List<int>> _copyChunks(
      Iterable<List<Object?>> rows, int columnCount) async* {
    const chunkBytes = 64 * 1024;
    final buffer = BytesBuilder(copy: false);
    for (final row in rows) {
      if (row.length != columnCount) {
        throw ArgumentError.value(
            row, 'rows', 'Expected $columnCount values per row');
      }
      buffer.add(_encoding.encode(formatCopyRow(row)));
      if (buffer.length >= chunkBytes) yield buffer.takeBytes();
    }
    if (buffer.isNotEmpty) yield buffer.takeBytes();
  }

  // ------------------------------------------------------- LISTEN / NOTIFY ---

  static const _notificationId = 0;
  bool _polling = false;
  final Map<String, StreamController<PqNotification>> _channels = {};
  StreamController<PqNotification>? _allNotifications;

  final StreamController<String> _notices = StreamController.broadcast();

  /// The server's notices and warnings (`NOTICE: table does not exist,
  /// skipping`). libpq would print them to stderr.
  Stream<String> get notices => _notices.stream;

  /// Every notification this connection receives, whatever the channel. Listen
  /// to it after running `LISTEN` yourself; [listen] does both for one channel.
  /// While it has listeners the connection keeps the process running.
  Stream<PqNotification> get notifications {
    return (_allNotifications ??= StreamController.broadcast(
      onListen: _updatePolling,
      onCancel: _updatePolling,
    ))
        .stream;
  }

  /// `LISTEN` on [channel], and delivers its notifications until the last
  /// subscription is cancelled (then `UNLISTEN`).
  ///
  /// libpq has to be asked: while it has listeners, the connection checks for
  /// notifications every `notificationPollInterval` (50 ms by default), in its
  /// own isolate. It also notices a closed connection that way: the stream gets
  /// an error and ends. A connection with listeners should not be shared with
  /// long commands, because nothing is delivered while one runs.
  Stream<PqNotification> listen(String channel) {
    final existing = _channels[channel];
    if (existing != null) return existing.stream;
    late StreamController<PqNotification> controller;
    controller = StreamController<PqNotification>.broadcast(
      onListen: () async {
        try {
          await _holding(() =>
              _run('LISTEN ${_quoteIdentifier(channel)}', const [], null));
          _updatePolling();
        } catch (e, s) {
          if (!controller.isClosed) controller.addError(e, s);
        }
      },
      onCancel: () async {
        _channels.remove(channel);
        unawaited(controller.close());
        _updatePolling();
        if (isConnected) {
          try {
            await _enqueue(() =>
                _run('UNLISTEN ${_quoteIdentifier(channel)}', const [], null));
          } catch (_) {
            // It ends with the connection.
          }
        }
      },
    );
    _channels[channel] = controller;
    return controller.stream;
  }

  void _updatePolling() {
    final wanted =
        _channels.isNotEmpty || (_allNotifications?.hasListener ?? false);
    if (wanted == _polling || _workerExited || _closed) return;
    _polling = wanted;
    _updateKeepAlive();
    _toWorker.send([
      _notificationId,
      wanted ? _Command.pollStart : _Command.pollStop,
      _pollInterval.inMicroseconds
    ]);
  }

  void _onNotificationMessage(List<Object?> message) {
    if (message[1] == _Reply.notice) {
      _notices.add(message[2] as String);
      return;
    }
    if (message[1] == _Reply.lost) {
      _lostBecause ??= 'the server closed the connection';
      _transactionStatus = PqTransactionStatus.unknown;
      _failListeners(_lostBecause!);
      return;
    }
    final notification = PqNotification(
        message[2] as String, message[3] as String, message[4] as int);
    _channels[notification.channel]?.add(notification);
    final all = _allNotifications;
    if (all != null && all.hasListener) all.add(notification);
  }

  void _failListeners(Object reason) {
    final error = _lostError(reason);
    for (final controller in _channels.values.toList()) {
      controller
        ..addError(error)
        ..close();
    }
    _channels.clear();
    final all = _allNotifications;
    if (all != null && !all.isClosed) {
      all
        ..addError(error)
        ..close();
    }
    _polling = false;
    _updateKeepAlive();
  }

  @override
  Future<void> notify(String channel, [String payload = '']) async {
    await execute(r'select pg_notify($1, $2)', params: [channel, payload]);
  }

  // ---------------------------------------------------------- transactions ---

  /// Runs [action] in a transaction: `BEGIN` before it, `COMMIT` after it, and
  /// `ROLLBACK` if it throws. The connection is held meanwhile, so commands
  /// from other callers wait. Inside [action], use the session it receives.
  /// [timeout] is the default of its statements.
  Future<T> transaction<T>(Future<T> Function(PqTransaction tx) action,
      {PqIsolationLevel? isolationLevel,
      bool readOnly = false,
      Duration? timeout}) async {
    if (_inOwnTransaction) {
      throw StateError('Transactions on one connection cannot be nested: use '
          'the savepoint of the session the callback receives');
    }
    _checkUsable();
    return _enqueue(() async {
      final begin = StringBuffer('BEGIN');
      if (isolationLevel != null) {
        begin.write(' ISOLATION LEVEL ${isolationLevel.sql}');
      }
      if (readOnly) begin.write(' READ ONLY');
      await _run(begin.toString(), const [], timeout);
      final session = _TransactionSession(this, timeout);
      final T value;
      try {
        value = await runZoned(() => action(session),
            zoneValues: {_transactionKey: this});
      } catch (_) {
        session._ended = true;
        try {
          await _run('ROLLBACK', const [], timeout);
        } catch (_) {
          // The original error matters more; the connection may be gone.
        }
        rethrow;
      }
      session._ended = true;
      final commit = await _run('COMMIT', const [], timeout);
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
    if (_closed || _workerExited) return Future<bool>.value(false);
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
    for (final controller in _channels.values.toList()) {
      unawaited(controller.close());
    }
    _channels.clear();
    final all = _allNotifications;
    if (all != null && !all.isClosed) unawaited(all.close());
    _polling = false;
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

class _TransactionSession implements PqTransaction {
  _TransactionSession(this._connection, this._timeout, [this._depth = 0]);

  final LibPqAsync _connection;
  final Duration? _timeout;
  final int _depth;
  bool _ended = false;
  int _savepoints = 0;

  /// Statements of one callback run in the order they are called, also when
  /// they are not awaited one by one.
  Future<void> _tail = Future<void>.value();

  void _checkActive() {
    if (_ended) throw StateError('This transaction has ended');
  }

  Future<R> _serial<R>(Future<R> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<PqAsyncResult> execute(String sql,
      {List<Object?> params = const [], Duration? timeout}) async {
    _checkActive();
    return _serial(() => _connection._run(sql, params, timeout ?? _timeout));
  }

  @override
  Stream<PqRow> stream(String sql,
      {List<Object?> params = const [], int batchSize = 256}) {
    if (_ended) return Stream.error(StateError('This transaction has ended'));
    return _connection.stream(sql, params: params, batchSize: batchSize);
  }

  @override
  Future<int> copyFrom(String sql, Stream<List<int>> data) async {
    _checkActive();
    return _serial(() => _connection._copyFrom(sql, data));
  }

  @override
  Future<int> copyRows(
      String table, List<String> columns, Iterable<List<Object?>> rows) async {
    _checkActive();
    return _serial(() => _connection.copyRows(table, columns, rows));
  }

  @override
  Stream<Uint8List> copyTo(String sql) {
    if (_ended) return Stream.error(StateError('This transaction has ended'));
    return _connection.copyTo(sql);
  }

  @override
  Future<void> notify(String channel, [String payload = '']) async {
    await execute(r'select pg_notify($1, $2)', params: [channel, payload]);
  }

  @override
  Future<T> savepoint<T>(Future<T> Function(PqTransaction tx) action) async {
    _checkActive();
    final name = 'libpq_sp_${_depth}_${_savepoints++}';
    await execute('SAVEPOINT $name');
    final inner = _TransactionSession(_connection, _timeout, _depth + 1);
    final T value;
    try {
      value = await action(inner);
    } catch (_) {
      inner._ended = true;
      try {
        await execute('ROLLBACK TO SAVEPOINT $name');
        await execute('RELEASE SAVEPOINT $name');
      } catch (_) {
        // The action's error matters more.
      }
      rethrow;
    }
    inner._ended = true;
    await execute('RELEASE SAVEPOINT $name');
    return value;
  }
}

String _quoteIdentifier(String name) => '"${name.replaceAll('"', '""')}"';

class _WorkerGone {
  _WorkerGone(this.reason);
  final Object reason;
}

LibPqException _errorFromReply(List<Object?> e) => LibPqException(
      e[0] as String,
      sql: e[1] as String?,
      sqlState: e[2] as String?,
      severity: e[3] as String?,
      detail: e[4] as String?,
      hint: e[5] as String?,
      constraint: e[6] as String?,
      table: e[7] as String?,
      column: e[8] as String?,
    );

Exception _errorFromMessage(List<Object?> message) {
  if (message.length >= 2 && message[0] == _Reply.error) {
    return _errorFromReply((message[1] as List).cast<Object?>());
  }
  return LibPqException('The connection isolate failed: $message');
}

PqAsyncResult _resultFromReply(List<Object?> data) => PqAsyncResult._(
      (data[0] as List).cast<String>(),
      (data[1] as List).cast<int>(),
      (data[2] as List).cast<List<Object?>>(),
      data[3] as String,
      data[4] as int,
      data[5] as bool,
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
  static const abandon = 4;
  static const close = 5;
  static const copyInStart = 6;
  static const copyInData = 7;
  static const copyInEnd = 8;
  static const copyOutStart = 9;
  static const copyOutNext = 10;
  static const abandonCopyOut = 11;
  static const pollStart = 12;
  static const pollStop = 13;
}

abstract final class _Reply {
  static const connected = 'connected';
  static const error = 'error';
  static const ok = 'ok';
  static const batch = 'batch';
  static const end = 'end';
  static const notification = 'notification';
  static const lost = 'lost';
  static const notice = 'notice';
}

class _WorkerStart {
  _WorkerStart(
      this.toMain,
      this.conninfo,
      this.connectTimeoutSeconds,
      this.libraryPath,
      this.encoding,
      this.typed,
      this.infinity,
      this.statementCacheSize,
      this.binary,
      this.sessionStatements);

  final SendPort toMain;
  final String conninfo;
  final int connectTimeoutSeconds;
  final String? libraryPath;
  final Encoding encoding;
  final bool typed;
  final PqInfinity infinity;
  final int statementCacheSize;
  final bool binary;
  final List<String> sessionStatements;
}

/// A statement prepared on a connection, and the format of its results.
class _Statement {
  _Statement(this.name, this.binary);

  final String name;
  final bool binary;
}

List<Object?> _errorFields(String message, {String? sql, String? sqlState}) =>
    [message, sql, sqlState, null, null, null, null, null, null];

List<Object?> _errorFieldsOf(LibPqException e) => [
      e.message,
      e.sql,
      e.sqlState,
      e.severity,
      e.detail,
      e.hint,
      e.constraint,
      e.table,
      e.column
    ];

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
    start.toMain.send([
      _Reply.error,
      _errorFields(message, sqlState: '08001'),
    ]);
    return;
  }

  final fromMain = RawReceivePort();
  final worker = _Worker(pq, conn, start.encoding, start.typed, start.infinity,
      start.statementCacheSize, start.binary, start.toMain, fromMain);
  _Worker.current = worker;
  pq.PQsetNoticeProcessor(
      conn,
      Pointer.fromFunction<Void Function(Pointer<Void>, Pointer<Char>)>(
          _onNotice),
      nullptr);
  fromMain.handler = worker.onCommand;

  try {
    worker.prepareSession(start.sessionStatements);
  } on LibPqException catch (e) {
    pq.PQfreeCancel(worker.cancelHandle);
    pq.PQfinish(conn);
    fromMain.close();
    start.toMain.send([_Reply.error, _errorFieldsOf(e)]);
    return;
  }

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

/// Called by libpq, on the worker's thread, during a blocking call.
void _onNotice(Pointer<Void> _, Pointer<Char> message) {
  final worker = _Worker.current;
  if (worker == null) return;
  worker.toMain.send([
    LibPqAsync._notificationId,
    _Reply.notice,
    message.asDartString(encoding: worker.encoding).trim(),
  ]);
}

class _Worker {
  /// This isolate's worker: a notice processor cannot carry Dart state.
  static _Worker? current;

  _Worker(this.pq, this.conn, this.encoding, this.typed, this.infinity,
      this.statementCacheSize, this.binary, this.toMain, this.fromMain)
      : cancelHandle = pq.PQgetCancel(conn);

  final LibpqBindings pq;
  final Pointer<pg_conn> conn;
  final Encoding encoding;
  final bool typed;
  final PqInfinity infinity;
  final int statementCacheSize;
  final bool binary;
  final SendPort toMain;
  final RawReceivePort fromMain;
  final Pointer<PGcancel> cancelHandle;
  Timer? _pollTimer;

  bool get _connected => pq.PQstatus(conn) == ConnStatusType.CONNECTION_OK;

  void _reply(int id, String kind, List<Object?> data) {
    _deliverNotifications();
    toMain.send([id, kind, _connected, pq.PQtransactionStatus(conn), data]);
  }

  /// Typed decoding needs the dates in ISO format, whatever the server's
  /// default is.
  void prepareSession(List<String> statements) {
    final all = [
      if (typed && !_dateStyleIsIso()) 'SET DateStyle TO ISO',
      ...statements,
    ];
    for (final statement in all) {
      final result = using(
          (arena) => pq.PQexec(conn, nativeString(statement, encoding, arena)));
      _checkResult(result, statement);
      pq.PQclear(result);
    }
  }

  bool _dateStyleIsIso() => using((arena) {
        final value =
            pq.PQparameterStatus(conn, nativeString('DateStyle', utf8, arena));
        return value != nullptr && value.asDartString().startsWith('ISO');
      });

  void _checkResult(Pointer<pg_result> result, String? sql) {
    if (result == nullptr) throw _connectionError(sql);
    final status = pq.PQresultStatus(result);
    if (status == ExecStatusType.PGRES_COMMAND_OK ||
        status == ExecStatusType.PGRES_TUPLES_OK ||
        status == ExecStatusType.PGRES_EMPTY_QUERY) {
      return;
    }
    final error = exceptionFromResult(pq, result, encoding, sql, conn);
    pq.PQclear(result);
    throw error;
  }

  /// libpq's message, with the SQLSTATE of a lost connection when it is one.
  LibPqException _connectionError(String? sql) {
    final message =
        pq.PQerrorMessage(conn).asDartString(encoding: encoding).trim();
    return LibPqException(
        message.isEmpty ? 'libpq returned no result' : message,
        sql: sql,
        sqlState: _connected ? null : '08006');
  }

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
        case _Command.abandon:
          _drain();
          _reply(id, _Reply.end, const []);
        case _Command.copyInStart:
          _copyStart(id, message[2] as String, ExecStatusType.PGRES_COPY_IN);
        case _Command.copyInData:
          _copyInData(id, message[2] as Uint8List);
        case _Command.copyInEnd:
          _copyInEnd(id, message[2] as String?);
        case _Command.copyOutStart:
          _copyStart(id, message[2] as String, ExecStatusType.PGRES_COPY_OUT);
        case _Command.copyOutNext:
          _copyOutNext(id);
        case _Command.abandonCopyOut:
          _discardCopyOut();
          _reply(id, _Reply.end, const []);
        case _Command.pollStart:
          _startPolling(message[2] as int);
        case _Command.pollStop:
          _pollTimer?.cancel();
          _pollTimer = null;
        case _Command.close:
          _pollTimer?.cancel();
          pq.PQfreeCancel(cancelHandle);
          pq.PQfinish(conn);
          toMain.send([id, _Reply.ok, false, 4, const <Object?>[]]);
          fromMain.close();
      }
    } on LibPqException catch (e) {
      _reply(id, _Reply.error, _errorFieldsOf(e));
    } catch (e) {
      _reply(id, _Reply.error, _errorFields('$e'));
    }
  }

  void _startPolling(int micros) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(Duration(microseconds: micros), (_) {
      if (pq.PQconsumeInput(conn) == 0 || !_connected) {
        _pollTimer?.cancel();
        _pollTimer = null;
        toMain.send([LibPqAsync._notificationId, _Reply.lost]);
        return;
      }
      _deliverNotifications();
    });
  }

  void _deliverNotifications() {
    while (true) {
      final notification = pq.PQnotifies(conn);
      if (notification == nullptr) return;
      final value = notification.ref;
      toMain.send([
        LibPqAsync._notificationId,
        _Reply.notification,
        value.relname.asDartString(encoding: encoding),
        value.extra.asDartString(encoding: encoding),
        value.be_pid,
      ]);
      pq.PQfreemem(notification.cast());
    }
  }

  // ---------------------------------------------------- prepared statements ---

  /// The prepared statements by their SQL; the first is the least recently used.
  final Map<String, _Statement> _statements = {};

  /// Statements out of the cache, still prepared on the server.
  final List<String> _toDeallocate = [];
  int _statementCount = 0;

  /// What is worth a plan. `BEGIN`, `SET`, DDL have none, and a savepoint's name
  /// would fill the cache.
  static final RegExp _hasPlan = RegExp(
      r'^\s*(select|with|insert|update|delete|values|table|merge)\b',
      caseSensitive: false);

  /// A statement with several commands cannot be prepared: it goes on as a
  /// script. A `;` in a string only means this one is not cached.
  bool _cacheable(String sql) {
    if (statementCacheSize == 0) return false;
    final semicolon = sql.indexOf(';');
    if (semicolon >= 0 && sql.substring(semicolon + 1).trim().isNotEmpty) {
      return false;
    }
    return _hasPlan.hasMatch(sql);
  }

  /// The statement of [sql], prepared if it was not; null if it is not cached.
  _Statement? _statementFor(String sql) {
    final found = _statements.remove(sql);
    if (found != null) {
      _statements[sql] = found;
      return found;
    }
    if (!_cacheable(sql)) return null;

    final name = 'libpq_dart_${_statementCount++}';
    final statement = using((arena) {
      final nativeName = nativeString(name, utf8, arena);
      final prepared = pq.PQprepare(
          conn, nativeName, nativeString(sql, encoding, arena), 0, nullptr);
      _checkResult(prepared, sql);
      pq.PQclear(prepared);
      return _Statement(name, binary && _allColumnsBinary(nativeName, sql));
    });
    _statements[sql] = statement;
    if (_statements.length > statementCacheSize) {
      _forget(_statements.keys.first);
    }
    _deallocate();
    return statement;
  }

  /// The types come from the server before running: a type this driver cannot
  /// read, or the server cannot send (`aclitem`), keeps the statement in text.
  bool _allColumnsBinary(Pointer<Char> name, String sql) {
    final description = pq.PQdescribePrepared(conn, name);
    _checkResult(description, sql);
    try {
      for (var c = 0; c < pq.PQnfields(description); c++) {
        if (!hasBinaryDecoder(pq.PQftype(description, c), infinity)) {
          return false;
        }
      }
      return true;
    } finally {
      pq.PQclear(description);
    }
  }

  void _forget(String sql) {
    final statement = _statements.remove(sql);
    if (statement != null) _toDeallocate.add(statement.name);
  }

  bool get _isIdle =>
      pq.PQtransactionStatus(conn) == PGTransactionStatusType.PQTRANS_IDLE;

  /// Only outside a transaction: a name the server does not know, after someone
  /// else's `DEALLOCATE ALL`, would abort it.
  void _deallocate() {
    if (_toDeallocate.isEmpty || !_isIdle) return;
    for (final name in _toDeallocate) {
      final result = using((arena) =>
          pq.PQexec(conn, nativeString('DEALLOCATE $name', utf8, arena)));
      if (result != nullptr) pq.PQclear(result);
    }
    _toDeallocate.clear();
  }

  /// A statement the server no longer has (`DEALLOCATE ALL`, `DISCARD ALL`), or
  /// that now returns other columns (`cached plan must not change result type`).
  bool _isStale(Pointer<pg_result> result) {
    if (result == nullptr ||
        pq.PQresultStatus(result) != ExecStatusType.PGRES_FATAL_ERROR) {
      return false;
    }
    final state = pq.PQresultErrorField(result, PG_DIAG_SQLSTATE);
    if (state == nullptr) return false;
    final code = state.asDartString();
    return code == '26000' || code == '0A000';
  }

  Pointer<pg_result> _send(
          String sql, List<Object?> params, _Statement? statement) =>
      using((arena) {
        if (statement != null) {
          final native = NativeParams.allocate(params, encoding, arena);
          return pq.PQexecPrepared(
              conn,
              nativeString(statement.name, utf8, arena),
              native.count,
              native.values,
              native.lengths,
              native.formats,
              statement.binary ? 1 : 0);
        }
        final text = nativeString(sql, encoding, arena);
        // Without parameters, the simple protocol: a script with several
        // statements runs whole, and PQexec returns the last result.
        if (params.isEmpty) return pq.PQexec(conn, text);
        final native = NativeParams.allocate(params, encoding, arena);
        return pq.PQexecParams(conn, text, native.count, nullptr, native.values,
            native.lengths, native.formats, 0);
      });

  void _execute(int id, String sql, List<Object?> params) {
    var statement = _statementFor(sql);
    var result = _send(sql, params, statement);
    if (statement != null && _isStale(result)) {
      _forget(sql);
      // Outside a transaction nothing ran, so it can run again. Inside, the
      // transaction is already aborted: the error goes to the caller.
      if (_isIdle) {
        pq.PQclear(result);
        statement = _statementFor(sql);
        result = _send(sql, params, statement);
      }
    }
    final inBinary = statement?.binary ?? false;
    if (result != nullptr) _leaveCopyMode(result);
    _checkResult(result, sql);
    try {
      final rowCount = pq.PQntuples(result);
      final columnCount = pq.PQnfields(result);
      final types = _columnTypes(result, columnCount);
      final rows = List<List<Object?>>.generate(
          rowCount, (r) => _row(result, r, columnCount, types, inBinary),
          growable: false);
      _reply(id, _Reply.ok, [
        _columnNames(result, columnCount),
        types,
        rows,
        pq.PQcmdStatus(result).asDartString(encoding: encoding),
        int.tryParse(pq.PQcmdTuples(result).asDartString(encoding: encoding)) ??
            0,
        inBinary,
      ]);
    } finally {
      pq.PQclear(result);
    }
  }

  /// A `COPY` through [_execute]: without this the connection would stay in
  /// COPY mode, refusing every other command.
  void _leaveCopyMode(Pointer<pg_result> result) {
    final status = pq.PQresultStatus(result);
    if (status == ExecStatusType.PGRES_COPY_IN) {
      using((arena) => pq.PQputCopyEnd(
          conn, nativeString('Use copyFrom for COPY', utf8, arena)));
      _drain();
    } else if (status == ExecStatusType.PGRES_COPY_OUT) {
      _discardCopyOut();
    } else {
      return;
    }
    pq.PQclear(result);
    throw LibPqException(
        'A COPY needs copyFrom, copyRows or copyTo: it cannot run through '
        'execute');
  }

  List<Object?> _row(Pointer<pg_result> result, int row, int columnCount,
      List<int> types, bool inBinary) {
    return List<Object?>.generate(columnCount, (c) {
      if (pq.PQgetisnull(result, row, c) == 1) return null;
      final length = pq.PQgetlength(result, row, c);
      final bytes =
          pq.PQgetvalue(result, row, c).cast<Uint8>().asTypedList(length);
      if (inBinary) {
        return decodeBinaryPgValue(types[c], bytes, encoding, infinity);
      }
      return typed
          ? decodePgValue(types[c], bytes, encoding, infinity)
          : encoding.decode(bytes);
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
  bool _streamBinary = false;

  /// How to start the stream again, while it may have a stale statement.
  void Function(int id)? _streamRetry;

  void _streamStart(int id, String sql, List<Object?> params, int batchSize,
      {bool mayRetry = true}) {
    _streamColumns = const [];
    _streamTypes = const [];
    final statement = _statementFor(sql);
    _streamBinary = statement?.binary ?? false;
    _streamRetry = statement == null || !mayRetry
        ? null
        : (id) {
            _forget(sql);
            if (_isIdle) {
              _streamStart(id, sql, params, batchSize, mayRetry: false);
            }
          };
    final sent = using((arena) {
      final native = NativeParams.allocate(params, encoding, arena);
      if (statement != null) {
        return pq.PQsendQueryPrepared(
            conn,
            nativeString(statement.name, utf8, arena),
            native.count,
            native.values,
            native.lengths,
            native.formats,
            statement.binary ? 1 : 0);
      }
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
      final error = _connectionError(sql);
      _drain();
      throw error;
    }
    _streamNext(id, batchSize);
  }

  /// Reads up to [batchSize] rows, blocking only until they arrive.
  void _streamNext(int id, int batchSize) {
    final rows = <List<Object?>>[];
    while (rows.length < batchSize) {
      final result = pq.PQgetResult(conn);
      if (result == nullptr) {
        _reply(id, _Reply.end, [_streamColumns, _streamTypes, rows]);
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
            try {
              _streamRetry = null;
              rows.add(
                  _row(result, 0, columnCount, _streamTypes, _streamBinary));
            } catch (_) {
              // A value that cannot be decoded: the rest of the result must be
              // read, or the next command fails.
              _drain();
              rethrow;
            }
          }
        } else if (status != ExecStatusType.PGRES_COMMAND_OK) {
          final stale = _streamRetry != null && _isStale(result);
          final error = exceptionFromResult(pq, result, encoding, null, conn);
          _drain();
          if (stale) {
            final retry = _streamRetry!;
            _streamRetry = null;
            final wasIdle = _isIdle;
            retry(id);
            if (wasIdle) return;
          }
          throw error;
        }
      } finally {
        pq.PQclear(result);
      }
    }
    _reply(id, _Reply.batch, [_streamColumns, _streamTypes, rows]);
  }

  /// Consumes what is left of the current command: libpq requires it before
  /// the next one.
  void _drain() {
    while (true) {
      final result = pq.PQgetResult(conn);
      if (result == nullptr) return;
      final status = pq.PQresultStatus(result);
      pq.PQclear(result);
      if (status == ExecStatusType.PGRES_COPY_OUT) {
        _discardCopyOut();
        return;
      }
      if (status == ExecStatusType.PGRES_COPY_IN) {
        using((arena) => pq.PQputCopyEnd(
            conn, nativeString('Abandoned by the client', utf8, arena)));
      }
    }
  }

  void _copyStart(int id, String sql, int expected) {
    final result =
        using((arena) => pq.PQexec(conn, nativeString(sql, encoding, arena)));
    if (result == nullptr) throw _connectionError(sql);
    final status = pq.PQresultStatus(result);
    if (status != expected) {
      if (status == ExecStatusType.PGRES_COPY_IN ||
          status == ExecStatusType.PGRES_COPY_OUT) {
        _leaveCopyMode(result); // Throws: the other direction.
      }
      if (status == ExecStatusType.PGRES_COMMAND_OK ||
          status == ExecStatusType.PGRES_TUPLES_OK) {
        pq.PQclear(result);
        throw LibPqException('This statement is not a COPY: $sql', sql: sql);
      }
      final error = exceptionFromResult(pq, result, encoding, sql, conn);
      pq.PQclear(result);
      throw error;
    }
    pq.PQclear(result);
    if (expected == ExecStatusType.PGRES_COPY_IN) {
      _reply(id, _Reply.ok, const []);
    } else {
      _copyOutNext(id);
    }
  }

  void _copyInData(int id, Uint8List data) {
    final sent = using((arena) {
      final buffer = arena<Uint8>(data.length);
      buffer.asTypedList(data.length).setAll(0, data);
      return pq.PQputCopyData(conn, buffer.cast(), data.length);
    });
    // Otherwise the server ended the COPY with an error: read it.
    if (sent != 1) throw _copyFailure();
    _reply(id, _Reply.ok, const []);
  }

  LibPqException _copyFailure() {
    final message = _connectionError(null);
    final result = pq.PQgetResult(conn);
    if (result == nullptr) return message;
    final error = exceptionFromResult(pq, result, encoding, null, conn);
    pq.PQclear(result);
    _drain();
    return error;
  }

  void _copyInEnd(int id, String? failure) {
    final ended = using((arena) => pq.PQputCopyEnd(conn,
        failure == null ? nullptr : nativeString(failure, encoding, arena)));
    if (ended != 1) throw _copyFailure();
    final result = pq.PQgetResult(conn);
    try {
      _checkResult(result, null);
    } catch (_) {
      _drain();
      rethrow;
    }
    final count =
        int.tryParse(pq.PQcmdTuples(result).asDartString(encoding: encoding)) ??
            0;
    pq.PQclear(result);
    _drain();
    _reply(id, _Reply.ok, [count]);
  }

  /// Sends what `PQgetCopyData` gives, up to about 64 KB per message.
  void _copyOutNext(int id) {
    const limit = 64 * 1024;
    final out = BytesBuilder(copy: true);
    final slot = malloc<Pointer<Char>>();
    try {
      while (out.length < limit) {
        final length = pq.PQgetCopyData(conn, slot, 0);
        if (length > 0) {
          out.add(slot.value.cast<Uint8>().asTypedList(length));
          pq.PQfreemem(slot.value.cast());
        } else if (length == -1) {
          final result = pq.PQgetResult(conn);
          try {
            _checkResult(result, null);
          } catch (_) {
            _drain();
            rethrow;
          }
          pq.PQclear(result);
          _drain();
          _reply(id, _Reply.end, out.isEmpty ? const [] : [out.takeBytes()]);
          return;
        } else {
          throw _copyFailure();
        }
      }
    } finally {
      malloc.free(slot);
    }
    _reply(id, _Reply.batch, [out.takeBytes()]);
  }

  void _discardCopyOut() {
    final slot = malloc<Pointer<Char>>();
    try {
      while (true) {
        final length = pq.PQgetCopyData(conn, slot, 0);
        if (length <= 0) break;
        pq.PQfreemem(slot.value.cast());
      }
    } finally {
      malloc.free(slot);
    }
    while (true) {
      final result = pq.PQgetResult(conn);
      if (result == nullptr) return;
      pq.PQclear(result);
    }
  }
}
