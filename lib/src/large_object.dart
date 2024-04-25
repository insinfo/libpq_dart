import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:libpq_dart/libpq_dart.dart';

/// A large object wrapper
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

  /// Deletes a large object
  void delete(int oid) {
    if (psql.pq.lo_unlink(psql.conn, oid) < 0)
      throw LibPqException(psql.lastErrorMessage);
  }

  /// Exports a large object to a local file
  void export(int oid, String filename, {Allocator allocator = malloc}) {
    if (psql.pq.lo_export(psql.conn, oid,
            filename.asCharP(allocator: allocator, encoding: psql.encoding)) <
        0) throw LibPqException(psql.lastErrorMessage);
  }

  /// Imports a local file into a large object and returns its id
  int import(int oid, String filename, {Allocator allocator = malloc}) {
    int id = psql.pq.lo_import(psql.conn,
        filename.asCharP(allocator: allocator, encoding: psql.encoding));
    if (id < 0) throw LibPqException(psql.lastErrorMessage);

    return id;
  }

  /// Create a new large object and returns the object id
  int create() {
    psql.startTransaction();
    int oid = psql.pq.lo_creat(psql.conn, INV_READ | INV_WRITE);
    psql.comitTransaction();
    return oid;
  }

  /// Opens a large object for reading/writing
  void open(int id) {
    psql.startTransaction();
    fd = psql.pq.lo_open(psql.conn, id, INV_READ | INV_WRITE);
    if (fd < 0) {
      psql.rollbackTransaction();
      throw LibPqException(psql.lastErrorMessage);
    }
  }

  /// Closes a large object
  void close() {
    if (fd < 0) return;
    psql.pq.lo_close(psql.conn, fd);
    psql.comitTransaction();
    fd = -1;
  }

  /// Write data to the large object
  int write(Uint8List data, int length, {Allocator allocator = malloc}) {
    Pointer<Char> buf = allocator<Char>(length);
    for (int i = 0; i < length; i++) {
      buf[i] = data[i];
    }
    final result = psql.pq.lo_write(psql.conn, fd, buf, length);
    allocator.free(buf);
    return result;
  }

  /// Reads data from the large object
  int read(Uint8List data, int length, {Allocator allocator = malloc}) {
    Pointer<Char> buf = allocator<Char>(length);
    for (int i = 0; i < length; i++) {
      buf[i] = data[i];
    }
    final result = psql.pq.lo_read(psql.conn, fd, buf, length);
    allocator.free(buf);
    return result;
  }

  /// Returns the length of a large object
  int size() {
    psql.pq.lo_lseek(psql.conn, fd, 0, 2);
    int len = psql.pq.lo_tell(psql.conn, fd);
    psql.pq.lo_lseek(psql.conn, fd, 0, 0);
    return len;
  }
}
