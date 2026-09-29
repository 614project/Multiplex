import 'dart:convert';

abstract final class UrlCredentials {
  /// Removes `user:password@` from an absolute URL while keeping the rest of the text untouched,
  /// so exported project files never carry API credentials.
  static String remove(String? url) {
    if (url == null || url.trim().isEmpty) {
      return '';
    }

    final trimmed = url.trim();
    final schemeSeparatorIndex = trimmed.indexOf('://');
    if (schemeSeparatorIndex <= 0) {
      return trimmed;
    }

    final authorityStart = schemeSeparatorIndex + 3;
    var authorityEnd = trimmed.length;
    for (var index = authorityStart; index < trimmed.length; index++) {
      final character = trimmed[index];
      if (character == '/' || character == '?' || character == '#') {
        authorityEnd = index;
        break;
      }
    }

    final userInfoEnd = trimmed.substring(authorityStart, authorityEnd).lastIndexOf('@');
    if (userInfoEnd < 0) {
      return trimmed;
    }

    return trimmed.substring(0, authorityStart) + trimmed.substring(authorityStart + userInfoEnd + 1);
  }
}

/// A request target resolved from a user supplied base URL.
class ResolvedEndpoint {
  const ResolvedEndpoint(this.uri, this.basicAuthorization);

  final Uri uri;

  /// Value for the `Authorization` header when the base URL carried `user:password@`.
  final String? basicAuthorization;
}

abstract final class EndpointResolver {
  static const _strippedSuffixes = ['/docs', '/sdapi/v1', '/agent-scheduler/v1'];

  /// Combines [baseUrl] with an API [path] (which may contain a query string).
  ///
  /// Credentials in the base URL become a Basic authorization header, and pasted documentation or
  /// API roots such as `/docs` or `/sdapi/v1` are trimmed so both `http://host:7860` and
  /// `http://host:7860/sdapi/v1` work.
  static ResolvedEndpoint resolve(String baseUrl, String path) {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Base URL is required.');
    }

    final base = Uri.tryParse(trimmed);
    if (base == null || !base.hasScheme || base.host.isEmpty) {
      throw ArgumentError('Base URL must be an absolute URL such as http://127.0.0.1:7860.');
    }

    String? authorization;
    if (base.userInfo.isNotEmpty) {
      final separator = base.userInfo.indexOf(':');
      final user = separator < 0 ? base.userInfo : base.userInfo.substring(0, separator);
      final password = separator < 0 ? '' : base.userInfo.substring(separator + 1);
      final credentials = '${Uri.decodeComponent(user)}:${Uri.decodeComponent(password)}';
      authorization = 'Basic ${base64.encode(utf8.encode(credentials))}';
    }

    var basePath = base.path;
    while (basePath.endsWith('/')) {
      basePath = basePath.substring(0, basePath.length - 1);
    }

    for (final suffix in _strippedSuffixes) {
      if (basePath.toLowerCase().endsWith(suffix)) {
        basePath = basePath.substring(0, basePath.length - suffix.length);
      }
    }

    final queryIndex = path.indexOf('?');
    var requestPath = queryIndex < 0 ? path : path.substring(0, queryIndex);
    final query = queryIndex < 0 || queryIndex == path.length - 1 ? null : path.substring(queryIndex + 1);
    while (requestPath.startsWith('/')) {
      requestPath = requestPath.substring(1);
    }

    final combinedPath = basePath.isEmpty
        ? '/$requestPath'
        : requestPath.isEmpty
            ? basePath
            : '$basePath/$requestPath';

    final uri = Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: combinedPath,
      query: query,
    );
    return ResolvedEndpoint(uri, authorization);
  }

  /// A short `host:port` label for status chips.
  static String describe(String baseUrl) {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || uri.host.isEmpty) {
      return baseUrl.trim();
    }

    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }
}
