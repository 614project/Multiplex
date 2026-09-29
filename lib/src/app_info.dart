/// Version stamped into release builds with `--dart-define=MULTIPLEX_VERSION=<version>`.
const String appVersion = String.fromEnvironment('MULTIPLEX_VERSION', defaultValue: 'dev');
