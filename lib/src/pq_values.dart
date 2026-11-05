import 'dart:convert';
import 'dart:typed_data';

/// Decodes a value in the server's text format by its type oid.
///
/// | PostgreSQL | Dart |
/// | --- | --- |
/// | `int2`, `int4`, `int8`, `oid` | `int` |
/// | `float4`, `float8` | `double` |
/// | `bool` | `bool` |
/// | `numeric` | `String`, the exact text |
/// | `date`, `timestamp` | `DateTime` in UTC, with the fields the server shows |
/// | `timestamptz` | `DateTime` in UTC, the same instant |
/// | `json`, `jsonb` | decoded `Map`, `List`... |
/// | `bytea` | `Uint8List` |
/// | arrays of the above and of text types | `List<T?>` |
/// | everything else | `String`, the server's text |
///
/// A date `DateTime` cannot represent (`infinity`, BC) stays the server's text.
Object? decodePgValue(int oid, Uint8List bytes, Encoding encoding) {
  switch (oid) {
    case _int2:
    case _int4:
    case _int8:
    case _oid:
      return _intFromAscii(bytes) ?? int.parse(encoding.decode(bytes));
    case _bool:
      return bytes.isNotEmpty && bytes[0] == 0x74; // 't'
    case _bytea:
      return decodeByteaBytes(bytes);
  }
  return _decodeText(oid, encoding.decode(bytes), encoding);
}

Object? _decodeText(int oid, String text, Encoding encoding) {
  switch (oid) {
    case _int2:
    case _int4:
    case _int8:
    case _oid:
      return int.parse(text);
    case _bool:
      return text == 't' || text == 'true';
    case _float4:
    case _float8:
      return double.parse(text);
    case _json:
    case _jsonb:
      return jsonDecode(text);
    case _bytea:
      return decodeBytea(text);
    case _date:
    case _timestamp:
      return parsePgTimestamp(text, hasZone: false) ?? text;
    case _timestamptz:
      return parsePgTimestamp(text, hasZone: true) ?? text;
  }
  final element = _arrayElements[oid];
  if (element != null) return parsePgArray(text, element, encoding);
  return text;
}

/// The value of a text-format integer, or null if it is not a plain one.
int? _intFromAscii(Uint8List bytes) {
  final length = bytes.length;
  if (length == 0 || length > 18) return null;
  var i = 0;
  final negative = bytes[0] == 0x2D;
  if (negative) {
    if (length == 1) return null;
    i = 1;
  }
  var value = 0;
  for (; i < length; i++) {
    final digit = bytes[i] - 0x30;
    if (digit < 0 || digit > 9) return null;
    value = value * 10 + digit;
  }
  return negative ? -value : value;
}

int? _digits(String s, int start, int count) {
  if (start + count > s.length) return null;
  var value = 0;
  for (var i = start; i < start + count; i++) {
    final digit = s.codeUnitAt(i) - 0x30;
    if (digit < 0 || digit > 9) return null;
    value = value * 10 + digit;
  }
  return value;
}

/// `YYYY-MM-DD[ HH:MM:SS[.ffffff]][+HH[:MM[:SS]]]` (`DateStyle` ISO) as UTC;
/// null for what `DateTime` cannot represent or another format.
DateTime? parsePgTimestamp(String s, {required bool hasZone}) {
  final year = _digits(s, 0, 4);
  if (year == null || s.length < 10 || s.codeUnitAt(4) != 0x2D) return null;
  final month = _digits(s, 5, 2);
  final day = _digits(s, 8, 2);
  if (month == null || day == null) return null;
  if (s.length == 10) return DateTime.utc(year, month, day);
  if (s.length < 19) return null;
  final hour = _digits(s, 11, 2);
  final minute = _digits(s, 14, 2);
  final second = _digits(s, 17, 2);
  if (hour == null || minute == null || second == null) return null;
  var i = 19;
  var micros = 0;
  if (i < s.length && s.codeUnitAt(i) == 0x2E) {
    i++;
    var scale = 100000;
    while (i < s.length) {
      final digit = s.codeUnitAt(i) - 0x30;
      if (digit < 0 || digit > 9) break;
      micros += digit * scale;
      scale ~/= 10;
      i++;
    }
  }
  var offsetSeconds = 0;
  if (i < s.length) {
    final sign = s.codeUnitAt(i);
    if (!hasZone || (sign != 0x2B && sign != 0x2D)) return null;
    final hours = _digits(s, i + 1, 2);
    if (hours == null) return null;
    i += 3;
    var total = hours * 3600;
    if (i < s.length && s.codeUnitAt(i) == 0x3A) {
      final minutes = _digits(s, i + 1, 2);
      if (minutes == null) return null;
      total += minutes * 60;
      i += 3;
    }
    if (i < s.length && s.codeUnitAt(i) == 0x3A) {
      final seconds = _digits(s, i + 1, 2);
      if (seconds == null) return null;
      total += seconds;
      i += 3;
    }
    if (i != s.length) return null; // "BC" and the like.
    offsetSeconds = sign == 0x2B ? total : -total;
  }
  final value = DateTime.utc(
      year, month, day, hour, minute, second - offsetSeconds, 0, micros);
  return value;
}

/// Parses an array literal (`{1,2,NULL}`, nested, or with `[0:1]={...}` bounds).
List<Object?> parsePgArray(String text, int elementOid, Encoding encoding) {
  var i = 0;
  // Explicit bounds, printed when they do not start at 1.
  if (text.isNotEmpty && text.codeUnitAt(0) == 0x5B) {
    i = text.indexOf('=') + 1;
  }

  late List<Object?> Function() parseArray;

  parseArray = () {
    i++; // '{'
    final values = _newList(elementOid);
    final nested = <Object?>[];
    var isNested = false;
    while (i < text.length) {
      final c = text.codeUnitAt(i);
      if (c == 0x7D) {
        i++;
        return isNested ? nested : values;
      }
      if (c == 0x2C) {
        i++;
        continue;
      }
      if (c == 0x7B) {
        isNested = true;
        nested.add(parseArray());
        continue;
      }
      if (c == 0x22) {
        i++;
        final buffer = StringBuffer();
        while (true) {
          final q = text.codeUnitAt(i);
          if (q == 0x5C) {
            buffer.writeCharCode(text.codeUnitAt(i + 1));
            i += 2;
          } else if (q == 0x22) {
            i++;
            break;
          } else {
            buffer.writeCharCode(q);
            i++;
          }
        }
        values.add(_decodeText(elementOid, buffer.toString(), encoding));
        continue;
      }
      final start = i;
      while (i < text.length) {
        final u = text.codeUnitAt(i);
        if (u == 0x2C || u == 0x7D) break;
        i++;
      }
      final item = text.substring(start, i);
      values
          .add(item == 'NULL' ? null : _decodeText(elementOid, item, encoding));
    }
    throw FormatException('Unterminated array literal', text);
  };

  if (i >= text.length || text.codeUnitAt(i) != 0x7B) {
    throw FormatException('Not an array literal', text);
  }
  return parseArray();
}

List<Object?> _newList(int elementOid) {
  switch (elementOid) {
    case _int2:
    case _int4:
    case _int8:
    case _oid:
      return <int?>[];
    case _float4:
    case _float8:
      return <double?>[];
    case _bool:
      return <bool?>[];
    case _date:
    case _timestamp:
    case _timestamptz:
    case _json:
    case _jsonb:
    case _bytea:
      return <Object?>[];
    default:
      return <String?>[];
  }
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

/// As [decodeBytea], from the bytes of the text.
Uint8List decodeByteaBytes(Uint8List text) {
  if (text.length < 2 || text[0] != 0x5C || text[1] != 0x78) {
    throw FormatException('Not a bytea in hex format');
  }
  final out = Uint8List((text.length - 2) ~/ 2);
  int nibble(int c) => c <= 0x39 ? c - 0x30 : (c <= 0x46 ? c - 0x37 : c - 0x57);
  for (var i = 0; i < out.length; i++) {
    out[i] = nibble(text[2 + i * 2]) << 4 | nibble(text[3 + i * 2]);
  }
  return out;
}

/// A query parameter as the server's text: `null` stays SQL NULL, a [Uint8List]
/// stays bytes (it goes in binary), a [DateTime] goes with its offset, a `List`
/// or `Set` as an array literal (so `= ANY($1)` works), a `Map` as JSON, and any
/// other value is its `toString()`.
///
/// A JSON array for a `json` column is ambiguous with a PostgreSQL array: pass
/// it through `jsonEncode`.
Object? normalizeParam(Object? value) {
  if (value == null || value is String || value is Uint8List) return value;
  if (value is DateTime) return formatPgDateTime(value);
  if (value is Iterable) return _arrayLiteral(value);
  if (value is Map) return jsonEncode(value);
  return value.toString();
}

/// ISO 8601 with the offset: right for `timestamptz`, and `timestamp` keeps the
/// fields of the value (a `timestamp` column ignores the offset).
String formatPgDateTime(DateTime value) {
  final text = value.toIso8601String();
  if (value.isUtc) return text;
  final offset = value.timeZoneOffset;
  final minutes = offset.inMinutes.abs();
  final sign = offset.isNegative ? '-' : '+';
  final hh = (minutes ~/ 60).toString().padLeft(2, '0');
  final mm = (minutes % 60).toString().padLeft(2, '0');
  return '$text$sign$hh:$mm';
}

String _arrayLiteral(Iterable<Object?> values) {
  final buffer = StringBuffer('{');
  var first = true;
  for (final value in values) {
    if (!first) buffer.write(',');
    first = false;
    if (value == null) {
      buffer.write('NULL');
    } else if (value is Uint8List) {
      buffer.write('"\\\\x');
      for (final byte in value) {
        buffer.write(byte.toRadixString(16).padLeft(2, '0'));
      }
      buffer.write('"');
    } else if (value is Iterable) {
      buffer.write(_arrayLiteral(value));
    } else if (value is num || value is bool) {
      buffer.write(value);
    } else {
      final text = value is DateTime
          ? formatPgDateTime(value)
          : value is Map
              ? jsonEncode(value)
              : value.toString();
      buffer
        ..write('"')
        ..write(text.replaceAll(r'\', r'\\').replaceAll('"', r'\"'))
        ..write('"');
    }
  }
  buffer.write('}');
  return buffer.toString();
}

/// One line of `COPY ... FROM STDIN` text format for [values], with its newline.
String formatCopyRow(List<Object?> values) {
  final buffer = StringBuffer();
  for (var i = 0; i < values.length; i++) {
    if (i > 0) buffer.write('\t');
    final value = values[i];
    if (value == null) {
      buffer.write(r'\N');
      continue;
    }
    final normalized =
        value is Uint8List ? _hexBytea(value) : normalizeParam(value);
    _writeCopyEscaped(buffer, normalized as String);
  }
  buffer.write('\n');
  return buffer.toString();
}

String _hexBytea(Uint8List value) {
  final buffer = StringBuffer(r'\x');
  for (final byte in value) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

void _writeCopyEscaped(StringBuffer buffer, String text) {
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    switch (c) {
      case 0x5C:
        buffer.write(r'\\');
      case 0x0A:
        buffer.write(r'\n');
      case 0x0D:
        buffer.write(r'\r');
      case 0x09:
        buffer.write(r'\t');
      case 0x08:
        buffer.write(r'\b');
      case 0x0C:
        buffer.write(r'\f');
      case 0x0B:
        buffer.write(r'\v');
      default:
        buffer.writeCharCode(c);
    }
  }
}

/// [sql] with its `?` placeholders numbered as `$1`, `$2`... (`??` is a literal
/// `?`), for code written for drivers that take them. `?` inside strings,
/// quoted identifiers, comments and dollar quotes is left alone.
String questionMarksToNumbered(String sql) {
  final out = StringBuffer();
  var number = 0;
  var i = 0;
  final n = sql.length;

  bool startsWith(String s) => sql.startsWith(s, i);

  void copyUntil(String end) {
    final at = sql.indexOf(end, i);
    final stop = at < 0 ? n : at + end.length;
    out.write(sql.substring(i, stop));
    i = stop;
  }

  while (i < n) {
    final c = sql.codeUnitAt(i);
    if (c == 0x27 || c == 0x22) {
      // '...' or "...": a doubled quote just ends and starts another one.
      // E'...' allows \' as well.
      final escapes = c == 0x27 &&
          i > 0 &&
          (sql.codeUnitAt(i - 1) | 0x20) == 0x65 &&
          (i < 2 || !_isIdentifierChar(sql.codeUnitAt(i - 2)));
      out.writeCharCode(c);
      i++;
      while (i < n) {
        final q = sql.codeUnitAt(i);
        out.writeCharCode(q);
        i++;
        if (escapes && q == 0x5C && i < n) {
          out.writeCharCode(sql.codeUnitAt(i));
          i++;
        } else if (q == c) {
          break;
        }
      }
    } else if (startsWith('--')) {
      copyUntil('\n');
    } else if (startsWith('/*')) {
      var depth = 1;
      final start = i;
      i += 2;
      while (i < n && depth > 0) {
        if (startsWith('/*')) {
          depth++;
          i += 2;
        } else if (startsWith('*/')) {
          depth--;
          i += 2;
        } else {
          i++;
        }
      }
      out.write(sql.substring(start, i));
    } else if (c == 0x24) {
      final tag = RegExp(r'\$[A-Za-z_]*\$').matchAsPrefix(sql, i);
      if (tag != null &&
          (i == 0 || !_isIdentifierChar(sql.codeUnitAt(i - 1)))) {
        final delimiter = tag.group(0)!;
        out.write(delimiter);
        i += delimiter.length;
        copyUntil(delimiter);
      } else {
        out.writeCharCode(c);
        i++;
      }
    } else if (c == 0x3F) {
      if (startsWith('??')) {
        out.write('?');
        i += 2;
      } else {
        number++;
        out.write('\$$number');
        i++;
      }
    } else {
      out.writeCharCode(c);
      i++;
    }
  }
  return out.toString();
}

bool _isIdentifierChar(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    c == 0x5F ||
    c >= 0x80;

const _bool = 16;
const _bytea = 17;
const _int8 = 20;
const _int2 = 21;
const _int4 = 23;
const _oid = 26;
const _json = 114;
const _float4 = 700;
const _float8 = 701;
const _date = 1082;
const _timestamp = 1114;
const _timestamptz = 1184;
const _jsonb = 3802;

const _text = 25;
const _varchar = 1043;
const _bpchar = 1042;
const _name = 19;
const _numeric = 1700;
const _uuid = 2950;

const _arrayElements = <int, int>{
  1000: _bool,
  1001: _bytea,
  1003: _name,
  1005: _int2,
  1007: _int4,
  1009: _text,
  1014: _bpchar,
  1015: _varchar,
  1016: _int8,
  1021: _float4,
  1022: _float8,
  1028: _oid,
  1115: _timestamp,
  1182: _date,
  1185: _timestamptz,
  1231: _numeric,
  2951: _uuid,
  199: _json,
  3807: _jsonb,
};

/// Windows-1252, for a database or session with `client_encoding` `WIN1252`.
class Windows1252Codec extends Encoding {
  const Windows1252Codec();

  @override
  String get name => 'windows-1252';

  @override
  Converter<List<int>, String> get decoder => const _Win1252Decoder();

  @override
  Converter<String, List<int>> get encoder => const _Win1252Encoder();
}

const _win1252High = <int>[
  0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F, //
  0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, //
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178, //
];

class _Win1252Decoder extends Converter<List<int>, String> {
  const _Win1252Decoder();

  @override
  String convert(List<int> input) {
    final units = Uint16List(input.length);
    for (var i = 0; i < input.length; i++) {
      final b = input[i];
      units[i] = b >= 0x80 && b <= 0x9F ? _win1252High[b - 0x80] : b;
    }
    return String.fromCharCodes(units);
  }
}

class _Win1252Encoder extends Converter<String, List<int>> {
  const _Win1252Encoder();

  @override
  List<int> convert(String input) {
    final out = Uint8List(input.length);
    for (var i = 0; i < input.length; i++) {
      final c = input.codeUnitAt(i);
      if (c < 0x80 || (c >= 0xA0 && c <= 0xFF)) {
        out[i] = c;
      } else {
        final at = _win1252High.indexOf(c);
        if (at < 0) {
          throw ArgumentError.value(input, 'input',
              'U+${c.toRadixString(16)} does not exist in Windows-1252');
        }
        out[i] = 0x80 + at;
      }
    }
    return out;
  }
}
