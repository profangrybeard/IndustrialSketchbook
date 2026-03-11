import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'auth_service.dart';

/// Thin wrapper around Google Drive v3 REST API for appDataFolder (Phase 3.2).
///
/// All files live in the hidden app-private folder (drive.appdata scope).
/// Uses raw HTTP instead of the heavyweight googleapis package — we only
/// need upload, download, list, update, and delete.
class DriveService {
  DriveService(this._authService);
  final AuthService _authService;

  static const _uploadUrl = 'https://www.googleapis.com/upload/drive/v3/files';
  static const _filesUrl = 'https://www.googleapis.com/drive/v3/files';

  /// Get auth headers or throw if not signed in.
  Future<Map<String, String>> _headers() async {
    final headers = await _authService.authHeaders;
    if (headers == null) {
      throw StateError('Not signed in — cannot access Google Drive');
    }
    return headers;
  }

  /// Upload a JSON file to appDataFolder (multipart upload).
  ///
  /// Returns the Drive file ID of the newly created file.
  Future<String> uploadJson(
      String filename, Map<String, dynamic> content) async {
    final headers = await _headers();
    final boundary =
        'sync_boundary_${DateTime.now().millisecondsSinceEpoch}';
    final metadata = jsonEncode({
      'name': filename,
      'parents': ['appDataFolder'],
    });
    final body = jsonEncode(content);

    final multipart = [
      '--$boundary',
      'Content-Type: application/json; charset=UTF-8',
      '',
      metadata,
      '--$boundary',
      'Content-Type: application/json',
      '',
      body,
      '--$boundary--',
    ].join('\r\n');

    final response = await http.post(
      Uri.parse('$_uploadUrl?uploadType=multipart'),
      headers: {
        ...headers,
        'Content-Type': 'multipart/related; boundary=$boundary',
      },
      body: multipart,
    );

    if (response.statusCode != 200) {
      throw DriveException('Upload failed (${response.statusCode})',
          response.body);
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return json['id'] as String;
  }

  /// Update an existing file's content (media-only upload).
  Future<void> updateJson(
      String fileId, Map<String, dynamic> content) async {
    final headers = await _headers();
    final body = jsonEncode(content);

    final response = await http.patch(
      Uri.parse('$_uploadUrl/$fileId?uploadType=media'),
      headers: {
        ...headers,
        'Content-Type': 'application/json',
      },
      body: body,
    );

    if (response.statusCode != 200) {
      throw DriveException('Update failed (${response.statusCode})',
          response.body);
    }
  }

  /// List files in appDataFolder.
  ///
  /// Optionally filter by name containing [nameContains].
  /// Returns all matching [DriveFile] entries.
  Future<List<DriveFile>> listFiles({String? nameContains}) async {
    final headers = await _headers();
    final params = <String, String>{
      'spaces': 'appDataFolder',
      'fields': 'files(id,name,createdTime,modifiedTime)',
      'pageSize': '1000',
    };
    if (nameContains != null) {
      params['q'] = "name contains '$nameContains' and trashed = false";
    } else {
      params['q'] = 'trashed = false';
    }

    final uri = Uri.parse(_filesUrl).replace(queryParameters: params);
    final response = await http.get(uri, headers: headers);

    if (response.statusCode != 200) {
      throw DriveException('List failed (${response.statusCode})',
          response.body);
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final files = json['files'] as List? ?? [];
    return files
        .map((f) => DriveFile.fromJson(f as Map<String, dynamic>))
        .toList();
  }

  /// Download a file's content as parsed JSON.
  Future<Map<String, dynamic>> downloadJson(String fileId) async {
    final headers = await _headers();
    final response = await http.get(
      Uri.parse('$_filesUrl/$fileId?alt=media'),
      headers: headers,
    );

    if (response.statusCode != 200) {
      throw DriveException('Download failed (${response.statusCode})',
          response.body);
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Upload a gzip-compressed JSON file to appDataFolder (Phase 4).
  ///
  /// Compresses [content] with gzip before uploading. The filename should
  /// end with `.json.gz` so the pull path knows to decompress.
  Future<String> uploadGzip(
      String filename, Map<String, dynamic> content) async {
    final headers = await _headers();
    final boundary =
        'sync_boundary_${DateTime.now().millisecondsSinceEpoch}';
    final metadata = jsonEncode({
      'name': filename,
      'parents': ['appDataFolder'],
    });
    final jsonBytes = utf8.encode(jsonEncode(content));
    final compressed = gzip.encode(jsonBytes);

    // Build multipart: metadata (JSON) + body (binary gzip)
    final metadataPart = [
      '--$boundary',
      'Content-Type: application/json; charset=UTF-8',
      '',
      metadata,
      '--$boundary',
      'Content-Type: application/gzip',
      'Content-Transfer-Encoding: binary',
      '',
    ].join('\r\n');
    final trailer = '\r\n--$boundary--';

    // Assemble as raw bytes to handle binary gzip payload
    final body = <int>[
      ...utf8.encode(metadataPart),
      ...utf8.encode('\r\n'),
      ...compressed,
      ...utf8.encode(trailer),
    ];

    final response = await http.post(
      Uri.parse('$_uploadUrl?uploadType=multipart'),
      headers: {
        ...headers,
        'Content-Type': 'multipart/related; boundary=$boundary',
        'Content-Length': body.length.toString(),
      },
      body: body,
    );

    if (response.statusCode != 200) {
      throw DriveException('Upload gzip failed (${response.statusCode})',
          response.body);
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return json['id'] as String;
  }

  /// Download and decompress a gzip-compressed JSON file.
  Future<Map<String, dynamic>> downloadGzip(String fileId) async {
    final headers = await _headers();
    final response = await http.get(
      Uri.parse('$_filesUrl/$fileId?alt=media'),
      headers: headers,
    );

    if (response.statusCode != 200) {
      throw DriveException(
          'Download gzip failed (${response.statusCode})',
          response.body);
    }

    final decompressed = gzip.decode(response.bodyBytes);
    final jsonStr = utf8.decode(decompressed);
    return jsonDecode(jsonStr) as Map<String, dynamic>;
  }

  /// Delete a file by ID.
  Future<void> deleteFile(String fileId) async {
    final headers = await _headers();
    final response = await http.delete(
      Uri.parse('$_filesUrl/$fileId'),
      headers: headers,
    );

    // 204 No Content is the expected success response
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw DriveException('Delete failed (${response.statusCode})',
          response.body);
    }
  }
}

/// Metadata for a file in Google Drive appDataFolder.
class DriveFile {
  const DriveFile({
    required this.id,
    required this.name,
    required this.createdTime,
    required this.modifiedTime,
  });

  final String id;
  final String name;
  final DateTime createdTime;
  final DateTime modifiedTime;

  factory DriveFile.fromJson(Map<String, dynamic> json) => DriveFile(
        id: json['id'] as String,
        name: json['name'] as String,
        createdTime: DateTime.parse(json['createdTime'] as String),
        modifiedTime: DateTime.parse(json['modifiedTime'] as String),
      );
}

/// Exception thrown when a Google Drive API call fails.
class DriveException implements Exception {
  const DriveException(this.message, [this.responseBody]);
  final String message;
  final String? responseBody;

  @override
  String toString() => 'DriveException: $message';
}
