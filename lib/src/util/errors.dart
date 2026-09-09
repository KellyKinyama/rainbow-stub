import 'dart:convert';

import 'package:shelf/shelf.dart';

/// Rainbow's REST envelope for errors:
/// `{ "status": <int>, "errorCode": <int>, "errorMsg": <str>, "errorDetails": <str>, "errorDetailsCode": <int> }`
class RainbowError implements Exception {
  RainbowError({
    required this.httpStatus,
    required this.errorCode,
    required this.errorMsg,
    this.errorDetails,
    this.errorDetailsCode,
  });

  final int httpStatus;
  final int errorCode;
  final String errorMsg;
  final String? errorDetails;
  final int? errorDetailsCode;

  factory RainbowError.unauthorized([String msg = 'Bad credentials']) =>
      RainbowError(
        httpStatus: 401,
        errorCode: 401,
        errorMsg: msg,
        errorDetailsCode: 40140,
      );

  factory RainbowError.forbidden([String msg = 'Forbidden']) =>
      RainbowError(httpStatus: 403, errorCode: 403, errorMsg: msg);

  factory RainbowError.badRequest(String msg, {int code = 400}) =>
      RainbowError(httpStatus: 400, errorCode: code, errorMsg: msg);

  factory RainbowError.notFound([String msg = 'Not found']) =>
      RainbowError(httpStatus: 404, errorCode: 404, errorMsg: msg);

  factory RainbowError.conflict(String msg, {int code = 409}) =>
      RainbowError(httpStatus: 409, errorCode: code, errorMsg: msg);

  Response toResponse() => Response(
    httpStatus,
    body: jsonEncode({
      'status': httpStatus,
      'errorCode': errorCode,
      'errorMsg': errorMsg,
      if (errorDetails != null) 'errorDetails': errorDetails,
      if (errorDetailsCode != null) 'errorDetailsCode': errorDetailsCode,
    }),
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}
