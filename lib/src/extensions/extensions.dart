import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Extension method for converting a [String] to a `Pointer<Utf8>`.
extension StringUtf8PointerCustom on String {
  /// Creates a zero-terminated [Utf8] code-unit array from this String.
  ///
  /// If this [String] contains NUL characters, converting it back to a string
  /// using [Utf8Pointer.asUtf8P] will truncate the result if a length is
  /// not passed.
  ///
  /// Unpaired surrogate code points in this [String] will be encoded as
  /// replacement characters (U+FFFD, encoded as the bytes 0xEF 0xBF 0xBD) in
  /// the UTF-8 encoded result. See [Utf8Encoder] for details on encoding.
  ///
  /// Returns an [allocator]-allocated pointer to the result.
  Pointer<Utf8> asUtf8P({Allocator allocator = malloc, Encoding? encoding}) {
    final units = encoding != null ? encoding.encode(this) : utf8.encode(this);
    final Pointer<Uint8> result = allocator<Uint8>(units.length + 1);
    final Uint8List nativeString = result.asTypedList(units.length + 1);
    nativeString.setAll(0, units);
    nativeString[units.length] = 0;
    return result.cast();
  }

  /// Returns *const char
  Pointer<Int8> asInt8({Allocator allocator = malloc, Encoding? encoding}) {
    final units = encoding != null ? encoding.encode(this) : utf8.encode(this);
    final Pointer<Uint8> result = allocator<Uint8>(units.length + 1);
    final Uint8List nativeString = result.asTypedList(units.length + 1);
    nativeString.setAll(0, units);
    nativeString[units.length] = 0;
    return result.cast();
  }

  /// Returns * char
  Pointer<Char> asCharP({Allocator allocator = malloc, Encoding? encoding}) {
    final units = encoding != null ? encoding.encode(this) : utf8.encode(this);

    final Pointer<Uint8> result = allocator<Uint8>(units.length + 1);
    final Uint8List nativeString = result.asTypedList(units.length + 1);
    nativeString.setAll(0, units);
    nativeString[units.length] = 0;
    return result.cast();
  }
}

extension CharPointerExtension on Pointer<Char> {
  /// The number of UTF-8 code units in this zero-terminated UTF-8 string.
  ///
  /// The UTF-8 code units of the strings are the non-zero code units up to the
  /// first zero code unit.
  int get length {
    _ensureNotNullptr('length');
    final codeUnits = cast<Uint8>();
    return _length(codeUnits);
  }

  /// Converts this UTF-8 encoded string to a Dart string.
  ///
  /// Decodes the UTF-8 code units of this zero-terminated byte array as
  /// Unicode code points and creates a Dart string containing those code
  /// points.
  ///
  /// If [length] is provided, zero-termination is ignored and the result can
  /// contain NUL characters.
  ///
  /// If [length] is not provided, the returned string is the string up til
  /// but not including  the first NUL character.
  String asDartString({int? length, Encoding? encoding}) {
    _ensureNotNullptr('toDartString');
    final codeUnits = cast<Uint8>();
    if (length != null) {
      RangeError.checkNotNegative(length, 'length');
    } else {
      length = _length(codeUnits);
    }
    if (encoding != null) {
      return encoding.decode(codeUnits.asTypedList(length));
    }
    return utf8.decode(codeUnits.asTypedList(length), allowMalformed: true);
  }

  static int _length(Pointer<Uint8> codeUnits) {
    var length = 0;
    while (codeUnits[length] != 0) {
      length++;
    }
    return length;
  }

  void _ensureNotNullptr(String operation) {
    if (this == nullptr) {
      throw UnsupportedError(
          "Operation '$operation' not allowed on a 'nullptr'.");
    }
  }
}
