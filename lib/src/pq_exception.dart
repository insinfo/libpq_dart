/// An error from libpq or from the server.
class LibPqException implements Exception {
  /// The statement that failed, when there is one.
  final String? sql;

  final String message;

  /// Kept for compatibility: always -1. Use [sqlState].
  final int errorCode;

  /// The SQLSTATE of a server error (`23505`, `42P01`...). A connection that
  /// was lost has `08006`, also when the server did not say so. Null for other
  /// errors of the client.
  final String? sqlState;

  /// The severity of a server error (`ERROR`, `FATAL`...).
  final String? severity;

  /// The optional detail of a server error.
  final String? detail;

  /// The optional hint of a server error.
  final String? hint;

  /// The constraint a server error refers to (a unique violation, for example).
  final String? constraint;

  /// The table a server error refers to.
  final String? table;

  /// The column a server error refers to.
  final String? column;

  LibPqException(
    this.message, {
    this.sql,
    this.errorCode = -1,
    this.sqlState,
    this.severity,
    this.detail,
    this.hint,
    this.constraint,
    this.table,
    this.column,
  });

  @override
  String toString() =>
      'LibPqException${sqlState == null ? '' : ' [$sqlState]'}: $message';
}
