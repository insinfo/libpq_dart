/// An error from libpq or from the server.
class LibPqException implements Exception {
  /// The statement that failed, when there is one.
  final String? sql;

  final String message;

  /// Kept for compatibility: always -1. Use [sqlState].
  final int errorCode;

  /// The SQLSTATE of a server error (`23505`, `42P01`...); null for an error
  /// that did not come from the server.
  final String? sqlState;

  /// The severity of a server error (`ERROR`, `FATAL`...).
  final String? severity;

  /// The optional detail of a server error.
  final String? detail;

  /// The optional hint of a server error.
  final String? hint;

  LibPqException(
    this.message, {
    this.sql,
    this.errorCode = -1,
    this.sqlState,
    this.severity,
    this.detail,
    this.hint,
  });

  @override
  String toString() =>
      'LibPqException${sqlState == null ? '' : ' [$sqlState]'}: $message';
}
