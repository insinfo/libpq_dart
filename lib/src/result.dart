import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:libpq_dart/src/disposable.dart';
import 'package:libpq_dart/src/extensions/extensions.dart';
import 'package:libpq_dart/src/generated_bindings.dart';
import 'package:libpq_dart/src/pq.dart';

import 'pq_exception.dart';

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
      throw LibPqException("Result is nullptr");
    }

    _status = psql.pq.PQresultStatus(res);
    _valid = (_status == ExecStatusType.PGRES_COMMAND_OK ||
        _status == ExecStatusType.PGRES_TUPLES_OK);
    _columns = psql.pq.PQnfields(res);
    _rows = psql.pq.PQntuples(res);

    for (int i = 0; i < _columns; i++) {
      columnNames
          .add(psql.pq.PQfname(res, i).asDartString(encoding: psql.encoding));
    }

    if (_status != ExecStatusType.PGRES_COMMAND_OK &&
        _status != ExecStatusType.PGRES_TUPLES_OK) {
      final message = psql.pq
          .PQresultErrorMessage(res)
          .asDartString(encoding: psql.encoding);
      dispose();
      throw LibPqException(message, sql: query);
    }
  }

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
        map[columnName(c)] = getValueAsString(r, c);
      }
      result.add(map);
    }
    return result;
  }

  int get affectedRows {
    return int.parse(
        psql.pq.PQcmdTuples(res).asDartString(encoding: psql.encoding));
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

  /// Access to the data
  // dynamic operator [](int index){
  // }
  /// Access to the data
  String getValueAsString(int row, int column,
      {int? length, Encoding? encoding}) {
    if (row < 0 || row >= rows || column < 0 || column >= columns)
      throw LibPqException("Row or column index out of range!");
    final valuePoiter = psql.pq.PQgetvalue(res, row, column);

    int _length(Pointer<Uint8> codeUnits) {
      var length = 0;
      while (codeUnits[length] != 0) {
        length++;
      }
      return length;
    }

    final codeUnits = valuePoiter.cast<Uint8>();
    if (length != null) {
      RangeError.checkNotNegative(length, 'length');
    } else {
      length = _length(codeUnits);
    }
    final bytes = codeUnits.asTypedList(length);

    return encoding != null
        ? encoding.decode(bytes)
        : psql.encoding.decode(bytes);
  }

  /// Access to the data
  String getValueByColNameAsString(int row, String column,
      {int? length, Encoding? encoding}) {
    if (row < 0 || row >= rows) throw LibPqException("Row index out of range!");
    for (int i = 0; i < columns; i++) {
      if (columnNames[i] == column)
        return getValueAsString(row, i, length: length, encoding: encoding);
    }
    throw LibPqException("Column $column not found!");
  }

  Uint8List getValueAsBytes(int row, int column, {int? length}) {
    if (row < 0 || row >= rows || column < 0 || column >= columns)
      throw LibPqException("Row or column index out of range!");
    final valuePoiter = psql.pq.PQgetvalue(res, row, column);

    int _length(Pointer<Uint8> codeUnits) {
      var length = 0;
      while (codeUnits[length] != 0) {
        length++;
      }
      return length;
    }

    final codeUnits = valuePoiter.cast<Uint8>();
    if (length != null) {
      RangeError.checkNotNegative(length, 'length');
    } else {
      length = _length(codeUnits);
    }
    return codeUnits.asTypedList(length);
  }

  int columnIndex(String column) {
    for (int i = 0; i < columns; i++) {
      if (columnNames[i] == column) return i;
    }
    throw LibPqException("Column ${column} not found!");
  }

  /// Returns the column name
  String columnName(int column) {
    if (column < 0 || column >= columns)
      throw LibPqException("Column index out of range!");
    return columnNames[column];
  }

  /// Returns the column name
  String columnTypeName(int column) {
    if (column < 0 || column >= columns)
      throw LibPqException("Column index out of range!");
    return psql.pqftypename(psql.pq.PQftype(res, column));
  }

  /// Returns the column type oid
  int columnType(int column) {
    if (column < 0 || column >= columns)
      throw LibPqException("Column index out of range!");
    return psql.pq.PQftype(res, column);
  }

  bool getBoolean(int row, int column) {
    return bool.parse(getValueAsString(row, column));
  }

  int getInt(int row, int column) {
    return int.parse(getValueAsString(row, column));
  }

  double getDouble(int row, int column) {
    return double.parse(getValueAsString(row, column));
  }

  void dump() {
    for (int col = 0; col < columns; col++)
      stdout.write('${columnNames[col].toString().padLeft(15)}');
    stdout.writeln();
    for (int row = 0; row < rows; row++) {
      for (int col = 0; col < columns; col++)
        stdout.write('${getValueAsString(row, col).toString().padLeft(15)}');
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
