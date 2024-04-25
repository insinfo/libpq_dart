import 'dart:io';
import 'dart:typed_data';

import 'package:libpq_dart/libpq_dart.dart';

/// The synchronization mode
enum SyncMode { Complete, Incremental }

class PSync implements IDisposable {
  final LibPq src;
  final LibPq dst;

  List<String> srcTables = [];
  List<String> dstTables = [];

  bool _delete = false;
  SyncMode _mode = SyncMode.Incremental;

  /// Should tables on destination deleted that are not existing on source
  bool get delete {
    return _delete;
  }

  /// The synchronization mode
  SyncMode get mode {
    return _mode;
  }

  /// [src] The configuration string for the source database
  /// [dst] The configuration string for the destination database
  PSync(this.src, this.dst);

  /// Start synchronization
  void start() {
    srcTables = listAllTables(src);
    dstTables = listAllTables(dst);

    if (srcTables.isEmpty || dstTables.isEmpty) return;

    print("Source has #${srcTables.length} tables...");
    print("Destination has #${dstTables.length} tables...");

    print("Synchronizing tables...");

    switch (mode) {
      case SyncMode.Complete:
        {
          for (String table in srcTables) {
            if (!dstTables.contains(table)) createTable(table);
            syncContent(table);
          }
        }
        break;
      case SyncMode.Incremental:
        {
          for (String table in srcTables) {
            if (dstTables.contains(table)) continue;
            createTable(table);
            syncContent(table);
          }
        }
        break;
    }

    if (delete) {
      print("Deleting tables...");
      for (String table in dstTables) {
        if (srcTables.contains(table)) continue;
        print(
          " - ${table}",
        );
        dst.exec("drop table ${table}").dispose();
      }
    }
  }

  @override
  void dispose() {
    //if (src != null)
    src.dispose();
    //	if (dst != null)
    dst.dispose();
  }

  /// get table primary keys from source connection
  List<String> getPrimaryKeys(String table, LibPq conn) {
    final result = conn.exec(
        "SELECT kcu.column_name FROM information_schema.table_constraints tc JOIN information_schema.key_column_usage kcu ON tc.constraint_catalog = kcu.constraint_catalog AND tc.constraint_name = kcu.constraint_name WHERE kcu.table_name = '$table' and tc.constraint_type ='PRIMARY KEY'");
    final pkeys = <String>[];
    for (int row = 0; row < result.rows; row++) {
      pkeys.add(result.getValueAsString(row, 0));
    }
    result.dispose();
    return pkeys;
  }

  List<int> getAllOidColumns(String table, LibPq conn) {
    final oids = <int>[];
    final result = conn.exec(
        "select data_type from information_schema.columns where table_name = '$table' order by ordinal_position");
    for (int row = 0; row < result.rows; row++) {
      if (result.getValueByColNameAsString(row, "data_type").toLowerCase() ==
          "oid") oids.add(row);
    }
    result.dispose();
    return oids;
  }

  void syncContent(String table) {
    List<int> oids = getAllOidColumns(table, src);
    if (oids.length == 0)
      syncContentNoOids(table);
    else
      syncContentWithOids(table, oids);
    print('');
  }

  int copyOid(int oid) {
    print("Copying large object $oid...");
    LargeObject lsrc = LargeObject(src);
    LargeObject ldst = LargeObject(dst);
    int id = ldst.create();
    lsrc.open(oid);
    ldst.open(id);
    var buf = Uint8List(2048);
    int s;
    while ((s = lsrc.read(buf, 2048)) > 0) ldst.write(buf, s);

    lsrc.close();
    ldst.close();
    return id;
  }

  /// Creates a table on destination
  /// [table] Table to be created
  void createTable(String table) {
    print("Creating table $table...");
    late PqResult result;
    try {
      final pkeys = getPrimaryKeys(table, src);
      result = src.exec(
          "select column_name, is_nullable, data_type from information_schema.columns where table_name = '$table' order by ordinal_position");
      var command = "create table $table(";
      for (int row = 0; row < result.rows; row++) {
        final name = result.getValueByColNameAsString(row, "column_name");
        final type = result.getValueByColNameAsString(row, "data_type");
        var options =
            (result.getValueByColNameAsString(row, "is_nullable") == "YES"
                ? ""
                : "not null");

        if (pkeys.contains(name)) options += " primary key";

        final comma = (row + 1 < result.rows ? "," : "");
        command += "$name $type $options$comma";
      }
      command += ")";

      print('createTable command: $command');

      try {
        result = dst.exec(command);
      } catch (e) {
        print('createTable e: $e');
      } finally {
        result.dispose();
      }
    } catch (e) {
      print('createTable e: $e');
    } finally {
      result.dispose();
    }
  }

  void syncContentWithOids(String table, List<int> oids) {
    PqResult result;
    String command, _select, _where, _from;
    bool first;
    List<String> primaryKeys = getPrimaryKeys(table, src);

    result = src.exec('select * from "$table"');
    //result.Dump();
    for (int row = 0; row < result.rows; row++) {
      progress(table, row / result.rows, 60);
      _select = "select";
      _from = " from";
      _where = " where";

      // Compose the select block
      first = true;
      for (int oid in oids) {
        if (!first) _select += ",";
        // Get the md5 hash value for the oid-column
        _select += " md5(${result.columnName(oid)})";
        first = false;
      }

      // Data from the table we are currently working on
      _from += table;

      // The row identified by the primary keys of the table
      first = true;
      for (String key in primaryKeys) {
        if (!first) _where += " and";
        _where +=
            " $key='${result.getValueAsString(row, result.columnIndex(key))}'";
        first = false;
      }
      command = _select + _from + _where;

      PqResult r1, r2;
      try {
        r1 = dst.exec(command);
        if (r1.rows > 0) {
          r2 = src.exec(command);

          // Compare large objects
          for (int c = 0; c < r1.columns; c++) {
            if (r1.getValueAsString(0, c) != r2.getValueAsString(0, c)) {
              int id = copyOid(result.getInt(row, oids[c]));
              command =
                  "update $table set ${result.columnName(oids[c])}='$id'$_where";
              dst.exec(command).dispose();
            }
          }

          r1.dispose();
          r2.dispose();
        } else {
          r1.dispose();
          command = "insert into $table values(";
          first = true;
          for (int col = 0; col < result.columns; col++) {
            if (!first) command += ",";
            command += " '${result.getValueAsString(row, col)}'";
            first = false;
          }
          command += ")";
          dst.exec(command).dispose();
          for (int oid in oids) {
            int id = copyOid(result.getInt(row, oid));
            command =
                "update $table set ${result.columnName(oid)}='$id'$_where";
            dst.exec(command).dispose();
          }
          //Console.WriteLine("Insert data into table");
        }
      } catch (e) {
        // Console.WriteLine(e.Message);
        for (int oid in oids) {
          int id = copyOid(result.getInt(row, oid));
          command = "update $table set ${result.columnName(oid)}='$id'$_where";
          dst.exec(command).dispose();
        }
      }
    }
    result.dispose();
    progress(table, 1.0, 60);
  }

  void syncContentNoOids(String table) {
    PqResult? result;
    bool first;
    List<String> pkeys = getPrimaryKeys(table, src);

    result = src.exec('select * from "$table"');
    for (int row = 0; row < result.rows; row++) {
      progress(table, row / result.rows, 60);
      String command = '';

      // try update first
      command = 'update "$table" set ';
      first = true;
      for (int col = 0; col < result.columns; col++) {
        if (pkeys.contains(result.columnName(col))) continue;
        if (!first) command += ",";
        command +=
            "${result.columnName(col)}='${result.getValueAsString(row, col)}'";
        first = false;
      }
      command += " where";
      for (int i = 0; i < pkeys.length; i++) {
        if (i != 0) command += " and";
        command +=
            " ${pkeys[i]}='${result.getValueByColNameAsString(row, pkeys[i])}'";
      }
      PqResult tmp = dst.exec(command);
      if (tmp.affectedRows == 1) {
        tmp.dispose();
        continue;
      }
      tmp.dispose();

      // insert values
      command = "insert into $table values(";
      first = true;
      for (int col = 0; col < result.columns; col++) {
        if (!first) command += ",";
        command += "'${result.getValueAsString(row, col)}'";
        first = false;
      }
      command += ")";
      dst.exec(command).dispose();
    }
    result.dispose();
    progress(table, 1.0, 60);
  }

  /// Lists all tables in a database
  List<String> listAllTables(LibPq db) {
    PqResult? result;
    try {
      List<String> tables = <String>[];

      result = db.exec(
          "select table_name from information_schema.tables where table_schema='public' and table_type='BASE TABLE'");
      for (int row = 0; row < result.rows; row++)
        tables.add(result.getValueAsString(row, 0));
      result.dispose();
      return tables;
    } catch (e) {
      print(e);
      if (result != null && result.valid) result.dispose();
      return [];
    }
  }

  void progress(String title, double p, int size) {
    int x = (p * size).floor();
    stdout.write('${title.padRight(20)} |');
    for (int i = 0; i < size; i++) {
      if (i <= x)
        stdout.write('=');
      else
        stdout.write('-');
    }
    stdout.write('| ${(p * 100).floor()}%\r');
  }
}
