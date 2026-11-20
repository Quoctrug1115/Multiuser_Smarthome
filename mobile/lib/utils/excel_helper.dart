import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class ExcelHelper {
  /// Giải mã file .xlsx an toàn, tự động bỏ qua lỗi numFmtId < 164 của LibreOffice/WPS
  static Excel decodeBytesSafe(Uint8List bytes) {
    try {
      return Excel.decodeBytes(bytes);
    } catch (e) {
      if (!e.toString().contains('numFmtId')) rethrow;

      final archive = ZipDecoder().decodeBytes(bytes);
      final rebuilt = Archive();

      for (final file in archive.files) {
        if (file.isFile && file.name == 'xl/styles.xml') {
          final rawXml = utf8.decode(
            file.content as List<int>,
            allowMalformed: true,
          );
          // Loại bỏ các thẻ numFmt có numFmtId < 164 gây crash parser
          final cleanedXml = rawXml.replaceAllMapped(
            RegExp(r'<numFmt\b[^>]*\bnumFmtId="(\d+)"[^>]*\/?>'),
            (match) {
              final id = int.tryParse(match.group(1) ?? '') ?? 164;
              return id < 164 ? '' : match.group(0)!;
            },
          );
          final encoded = utf8.encode(cleanedXml);
          rebuilt.addFile(ArchiveFile(file.name, encoded.length, encoded));
        } else if (file.isFile) {
          rebuilt.addFile(
            ArchiveFile(file.name, file.size, file.content as List<int>),
          );
        }
      }

      final fixedBytes = ZipEncoder().encode(rebuilt);
      if (fixedBytes == null) rethrow;
      return Excel.decodeBytes(Uint8List.fromList(fixedBytes));
    }
  }

  /// Đọc giá trị ô Excel thành chuỗi sạch
  static String readCell(Data? cell, {bool roundDouble = false}) {
    final v = cell?.value;
    if (v == null) return '';
    return switch (v) {
      TextCellValue() => v.value.toString().trim(),
      IntCellValue() => v.value.toString(),
      DoubleCellValue() =>
        roundDouble ? v.value.round().toString() : v.value.toString(),
      BoolCellValue() => v.value.toString(),
      _ => v.toString().trim(),
    };
  }

  /// Lưu và chia sẻ file Excel ra thư mục Downloads / Temporary
  static Future<String> saveAndShareExcel({
    required Excel excel,
    required String fileName,
    required String shareText,
  }) async {
    final bytes = excel.save();
    if (bytes == null) {
      throw Exception('Không thể khởi tạo dữ liệu file Excel');
    }

    final dir = await getDownloadsDirectory() ?? await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);

    try {
      await Share.shareXFiles([XFile(file.path)], text: shareText);
    } catch (_) {
      // Dự phòng trên Linux Desktop khi không có hộp thoại Share hệ thống
    }
    return file.path;
  }
}
