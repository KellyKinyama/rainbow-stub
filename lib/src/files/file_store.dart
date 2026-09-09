import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../db/database.dart';
import '../util/ids.dart';

class FileDescriptor {
  FileDescriptor({
    required this.id,
    required this.ownerId,
    required this.peerJid,
    required this.peerType,
    required this.fileName,
    required this.mimeType,
    required this.byteSize,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String ownerId;
  final String peerJid;
  final String peerType;
  final String fileName;
  final String mimeType;
  final int byteSize;
  final String state;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toRainbowJson({String? downloadUrl}) => {
    'id': id,
    'fileName': fileName,
    'mime': mimeType,
    'size': byteSize,
    'ownerId': ownerId,
    'peer': peerJid,
    'peerType': peerType,
    'state': state,
    'creationDate': createdAt.toUtc().toIso8601String(),
    'lastUpdateDate': updatedAt.toUtc().toIso8601String(),
    if (downloadUrl != null) 'downloadUrl': downloadUrl,
  };
}

class FileStore {
  FileStore({
    required this.rootDir,
    required AppDatabase db,
    required ObjectIdGen ids,
  }) : _db = db,
       _ids = ids {
    Directory(rootDir).createSync(recursive: true);
  }

  final String rootDir;
  final AppDatabase _db;
  final ObjectIdGen _ids;

  String _path(String fileId) => '$rootDir${Platform.pathSeparator}$fileId';

  FileDescriptor create({
    required String ownerId,
    required String peerJid,
    required String peerType,
    required String fileName,
    required String mimeType,
    int byteSize = 0,
  }) {
    final id = _ids.next();
    final now = DateTime.now().toUtc();
    _db.db.execute(
      '''
      INSERT INTO file_descriptors
        (id, owner_id, peer_jid, peer_type, file_name, mime_type,
         byte_size, state, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)
      ''',
      [
        id,
        ownerId,
        peerJid,
        peerType,
        fileName,
        mimeType,
        byteSize,
        now.toIso8601String(),
        now.toIso8601String(),
      ],
    );
    return findById(id)!;
  }

  FileDescriptor? findById(String id) {
    final rs = _db.db.select('SELECT * FROM file_descriptors WHERE id = ?', [
      id,
    ]);
    if (rs.isEmpty) return null;
    return _row(rs.first);
  }

  List<FileDescriptor> listForPeer(String peerJid) {
    final rs = _db.db.select(
      '''
      SELECT * FROM file_descriptors
      WHERE peer_jid = ? AND state != 'deleted'
      ORDER BY created_at DESC
      ''',
      [peerJid],
    );
    return rs.map(_row).toList();
  }

  Future<void> writeBytes(String id, Uint8List bytes, String? mimeType) async {
    await File(_path(id)).writeAsBytes(bytes, flush: true);
    _db.db.execute(
      '''
      UPDATE file_descriptors SET
        byte_size  = ?,
        mime_type  = COALESCE(?, mime_type),
        state      = 'uploaded',
        updated_at = ?
      WHERE id = ?
      ''',
      [bytes.length, mimeType, DateTime.now().toUtc().toIso8601String(), id],
    );
  }

  Future<Uint8List?> readBytes(String id) async {
    final f = File(_path(id));
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }

  Future<void> delete(String id) async {
    _db.db.execute(
      "UPDATE file_descriptors SET state = 'deleted', updated_at = ? WHERE id = ?",
      [DateTime.now().toUtc().toIso8601String(), id],
    );
    final f = File(_path(id));
    if (await f.exists()) await f.delete();
  }

  FileDescriptor _row(Map<String, Object?> r) => FileDescriptor(
    id: r['id'] as String,
    ownerId: r['owner_id'] as String,
    peerJid: r['peer_jid'] as String,
    peerType: r['peer_type'] as String,
    fileName: r['file_name'] as String,
    mimeType: r['mime_type'] as String,
    byteSize: r['byte_size'] as int,
    state: r['state'] as String,
    createdAt: DateTime.parse(r['created_at'] as String),
    updatedAt: DateTime.parse(r['updated_at'] as String),
  );
}
