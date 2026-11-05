import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'pq_async.dart';

/// A pool of [LibPqAsync] connections, each with its own isolate, so queries
/// run in parallel. Connections open when needed, up to [maxConnections], and a
/// lost one is replaced.
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
    this.libraryPath,
    this.encoding = const Utf8Codec(allowMalformed: true),
  }) {
    RangeError.checkNotNegative(maxConnections - 1, 'maxConnections - 1');
  }

  final String conninfo;
  final int maxConnections;
  final Duration connectTimeout;
  final String? libraryPath;
  final Encoding encoding;

  final List<LibPqAsync> _idle = [];
  final Queue<Completer<LibPqAsync?>> _waiters = Queue();
  int _open = 0;
  bool _closed = false;
  final List<Future<void>> _closing = [];

  /// The connections open now, idle or in use.
  int get openConnections => _open;

  /// The connections open and not in use.
  int get idleConnections => _idle.length;

  Future<LibPqAsync> _acquire() async {
    while (true) {
      if (_closed) throw StateError('This pool was closed');
      while (_idle.isNotEmpty) {
        final connection = _idle.removeLast();
        if (connection.isConnected) return connection;
        _discard(connection);
      }
      if (_open < maxConnections) {
        _open++;
        try {
          return await LibPqAsync.connect(conninfo,
              connectTimeout: connectTimeout,
              libraryPath: libraryPath,
              encoding: encoding);
        } catch (_) {
          _open--;
          _wakeOne();
          rethrow;
        }
      }
      final waiter = Completer<LibPqAsync?>();
      _waiters.add(waiter);
      final connection = await waiter.future;
      if (connection != null) return connection;
    }
  }

  void _wakeOne() {
    if (_waiters.isNotEmpty) _waiters.removeFirst().complete(null);
  }

  void _discard(LibPqAsync connection) {
    _open--;
    _closing.add(connection.close().catchError((_) {}));
  }

  void _release(LibPqAsync connection) {
    if (!connection.isConnected) {
      _discard(connection);
      _wakeOne();
      return;
    }
    if (_waiters.isNotEmpty) {
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
  Future<T> transaction<T>(Future<T> Function(PqSession session) action) =>
      withConnection((c) => c.transaction(action));

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
    await Future.wait(_closing);
  }
}
