/// NAS sync configuration.
///
/// For now these are compile-time constants. Once the full sync screen lands
/// the URL becomes user-overridable in SharedPreferences with these as the
/// fallback defaults.
class NasConfig {
  /// Tailscale MagicDNS hostname for Tobias's Ugreen DXP4800. Reachable from
  /// anywhere on the tailnet — does NOT need to be on home WiFi.
  static const String defaultBaseUrl =
      'http://dxp4800-tobias.tailc7581b.ts.net:8090';
}
