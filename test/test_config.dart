import 'dart:io';

/// The server of the tests; `LIBPQ_PATH` chooses the library.
final String conninfo = Platform.environment['LIBPQ_TEST_CONNINFO'] ??
    'host=localhost port=5432 dbname=banco_teste user=dart password=dart '
        'sslmode=disable';
