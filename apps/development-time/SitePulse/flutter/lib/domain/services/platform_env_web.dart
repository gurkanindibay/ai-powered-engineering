import 'dart:async';
// ignore: deprecated_member_use
import 'dart:html' as html;

const _prefix = 'sitepulse.';

/// Reads a preference from the browser's localStorage.
String? readPreference(String key) {
  try {
    return html.window.localStorage['$_prefix$key'];
  } catch (_) {
    return null; // storage blocked (private mode, sandboxed frame)
  }
}

/// Saves a preference to the browser's localStorage; null removes it.
void writePreference(String key, String? value) {
  try {
    if (value == null) {
      html.window.localStorage.remove('$_prefix$key');
    } else {
      html.window.localStorage['$_prefix$key'] = value;
    }
  } catch (_) {
    // Storage blocked: the choice simply lasts for this session.
  }
}

/// Whether the browser reports no network.
bool isPlatformOffline() => !(html.window.navigator.onLine ?? true);

/// Emits true when the browser goes offline and false when it comes back.
Stream<bool> platformOfflineChanges() {
  final controller = StreamController<bool>.broadcast();
  html.window.onOffline.listen((_) => controller.add(true));
  html.window.onOnline.listen((_) => controller.add(false));
  return controller.stream;
}

/// Saves bytes as a file through the browser's download. Returns false if blocked.
bool downloadBytes(String filename, List<int> bytes, String mimeType) {
  try {
    final blob = html.Blob([bytes], mimeType);
    final url = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.AnchorElement(href: url)
      ..download = filename
      ..style.display = 'none';
    html.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    html.Url.revokeObjectUrl(url);
    return true;
  } catch (_) {
    return false;
  }
}

/// Opens a URL (e.g. a payment provider's hosted page) in a new browser tab.
bool openUrlInNewTab(String url) {
  try {
    html.window.open(url, '_blank');
    return true;
  } catch (_) {
    return false;
  }
}
