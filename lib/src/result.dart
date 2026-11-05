import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:libpq_dart/src/disposable.dart';
import 'package:libpq_dart/src/extensions/extensions.dart';
import 'package:libpq_dart/src/generated_bindings.dart';
import 'package:libpq_dart/src/pq.dart';

import 'pq_exception.dart';
import 'pq_values.dart';

/// Reads the error fields of a failed [result].
///
/// libpq reports a connection the server closed as a result with a message and
/// no fields: given [connection], such an error gets SQLSTATE 08006.
LibPqException exceptionFromResult(
    LibpqBindings pq, Pointer<pg_result> result, Encoding encoding, String? sql,
    [Pointer<pg_conn>? connection]) {
  String? field(int code) {
    final value = pq.PQresultErrorField(result, code);
    return value == nullptr ? null : value.asDartString(encoding: encoding);
  }

  return LibPqException(
    pq.PQresultErrorMessage(result).asDartString(encoding: encoding).trim(),
    sql: sql,
    sqlState: field(PG_DIAG_SQLSTATE) ??
        (connection != null &&
                pq.PQstatus(connection) != ConnStatusType.CONNECTION_OK
            ? '08006'
            : null),
    severity: field(PG_DIAG_SEVERITY_NONLOCALIZED) ?? field(PG_DIAG_SEVERITY),
    detail: field(PG_DIAG_MESSAGE_DETAIL),
    hint: field(PG_DIAG_MESSAGE_HINT),
    constraint: field(PG_DIAG_CONSTRAINT_NAME),
    table: field(PG_DIAG_TABLE_NAME),
    column: field(PG_DIAG_COLUMN_NAME),
  );
}

/// The result of a query, in native memory until [dispose].
class PqResult implements IDisposable {
  final LibPq psql;
  final String query;

  Pointer<pg_result> res;
  bool _valid = false;
  int _columns = 0;
  int _rows = 0;
  int _status = 0;

  List<String> columnNames = [];

  PqResult(this.psql, this.res, this.query) {
    if (res == nullptr) {
      // libpq returns null on out of memory or a lost connection.
      throw LibPqException(
          psql.lastErrorMessage.isEmpty
              ? 'libpq returned no result'
              : psql.lastErrorMessage.trim(),
          sql: query);
    }

    _status = psql.pq.PQresultStatus(res);
    _valid = (_status == ExecStatusType.PGRES_COMMAND_OK ||
        _status == ExecStatusType.PGRES_TUPLES_OK);

    if (!_valid) {
      final error =
          exceptionFromResult(psql.pq, res, psql.encoding, query, psql.conn);
      dispose();
      throw error;
    }

    _columns = psql.pq.PQnfields(res);
    _rows = psql.pq.PQntuples(res);
    for (int i = 0; i < _columns; i++) {
      columnNames
          .add(psql.pq.PQfname(res, i).asDartString(encoding: psql.encoding));
    }
  }

  void _checkCell(int row, int column) {
    if (res == nullptr) throw StateError('This result was disposed');
    if (row < 0 || row >= _rows || column < 0 || column >= _columns) {
      throw LibPqException("Row or column index out of range!");
    }
  }

  /// The rows as maps of column name to text; SQL NULL is `null`.
  List<Map<String, dynamic>> asMapList() {
    final result = <Map<String, dynamic>>[];
    if (valid == false) {
      return result;
    }
    if (empty) {
      return result;
    }

    for (int r = 0; r < _rows; r++) {
      final map = <String, dynamic>{};
      for (int c = 0; c < _columns; c++) {
        map[columnNames[c]] = getValue(r, c);
      }
      result.add(map);
    }
    return result;
  }

  /// The rows affected by the command, or returned by a `SELECT`; 0 for a
  /// command that has no such count (`CREATE TABLE`, `SET`...).
  int get affectedRows {
    if (res == nullptr) throw StateError('This result was disposed');
    return int.tryParse(
            psql.pq.PQcmdTuples(res).asDartString(encoding: psql.encoding)) ??
        0;
  }

  /// The command tag (`INSERT 0 1`, `SELECT 3`...).
  String get commandTag {
    if (res == nullptr) throw StateError('This result was disposed');
    return psql.pq.PQcmdStatus(res).asDartString(encoding: psql.encoding);
  }

  /// Returns true, if the result is empty
  bool get empty {
    return _rows == 0;
  }

  /// Returns true, if the result is valid
  bool get valid {
    return _valid;
  }

  /// Returns the number of columns in the result
  int get columns {
    return _columns;
  }

  /// Returns the number of rows in the result
  int get rows {
    return _rows;
  }

  /// Whether the value is SQL NULL.
  bool isNull(int row, int column) {
    _checkCell(row, column);
    return psql.pq.PQgetisnull(res, row, column) == 1;
  }

  /// The value as text; `null` for SQL NULL.
  String? getValue(int row, int column, {Encoding? encoding}) =>
      isNull(row, column)
          ? null
          : getValueAsString(row, column, encoding: encoding);

  /// The value decoded by its type (see `decodePgValue`); `null` for SQL NULL.
  Object? getTyped(int row, int column) {
    if (isNull(row, column)) return null;
    return decodePgValue(columnType(column), _nativeBytes(row, column, null),
        psql.encoding, psql.infinity);
  }

  /// The rows as maps of column name to value decoded by its type, as the other
  /// PostgreSQL drivers return them. [asMapList] keeps the server's text.
  List<Map<String, dynamic>> toColumnMaps() => [
        for (var r = 0; r < _rows; r++)
          {for (var c = 0; c < _columns; c++) columnNames[c]: getTyped(r, c)}
      ];

  /// The value as text; an empty string for SQL NULL (see [getValue]).
  String getValueAsString(int row, int column,
      {int? length, Encoding? encoding}) {
    return (encoding ?? psql.encoding)
        .decode(_nativeBytes(row, column, length));
  }

  /// A view of the value in native memory, valid only until [dispose].
  Uint8List _nativeBytes(int row, int column, int? length) {
    _checkCell(row, column);
    if (length != null) RangeError.checkNotNegative(length, 'length');
    return psql.pq
        .PQgetvalue(res, row, column)
        .cast<Uint8>()
        .asTypedList(length ?? psql.pq.PQgetlength(res, row, column));
  }

  /// Access to the data
  String getValueByColNameAsString(int row, String column,
      {int? length, Encoding? encoding}) {
    if (row < 0 || row >= rows) throw LibPqException("Row index out of range!");
    return getValueAsString(row, columnIndex(column),
        length: length, encoding: encoding);
  }

  /// A copy of the value's bytes as the server sent them: for a `bytea` column
  /// this is the text `\x...`; see [getBytea].
  Uint8List getValueAsBytes(int row, int column, {int? length}) {
    return Uint8List.fromList(_nativeBytes(row, column, length));
  }

  /// The bytes of a `bytea` column; `null` for SQL NULL.
  Uint8List? getBytea(int row, int column) {
    final text = getValue(row, column);
    return text == null ? null : decodeBytea(text);
  }

  int columnIndex(String column) {
    final index = columnNames.indexOf(column);
    if (index < 0) throw LibPqException("Column $column not found!");
    return index;
  }

  /// Returns the column name
  String columnName(int column) {
    if (column < 0 || column >= columns) {
      throw LibPqException("Column index out of range!");
    }
    return columnNames[column];
  }

  /// Returns the name of the column's type. It runs a query the first time a
  /// type is asked for, so it must not be called while another result is being
  /// read in single row mode.
  String columnTypeName(int column) {
    return psql.pqftypename(columnType(column));
  }

  /// Returns the column type oid
  int columnType(int column) {
    if (res == nullptr) throw StateError('This result was disposed');
    if (column < 0 || column >= columns) {
      throw LibPqException("Column index out of range!");
    }
    return psql.pq.PQftype(res, column);
  }

  /// A `boolean` value: the server sends `t` or `f`.
  bool getBoolean(int row, int column) {
    final text = getValueAsString(row, column);
    switch (text) {
      case 't':
      case 'true':
      case '1':
        return true;
      case 'f':
      case 'false':
      case '0':
        return false;
    }
    throw FormatException('Not a boolean', text);
  }

  int getInt(int row, int column) {
    return int.parse(getValueAsString(row, column));
  }

  double getDouble(int row, int column) {
    return double.parse(getValueAsString(row, column));
  }

  void dump() {
    for (int col = 0; col < columns; col++) {
      stdout.write(columnNames[col].padLeft(15));
    }
    stdout.writeln();
    for (int row = 0; row < rows; row++) {
      for (int col = 0; col < columns; col++) {
        stdout.write((getValue(row, col) ?? 'NULL').padLeft(15));
      }
      stdout.writeln();
    }
  }

  @override
  void dispose() {
    if (res != nullptr) {
      psql.pq.PQclear(res);
      res = nullptr;
    }
  }
}
