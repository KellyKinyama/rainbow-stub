/// Minimal JID (Jabber ID) — `<local>@<domain>[/<resource>]`.
class Jid {
  const Jid({required this.local, required this.domain, this.resource});

  final String local;
  final String domain;
  final String? resource;

  bool get isBare => resource == null;

  Jid get bare => Jid(local: local, domain: domain);

  static Jid parse(String s) {
    var rest = s;
    String? resource;
    final slash = rest.indexOf('/');
    if (slash >= 0) {
      resource = rest.substring(slash + 1);
      rest = rest.substring(0, slash);
    }
    final at = rest.indexOf('@');
    if (at < 0) {
      // Bare-domain JID.
      return Jid(local: '', domain: rest, resource: resource);
    }
    return Jid(
      local: rest.substring(0, at).toLowerCase(),
      domain: rest.substring(at + 1).toLowerCase(),
      resource: resource,
    );
  }

  @override
  String toString() {
    final base = local.isEmpty ? domain : '$local@$domain';
    return resource == null ? base : '$base/$resource';
  }

  @override
  bool operator ==(Object other) =>
      other is Jid &&
      other.local == local &&
      other.domain == domain &&
      other.resource == resource;

  @override
  int get hashCode => Object.hash(local, domain, resource);
}
