import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'pq_values.dart';

/// The native arrays of `PQexecParams`, allocated in [arena].
class NativeParams {
  final int count;
  final Pointer<Pointer<Char>> values;
  final Pointer<Int> lengths;
  final Pointer<Int> formats;

  NativeParams._(this.count, this.values, this.lengths, this.formats);

  factory NativeParams.allocate(
      List<Object?> params, Encoding encoding, Allocator arena) {
    final count = params.length;
    if (count == 0) return NativeParams._(0, nullptr, nullptr, nullptr);
    final values = arena<Pointer<Char>>(count);
    final lengths = arena<Int>(count);
    final formats = arena<Int>(count);
    for (var i = 0; i < count; i++) {
      final param = normalizeParam(params[i]);
      if (param == null) {
        values[i] = nullptr;
        lengths[i] = 0;
        formats[i] = 0;
        continue;
      }
      final binary = param is Uint8List;
      final bytes = binary ? param : encoding.encode(param as String);
      // One more byte: text values are read up to their terminator.
      final buffer = arena<Uint8>(bytes.length + 1);
      final view = buffer.asTypedList(bytes.length + 1);
      view.setAll(0, bytes);
      view[bytes.length] = 0;
      values[i] = buffer.cast();
      lengths[i] = bytes.length;
      formats[i] = binary ? 1 : 0;
    }
    return NativeParams._(count, values, lengths, formats);
  }
}

/// A zero-terminated copy of [text], allocated in [arena].
Pointer<Char> nativeString(String text, Encoding encoding, Allocator arena) {
  final bytes = encoding.encode(text);
  final buffer = arena<Uint8>(bytes.length + 1);
  final view = buffer.asTypedList(bytes.length + 1);
  view.setAll(0, bytes);
  view[bytes.length] = 0;
  return buffer.cast();
}
