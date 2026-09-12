import 'package:sip_core/sip_core.dart';

import '../xmpp/jid.dart';

/// JID ↔ SIP URI helpers for the gateway.
///
/// A JID `<local>@<sipDomain>` maps to `sip:<local>@<sipDomain>` (and back).
/// The gateway routes by *domain* — no translation of the local part beyond
/// what the caller supplies. Production may plug in E.164 normalisation via
/// [normalizeLocal].
class SipJid {
  const SipJid._();

  /// Build a `sip:` URI from a JID by copying local part and domain
  /// verbatim.
  static SipUri toSipUri(Jid jid) {
    final local = jid.local.isEmpty ? null : jid.local;
    return SipUri(scheme: 'sip', user: local, host: jid.domain);
  }

  /// Build a JID from a SIP URI by copying user and host.
  static Jid fromSipUri(SipUri uri) {
    return Jid(local: uri.user ?? '', domain: uri.host);
  }

  /// Serialize a [SipUri] to its canonical wire form for embedding in an
  /// XMPP-facing string (angle brackets not included).
  static String uriToString(SipUri uri) {
    final buf = StringBuffer('${uri.scheme}:');
    if (uri.user != null && uri.user!.isNotEmpty) {
      buf.write('${uri.user}@');
    }
    buf.write(uri.host);
    if (uri.port != null) buf.write(':${uri.port}');
    return buf.toString();
  }

  /// Wrap [uri] in a `<sip:foo@bar>` `NameAddr` (angle-bracket form) suitable
  /// for `From`/`To`/`Contact`.
  static NameAddr toNameAddr(SipUri uri) => NameAddr(
        uri: uri,
        hasAngleBrackets: true,
      );

  /// `<local>` from a SIP URI is used verbatim as the user id in
  /// pseudo-user paths. Callers that need E.164 normalisation must apply
  /// their own transform here.
  static String normalizeLocal(String s) => s.trim();
}
