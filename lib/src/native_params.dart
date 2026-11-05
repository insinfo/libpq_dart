import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

/// A query parameter as text, for the server to convert: `null` is SQL NULL,
/// a [Uint8List] goes in binary, a [DateTime] in ISO 8601, and any other value
/// is its `toString()`.
Object? normalizeParam(Object? value) {
  if (value == null || value is String || value is Uint8List) return value;
  if (value is DateTime) return value.toIso8601String();
  return value.toString();
}

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

/// The bytes of a `bytea` value in the server's text format (`\x...` hex).
Uint8List decodeBytea(String text) {
  if (!text.startsWith(r'\x')) {
    throw FormatException('Not a bytea in hex format', text);
  }
  final out = Uint8List((text.length - 2) ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(text.substring(2 + i * 2, 4 + i * 2), radix: 16);
  }
  return out;
}
