import 'dart:convert';

import 'package:shelf/shelf.dart';

Response jsonOk(Object? body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Future<Map<String, dynamic>> readJsonBody(Request req) async {
  final raw = await req.readAsString();
  if (raw.isEmpty) return const {};
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Expected JSON object');
  }
  return decoded;
}
