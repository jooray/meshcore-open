import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

/// A P-256 client identity: raw X||Y public key (64 bytes) plus a DER ECDSA
/// signature over a server nonce.
class LocalApiCrypto {
  static final ECCurve_secp256r1 _curve = ECCurve_secp256r1();

  static String newNonce() {
    final random = Random.secure();
    final bytes = Uint8List.fromList(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    return base64UrlEncode(bytes);
  }

  static String fingerprint(Uint8List publicKeyRaw) {
    final digest = SHA256Digest().process(publicKeyRaw);
    final short = digest.sublist(0, 8);
    final hex = short
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return '${hex.substring(0, 4)} ${hex.substring(4, 8)} '
        '${hex.substring(8, 12)} ${hex.substring(12, 16)}';
  }

  static Uint8List? decodePublicKey(String base64Value) {
    try {
      final raw = base64Decode(base64Value);
      if (raw.length != 64) return null;
      final x = _unsigned(raw.sublist(0, 32));
      final y = _unsigned(raw.sublist(32, 64));
      final point = _curve.curve.createPoint(x, y);
      if (point.isInfinity) return null;
      return raw;
    } catch (_) {
      return null;
    }
  }

  /// DER-encoded `SHA256withECDSA` over [message].
  static bool verify(
    Uint8List publicKeyRaw,
    String message,
    String signatureBase64,
  ) {
    try {
      final x = _unsigned(publicKeyRaw.sublist(0, 32));
      final y = _unsigned(publicKeyRaw.sublist(32, 64));
      final curve = _curve.curve;
      final point = curve.createPoint(x, y);
      if (point.isInfinity) return false;

      final signature = _parseSignature(base64Decode(signatureBase64));
      if (signature == null) return false;

      final signer = ECDSASigner(SHA256Digest());
      signer.init(
        false,
        PublicKeyParameter<ECPublicKey>(ECPublicKey(point, _curve)),
      );
      return signer.verifySignature(
        Uint8List.fromList(utf8.encode(message)),
        signature,
      );
    } catch (_) {
      return false;
    }
  }

  /// Accepts DER (`SHA256withECDSA` as produced by Java/Kotlin) and the raw
  /// 64-byte `r||s` form used by simple clients and tests.
  static ECSignature? _parseSignature(Uint8List bytes) {
    if (bytes.length == 64) {
      final r = _unsigned(bytes.sublist(0, 32));
      final s = _unsigned(bytes.sublist(32, 64));
      return ECSignature(r, s);
    }
    return _parseDerSignature(bytes);
  }

  static ECSignature? _parseDerSignature(Uint8List der) {
    try {
      final parser = ASN1Parser(der);
      final sequence = parser.nextObject() as ASN1Sequence;
      if (sequence.elements == null || sequence.elements!.length != 2) {
        return null;
      }
      final r = (sequence.elements![0] as ASN1Integer).integer;
      final s = (sequence.elements![1] as ASN1Integer).integer;
      if (r == null || s == null) return null;
      return ECSignature(r, s);
    } catch (_) {
      return null;
    }
  }

  static BigInt _unsigned(Uint8List bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }
}
