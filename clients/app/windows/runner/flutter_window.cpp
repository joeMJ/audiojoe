#include "flutter_window.h"

#include <dwmapi.h>
#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "io.github.joemj.audiojoe/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto* dark = std::get_if<bool>(call.arguments());
        if (call.method_name() != "dark" || dark == nullptr) {
          result->NotImplemented();
          return;
        }
        dark_ = *dark;
        ApplyDark();
        result->Success();
      });
  storage_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "io.github.joemj.audiojoe/storage",
          &flutter::StandardMethodCodec::GetInstance());
  storage_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const auto* path = std::get_if<std::string>(call.arguments());
        if (call.method_name() != "free" || path == nullptr) {
          result->NotImplemented();
          return;
        }
        int n = MultiByteToWideChar(CP_UTF8, 0, path->c_str(), -1, nullptr, 0);
        std::wstring wide(n > 0 ? n : 1, L'\0');
        MultiByteToWideChar(CP_UTF8, 0, path->c_str(), -1, wide.data(), n);
        // Free bytes available to this user (quotas included), no elevation needed.
        ULARGE_INTEGER available;
        if (!GetDiskFreeSpaceExW(wide.c_str(), &available, nullptr, nullptr)) {
          result->Error("GetDiskFreeSpaceExW", std::to_string(GetLastError()));
          return;
        }
        result->Success(flutter::EncodableValue(
            static_cast<int64_t>(available.QuadPart)));
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::ApplyDark() {
  if (!dark_) return;
  BOOL value = *dark_ ? TRUE : FALSE;
  DwmSetWindowAttribute(GetHandle(), DWMWA_USE_IMMERSIVE_DARK_MODE, &value,
                        sizeof(value));
}

void FlutterWindow::OnDestroy() {
  window_channel_ = nullptr;
  storage_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Smallest window: 720 × 540 of content, below that the desktop layout has no room. Handled
  // before the plugins: window_manager 0.5.2 answers WM_GETMINMAXINFO itself and returns, so the
  // limit in Win32Window never came into effect (0.1.7, Windows VM / user 2026-11-04). With the
  // hidden title bar the client area is the window minus invisible borders; they are taken from
  // the window as it is, since window_manager sets them (8 px left, right, bottom; 1 px top on
  // Windows 10).
  // 0.2.0: Windows asks for the limit while a maximised window is being restored; the borders
  // measured then are those of the maximised window (16 px high instead of 9), so the restored
  // window came back 8 px higher than before (VM 2026-11-04: 736 × 556, client 548). Maximised or
  // minimised, the borders last measured in the normal state count.
  if (message == WM_GETMINMAXINFO) {
    static LONG dx = 16, dy = 9;
    UINT dpi = FlutterDesktopGetDpiForMonitor(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST));
    double scale = dpi / 96.0;
    RECT window, client;
    if (!IsIconic(hwnd) && !IsZoomed(hwnd) && GetWindowRect(hwnd, &window) && GetClientRect(hwnd, &client) &&
        client.right > 0 && client.bottom > 0) {
      dx = (window.right - window.left) - client.right;
      dy = (window.bottom - window.top) - client.bottom;
    }
    auto info = reinterpret_cast<MINMAXINFO*>(lparam);
    info->ptMinTrackSize.x = static_cast<LONG>(720 * scale) + dx;
    info->ptMinTrackSize.y = static_cast<LONG>(540 * scale) + dy;
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_DWMCOLORIZATIONCOLORCHANGED: {
      // The base class sets the system's choice; the app's choice wins.
      LRESULT r = Win32Window::MessageHandler(hwnd, message, wparam, lparam);
      ApplyDark();
      return r;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
