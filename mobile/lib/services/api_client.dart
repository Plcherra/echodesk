import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';

/// HTTP client for Echodesk backend API. Attaches Bearer token from Supabase session.
/// Refreshes token if expired. On 401, signs out and invokes onUnauthorized.
class ApiClient {
  static String get _baseUrl =>
      Env.apiBaseUrl.replaceAll(RegExp(r'/$'), '');

  /// Callback when a 401 Unauthorized is received on an authenticated request.
  /// Set by the app to sign out and navigate to login.
  static void Function()? onUnauthorized;

  /// Get access token from current session. Refreshes token if expired.
  /// Uses currentSession + refreshSession() for reliable token (handles expiry).
  static Future<String?> _getAccessToken() async {
    try {
      var session = Supabase.instance.client.auth.currentSession;
      if (session == null) return null;
      if (session.isExpired) {
        final resp = await Supabase.instance.client.auth.refreshSession();
        session = resp.session;
      }
      return session?.accessToken;
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('[ApiClient] _getAccessToken failed: $e');
      }
      return null;
    }
  }

  static void _debugLog(String path, String message) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('[ApiClient] $path: $message');
    }
  }

  static Future<Map<String, String>> _headers({bool withAuth = true}) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (withAuth) {
      final token = await _getAccessToken();
      if (token != null) {
        headers['Authorization'] = 'Bearer $token';
        if (kDebugMode) {
          _debugLog('_headers', 'Authorization header attached (token length: ${token.length})');
        }
      } else {
        if (kDebugMode) {
          _debugLog('_headers', 'No access token available - session may be null or expired');
        }
      }
    }
    return headers;
  }

  static Future<bool> _handleUnauthorized(http.Response response, String path, bool withAuth) async {
    if (response.statusCode == 401 && withAuth) {
      if (kDebugMode) {
        _debugLog(path, '401 Unauthorized - signing out and routing to login');
      }
      try {
        await Supabase.instance.client.auth.signOut();
      } catch (_) {}
      onUnauthorized?.call();
      return true;
    }
    return false;
  }

  static Future<http.Response> get(
    String path, {
    Map<String, String>? queryParams,
    bool withAuth = true,
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final uriWithParams = queryParams != null && queryParams.isNotEmpty
        ? uri.replace(queryParameters: queryParams)
        : uri;
    final headers = await _headers(withAuth: withAuth);
    if (kDebugMode) {
      final hasSession = Supabase.instance.client.auth.currentSession != null;
      final hasToken = headers.containsKey('Authorization');
      _debugLog(path, 'session=$hasSession token=$hasToken');
    }
    final response = await http.get(uriWithParams, headers: headers);
    if (kDebugMode) {
      _debugLog(path, 'GET status=${response.statusCode}');
    }
    if (await _handleUnauthorized(response, path, withAuth)) {
      return response;
    }
    return response;
  }

  static Future<http.Response> post(
    String path, {
    Object? body,
    bool withAuth = true,
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final headers = await _headers(withAuth: withAuth);
    if (kDebugMode) {
      final hasSession = Supabase.instance.client.auth.currentSession != null;
      final hasToken = headers.containsKey('Authorization');
      _debugLog(path, 'session=$hasSession token=$hasToken');
    }
    final response = await http.post(
      uri,
      headers: headers,
      body: body != null ? jsonEncode(body) : null,
    );
    if (kDebugMode) {
      _debugLog(path, 'POST status=${response.statusCode}');
    }
    if (await _handleUnauthorized(response, path, withAuth)) {
      return response;
    }
    return response;
  }

  static Future<http.Response> postMultipart(
    String path, {
    required Map<String, String> fields,
    required List<http.MultipartFile> files,
    bool withAuth = true,
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final request = http.MultipartRequest('POST', uri);
    if (withAuth) {
      final token = await _getAccessToken();
      if (token != null) {
        request.headers['Authorization'] = 'Bearer $token';
      }
    }
    request.headers['Accept'] = 'application/json';
    request.fields.addAll(fields);
    request.files.addAll(files);
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    if (await _handleUnauthorized(response, path, withAuth)) {
      return response;
    }
    return response;
  }

  static Future<http.Response> delete(
    String path, {
    bool withAuth = true,
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final headers = await _headers(withAuth: withAuth);
    final response = await http.delete(uri, headers: headers);
    if (await _handleUnauthorized(response, path, withAuth)) {
      return response;
    }
    return response;
  }

  static Future<http.Response> patch(
    String path, {
    Object? body,
    bool withAuth = true,
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final headers = await _headers(withAuth: withAuth);
    if (kDebugMode) {
      final hasSession = Supabase.instance.client.auth.currentSession != null;
      final hasToken = headers.containsKey('Authorization');
      _debugLog(path, 'session=$hasSession token=$hasToken');
    }
    final response = await http.patch(
      uri,
      headers: headers,
      body: body != null ? jsonEncode(body) : null,
    );
    if (kDebugMode) {
      _debugLog(path, 'PATCH status=${response.statusCode}');
    }
    if (await _handleUnauthorized(response, path, withAuth)) {
      return response;
    }
    return response;
  }
}
