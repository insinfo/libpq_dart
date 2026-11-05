import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:libpq_dart/libpq_dart.dart';

import 'native_params.dart';

/// A large object wrapper, on a synchronous [LibPq] connection.
///
/// A large object descriptor lives inside a transaction: [open] starts one and
/// [close] commits it.
class LargeObject {
  final LibPq psql;
  int fd = -1;

  /// Large Object Write Mode
  static const int INV_WRITE = 0x00020000;

  /// Large Object Read Mode
  static const int INV_READ = 0x00040000;

  LargeObject(this.psql) {
    fd = -1;
  }

  void _checkOpen() {
    if (fd < 0) throw StateError('The large object is not open');
  }

  /// Deletes a large object
  void delete(int oid) {
    if (psql.pq.lo_unlink(psql.conn, oid) < 0) {
      throw LibPqException(psql.lastErrorMessage);
    }
  }

  /// Exports a large object to a local file
  void export(int oid, String filename, {Allocator allocator = malloc}) {
    final result = using(
        (arena) => psql.pq.lo_export(
            psql.conn, oid, nativeString(filename, psql.encoding, arena)),
        allocator);
    if (result < 0) throw LibPqException(psql.lastErrorMessage);
  }

  /// Imports a local file into a large object and returns its id. [oid] is not
  /// used: the server assigns the id.
  int import(int oid, String filename, {Allocator allocator = malloc}) {
    final id = using(
        (arena) => psql.pq
            .lo_import(psql.conn, nativeString(filename, psql.encoding, arena)),
        allocator);
    // lo_import returns InvalidOid (0) when it fails.
    if (id <= 0) throw LibPqException(psql.lastErrorMessage);
    return id;
  }

  /// Create a new large object and returns the object id
  int create() {
    psql.startTransaction();
    final oid = psql.pq.lo_creat(psql.conn, INV_READ | INV_WRITE);
    if (oid <= 0) {
      final message = psql.lastErrorMessage;
      psql.rollbackTransaction();
      throw LibPqException(message);
    }
    psql.commitTransaction();
    return oid;
  }

  /// Opens a large object for reading/writing
  void open(int id) {
    psql.startTransaction();
    fd = psql.pq.lo_open(psql.conn, id, INV_READ | INV_WRITE);
    if (fd < 0) {
      final message = psql.lastErrorMessage;
      psql.rollbackTransaction();
      throw LibPqException(message);
    }
  }

  /// Closes a large object
  void close() {
    if (fd < 0) return;
    psql.pq.lo_close(psql.conn, fd);
    psql.commitTransaction();
    fd = -1;
  }

  /// Writes the first [length] bytes of [data]; returns the bytes written.
  int write(Uint8List data, int length, {Allocator allocator = malloc}) {
    _checkOpen();
    RangeError.checkValueInInterval(length, 0, data.length, 'length');
    final buf = allocator<Uint8>(length == 0 ? 1 : length);
    try {
      buf.asTypedList(length).setRange(0, length, data);
      final result = psql.pq.lo_write(psql.conn, fd, buf.cast(), length);
      if (result < 0) throw LibPqException(psql.lastErrorMessage);
      return result;
    } finally {
      allocator.free(buf);
    }
  }

  /// Reads up to [length] bytes into [data]; returns the bytes read, 0 at the
  /// end of the object.
  int read(Uint8List data, int length, {Allocator allocator = malloc}) {
    _checkOpen();
    RangeError.checkValueInInterval(length, 0, data.length, 'length');
    final buf = allocator<Uint8>(length == 0 ? 1 : length);
    try {
      final result = psql.pq.lo_read(psql.conn, fd, buf.cast(), length);
      if (result < 0) throw LibPqException(psql.lastErrorMessage);
      data.setRange(0, result, buf.asTypedList(result));
      return result;
    } finally {
      allocator.free(buf);
    }
  }

  /// Returns the length of a large object, and goes back to its start
  int size() {
    _checkOpen();
    psql.pq.lo_lseek(psql.conn, fd, 0, 2);
    final len = psql.pq.lo_tell(psql.conn, fd);
    psql.pq.lo_lseek(psql.conn, fd, 0, 0);
    if (len < 0) throw LibPqException(psql.lastErrorMessage);
    return len;
  }
}
