import 'dart:ffi';
import 'dart:io';

import 'pq_exception.dart';

/// The names tried for the libpq library, in order. `libpq.so` usually comes
/// only with the development package, so `libpq.so.5` comes first on Linux.
List<String> defaultLibraryNames() {
  if (Platform.isWindows) return const ['libpq.dll'];
  if (Platform.isMacOS) {
    return const [
      'libpq.5.dylib',
      'libpq.dylib',
      '/opt/homebrew/opt/libpq/lib/libpq.5.dylib',
      '/usr/local/opt/libpq/lib/libpq.5.dylib',
    ];
  }
  if (Platform.isLinux) return const ['libpq.so.5', 'libpq.so'];
  throw UnsupportedError(
      'libpq_dart does not support ${Platform.operatingSystem}');
}

/// Opens libpq: [path] if given, else the `LIBPQ_PATH` environment variable,
/// else [defaultLibraryNames] through the system's library search.
DynamicLibrary openLibpq([String? path]) {
  final chosen = path ?? Platform.environment['LIBPQ_PATH'];
  final candidates = chosen != null ? [chosen] : defaultLibraryNames();
  final errors = <String>[];
  for (final candidate in candidates) {
    try {
      return DynamicLibrary.open(candidate);
    } on ArgumentError catch (e) {
      errors.add('$candidate: ${e.message}');
    }
  }
  throw LibPqException('Could not load libpq. Install it, or pass its path '
      '(dllPath, or the LIBPQ_PATH environment variable). Tried:\n'
      '${errors.join('\n')}');
}
