// fsim-eval-full-strings: the VM service truncates `InstanceRef.valueAsString` to a short preview
// (`valueAsStringIsTruncated`), so an eval result/error longer than ~128 chars is silently corrupted at
// the printer. This pure paging logic reassembles the full value; the VM-service adapter lives in
// fsim.dart.

import 'dart:math';

/// The full string behind a possibly-truncated preview. Not truncated → [preview] as-is (never fetches).
/// Truncated → page the complete value with [fetch]`(offset, count)` — [length] chars total, [chunkSize]
/// per call. A fetch that returns null or the wrong number of chars throws (loud failure over a silent
/// partial value or an infinite loop).
Future<String?> assembleFullString(
  String? preview,
  bool truncated,
  int? length,
  Future<String?> Function(int offset, int count) fetch, {
  int chunkSize = 64 * 1024,
}) async {
  if (!truncated) return preview;
  if (length == null) {
    throw StateError('truncated string has no length — cannot page it');
  }
  final buf = StringBuffer();
  var offset = 0;
  while (offset < length) {
    final want = min(chunkSize, length - offset);
    final chunk = await fetch(offset, want);
    if (chunk == null || chunk.length != want) {
      throw StateError(
        'string paging returned ${chunk == null ? 'null' : '${chunk.length} chars'} '
        'for $want requested at offset $offset of $length',
      );
    }
    buf.write(chunk);
    offset += want;
  }
  return buf.toString();
}
