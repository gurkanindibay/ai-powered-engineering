/// Unified application error hierarchy for SitePulse.
sealed class AppException implements Exception {
  final String message;
  final String? code;
  final String? traceId;

  const AppException(this.message, {this.code, this.traceId});

  @override
  String toString() => message;
}

/// Server returned a non-2xx status code with a standardized JSON error envelope.
class ApiException extends AppException {
  final int statusCode;
  final Map<String, dynamic>? details;

  const ApiException({
    required String message,
    required this.statusCode,
    String? code,
    String? traceId,
    this.details,
  }) : super(message, code: code, traceId: traceId);

  bool get isNotFound => statusCode == 404;
  bool get isConflict => statusCode == 409;
  bool get isValidation => statusCode == 400 || statusCode == 422;
  bool get isPermissionDenied => statusCode == 403;
  bool get isUnauthorized => statusCode == 401;
  bool get isRateLimited => statusCode == 429;
  bool get isServerError => statusCode >= 500 && statusCode < 600;

  /// Retrieves field-specific error messages if returned by the backend.
  List<String> fieldErrors(String field) {
    if (details == null) return const [];
    final fe = details!['field_errors'];
    if (fe is! List) return const [];
    return fe
        .whereType<Map<String, dynamic>>()
        .where((e) => e['field'] == field)
        .map((e) => e['message']?.toString() ?? '')
        .where((m) => m.isNotEmpty)
        .toList();
  }
}

/// Network connectivity, socket, or offline errors.
class NetworkException extends AppException {
  const NetworkException([super.message = 'İnternet bağlantısı kurulamadı.'])
    : super(code: 'NETWORK_ERROR');
}

/// Request timed out before completion.
class RequestTimeoutException extends AppException {
  const RequestTimeoutException([
    super.message = 'İstek zaman aşımına uğradı.',
  ]) : super(code: 'TIMEOUT');
}

/// Authentication required or session expired.
class AuthException extends AppException {
  const AuthException([
    super.message = 'Oturum süresi doldu. Lütfen tekrar giriş yapın.',
  ]) : super(code: 'AUTHENTICATION_REQUIRED');
}

/// Client-side input or validation failure before network dispatch.
class ValidationException extends AppException {
  final Map<String, String> fieldErrors;

  const ValidationException(super.message, {this.fieldErrors = const {}})
    : super(code: 'CLIENT_VALIDATION_ERROR');
}
