class LibPqException implements Exception {
  final String? sql;
  final String message;
  final int errorCode;

  LibPqException(this.message, {this.sql, this.errorCode = -1});

  @override
  String toString() {
    return 'LibPqException: $message';
  }
}
