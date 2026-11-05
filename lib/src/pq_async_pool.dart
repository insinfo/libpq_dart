import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'pq_async.dart';

/// A pool of [LibPqAsync] connections, each with its own isolate, so queries
/// run in parallel. Connections open when needed, up to [maxConnections]; a lost
/// one is replaced, and one past its limits is closed instead of reused.
///
/// ```dart
/// final pool = LibPqAsyncPool('host=localhost dbname=app', maxConnections: 4);
/// final result = await pool.execute('select 1');
/// await pool.close();
/// ```
class LibPqAsyncPool implements PqSession {
  LibPqAsyncPool(
    this.conninfo, {
    this.maxConnections = 4,
    this.connectTimeout = const Duration(seconds: 15),
    this.acquireTimeout,
    this.queryTimeout,
    this.idleTestThreshold = const Duration(minutes: 1),
    this.maxConnectionAge = const Duration(hours: 12),
    this.maxCommandCount,
    this.libraryPath,
    this.encoding = const Utf8Codec(allowMalformed: true),
    this.typed = true,
    this.sessionStatements = const [],
    this.onOpen,
  }) {
    RangeError.checkNotNegative(maxConnections - 1, 'maxConnections - 1');
  }

  final String conninfo;
  final int maxConnections;
  final Duration connectTimeout;

  /// How long a caller waits for a free connection; null waits as long as it
  /// takes. Past it, a `TimeoutException`.
  final Duration? acquireTimeout;

  /// The timeout of the commands that do not give their own.
  final Duration? queryTimeout;

  /// A connection idle for longer than this is tested with `select 1` before
  /// being used, and replaced if the server closed it.
  final Duration idleTestThreshold;

  /// A connection older than this is closed instead of reused.
  final Duration maxConnectionAge;

  /// A connection that ran this many commands is closed instead of reused.
  final int? maxCommandCount;

  final String? libraryPath;
  final Encoding encoding;
  final bool typed;

  /// Statements each connection runs when it opens (`SET search_path...`).
  final List<String> sessionStatements;

  /// Called with each new connection, before anyone uses it. If it throws, the
  /// connection is closed and the caller that needed it fails.
  final Future<void> Function(LibPqAsync connection)? onOpen;

  final List<LibPqAsync> _idle = [];
  final Queue<Completer<LibPqAsync?>> _waiters = Queue();
  int _open = 0;
  bool _closed = false;
  final List<Future<void>> _closing = [];

  /// The connections open now, idle or in use.
  int get openConnections => _open;

  /// The connections open and not in use.
  int get idleConnections => _idle.length;

  /// The callers waiting for a connection.
  int get waitingCallers => _waiters.length;

  Future<LibPqAsync> _openOne() async {
    final connection = await LibPqAsync.connect(conninfo,
        connectTimeout: connectTimeout,
        libraryPath: libraryPath,
        encoding: encoding,
        typed: typed,
        sessionStatements: sessionStatements,
        queryTimeout: queryTimeout);
    final setup = onOpen;
    if (setup != null) {
      try {
        await setup(connection);
      } catch (_) {
        unawaited(connection.close().catchError((_) {}));
        rethrow;
      }
    }
    return connection;
  }

  bool _expired(LibPqAsync connection) {
    if (DateTime.now().difference(connection.openedAt) > maxConnectionAge) {
      return true;
    }
    final limit = maxCommandCount;
    return limit != null && connection.commandCount >= limit;
  }

  /// Whether [connection] can serve a caller; closes it otherwise.
  Future<bool> _usable(LibPqAsync connection) async {
    if (!connection.isConnected || _expired(connection)) {
      _discard(connection);
      return false;
    }
    if (DateTime.now().difference(connection.lastUsedAt) > idleTestThreshold) {
      try {
        await connection.execute('select 1',
            timeout: const Duration(seconds: 5));
      } catch (_) {
        _discard(connection);
        return false;
      }
    }
    return true;
  }

  Future<LibPqAsync> _acquire() async {
    while (true) {
      if (_closed) throw StateError('This pool was closed');
      while (_idle.isNotEmpty) {
        final connection = _idle.removeLast();
        if (await _usable(connection)) return connection;
      }
      if (_open < maxConnections) {
        _open++;
        try {
          return await _openOne();
        } catch (_) {
          _open--;
          _wakeOne();
          rethrow;
        }
      }
      final waiter = Completer<LibPqAsync?>();
      _waiters.add(waiter);
      final limit = acquireTimeout;
      final LibPqAsync? connection;
      if (limit == null) {
        connection = await waiter.future;
      } else {
        try {
          connection = await waiter.future.timeout(limit);
        } on TimeoutException {
          _waiters.remove(waiter);
          // A connection handed over at the last moment must not be lost.
          unawaited(waiter.future.then((c) {
            if (c != null) _release(c);
          }));
          throw TimeoutException(
              'No connection became free: $_open open', limit);
        }
      }
      if (connection != null) return connection;
    }
  }

  void _wakeOne() {
    if (_waiters.isNotEmpty) _waiters.removeFirst().complete(null);
  }

  void _discard(LibPqAsync connection) {
    _open--;
    _closing.add(connection.close().catchError((_) {}));
    if (_closing.length > 64) _closing.removeRange(0, 32);
  }

  void _release(LibPqAsync connection) {
    if (_closed ||
        !connection.isConnected ||
        _expired(connection) ||
        // A callback that left a transaction open must not hand it over.
        connection.transactionStatus != PqTransactionStatus.idle) {
      _discard(connection);
      _wakeOne();
      return;
    }
    if (_waiters.isNotEmpty) {
      // The next caller tests nothing: it was in use a moment ago.
      _waiters.removeFirst().complete(connection);
    } else {
      _idle.add(connection);
    }
  }

  /// Runs [action] with a connection of its own, returned to the pool after it.
  Future<T> withConnection<T>(
      Future<T> Function(LibPqAsync connection) action) async {
    final connection = await _acquire();
    try {
      return await action(connection);
    } finally {
      _release(connection);
    }
  }

  @override
  Future<PqAsyncResult> execute(String sql,
          {List<Object?> params = const [], Duration? timeout}) =>
      withConnection((c) => c.execute(sql, params: params, timeout: timeout));

  /// Runs [action] in a transaction, on a connection of its own.
  Future<T> transaction<T>(Future<T> Function(PqTransaction tx) action,
          {PqIsolationLevel? isolationLevel,
          bool readOnly = false,
          Duration? timeout}) =>
      withConnection((c) => c.transaction(action,
          isolationLevel: isolationLevel,
          readOnly: readOnly,
          timeout: timeout));

  /// [open] on a connection of its own, returned when the stream ends or its
  /// listener cancels.
  Stream<T> _holdingStream<T>(Stream<T> Function(LibPqAsync c) open) {
    late StreamController<T> controller;
    StreamSubscription<T>? subscription;
    LibPqAsync? held;
    var cancelled = false;

    void release() {
      final connection = held;
      held = null;
      if (connection != null) _release(connection);
    }

    controller = StreamController<T>(
      onListen: () async {
        final LibPqAsync connection;
        try {
          connection = await _acquire();
        } catch (e, s) {
          controller
            ..addError(e, s)
            ..close();
          return;
        }
        if (cancelled) {
          _release(connection);
          return;
        }
        held = connection;
        subscription = open(connection)
            .listen(controller.add, onError: controller.addError, onDone: () {
          release();
          controller.close();
        });
        if (controller.isPaused) subscription!.pause();
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        cancelled = true;
        await subscription?.cancel();
        release();
      },
    );
    return controller.stream;
  }

  @override
  Stream<PqRow> stream(String sql,
          {List<Object?> params = const [], int batchSize = 256}) =>
      _holdingStream(
          (c) => c.stream(sql, params: params, batchSize: batchSize));

  @override
  Future<int> copyFrom(String sql, Stream<List<int>> data) =>
      withConnection((c) => c.copyFrom(sql, data));

  @override
  Future<int> copyRows(
          String table, List<String> columns, Iterable<List<Object?>> rows) =>
      withConnection((c) => c.copyRows(table, columns, rows));

  @override
  Stream<Uint8List> copyTo(String sql) => _holdingStream((c) => c.copyTo(sql));

  @override
  Future<void> notify(String channel, [String payload = '']) =>
      withConnection((c) => c.notify(channel, payload));

  /// Closes the idle connections now, and each one in use when it is returned.
  /// Whoever waits for a connection fails.
  Future<void> close() async {
    _closed = true;
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(null);
    }
    for (final connection in _idle) {
      _discard(connection);
    }
    _idle.clear();
    await Future.wait(_closing.toList());
  }
}
