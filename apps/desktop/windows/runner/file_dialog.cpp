#include "file_dialog.h"

#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shlobj.h>
#include <wrl/client.h>

#include <atomic>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "win32_window.h"

namespace file_dialog {
namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using MethodChannel = flutter::MethodChannel<flutter::EncodableValue>;
using MethodResult = flutter::MethodResult<flutter::EncodableValue>;
using Microsoft::WRL::ComPtr;

constexpr char kChannelName[] = "bhe/native_file_dialog";

// The bounded-cancel timer matches the Dart-side escape hatch in
// ThreadedFileSelectorWindows: after this delay the timer fires inside the
// dialog's own message pump, cancels the modal dialog with IDCANCEL, and
// re-enables the main window.
constexpr UINT_PTR kCancelTimerId = 0x4248;
constexpr DWORD kDialogWatchdogMs = 90 * 1000;
// Platform-thread watchdog: fires slightly after the in-pump cancel timer so
// the main window is re-enabled even when the picker thread never pumps.
constexpr DWORD kRestoreWatchdogMs = 90 * 1000 + 500;

// Single-dialog policy: at most one native picker at a time, owned by the
// main window. If the shell stalls before the dialog window is even created,
// the cancel timer cannot run and the slot intentionally stays taken until
// the app restarts; further requests fail fast with dialog_already_open
// instead of stacking threads and unowned windows.
std::mutex s_state_mutex;
bool s_session_active = false;
std::atomic<HWND> s_session_owner(nullptr);

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) return std::wstring();
  int size = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                 static_cast<int>(text.size()), nullptr, 0);
  if (size <= 0) return std::wstring();
  std::wstring wide(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      wide.data(), size);
  return wide;
}

// Per MSDN: the first call with cbMultiByte = 0 returns the byte count
// INCLUDING the terminator; the second call must receive that exact buffer
// size, otherwise the conversion fails with ERROR_INSUFFICIENT_BUFFER.
std::string WideToUtf8(const wchar_t* text) {
  if (!text || !*text) return std::string();
  int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr,
                                 nullptr);
  if (size <= 0) return std::string();
  std::string narrow(size, '\0');
  int written = WideCharToMultiByte(CP_UTF8, 0, text, -1, narrow.data(), size,
                                    nullptr, nullptr);
  if (written <= 0) return std::string();
  narrow.resize(written - 1);
  return narrow;
}

struct PickerArgs {
  bool save = false;
  bool pick_folder = false;
  bool multi_select = false;
  std::wstring initial_name;
  std::wstring ok_label;
  std::wstring initial_directory;
  std::wstring type_label;
  std::vector<std::wstring> extensions;
};

std::optional<std::wstring> FindString(const EncodableMap& map,
                                       const char* key) {
  auto it = map.find(EncodableValue(key));
  if (it == map.end()) return std::nullopt;
  if (const auto* value = std::get_if<std::string>(&it->second)) {
    return Utf8ToWide(*value);
  }
  return std::nullopt;
}

PickerArgs ParseArgs(const EncodableMap& map, const std::string& method) {
  PickerArgs args;
  args.save = method == "save";
  args.pick_folder = method == "directory";
  args.multi_select = method == "openFiles";
  if (auto value = FindString(map, "suggestedName")) {
    args.initial_name = *value;
  }
  if (auto value = FindString(map, "confirmLabel")) {
    args.ok_label = *value;
  }
  if (auto value = FindString(map, "initialDirectory")) {
    args.initial_directory = *value;
  }
  if (auto value = FindString(map, "typeLabel")) {
    args.type_label = *value;
  }
  auto it = map.find(EncodableValue("extensions"));
  if (it != map.end()) {
    if (const auto* list = std::get_if<EncodableList>(&it->second)) {
      for (const auto& item : *list) {
        if (const auto* extension = std::get_if<std::string>(&item)) {
          args.extensions.push_back(Utf8ToWide(*extension));
        }
      }
    }
  }
  return args;
}

void ApplyFileTypes(IFileDialog* dialog, const PickerArgs& args) {
  if (args.type_label.empty() || args.extensions.empty()) {
    return;
  }
  std::wstring pattern;
  for (size_t i = 0; i < args.extensions.size(); ++i) {
    if (i) pattern += L";";
    pattern += L"*." + args.extensions[i];
  }
  COMDLG_FILTERSPEC filters[1] = {{args.type_label.c_str(), pattern.c_str()}};
  dialog->SetFileTypes(1, filters);
  dialog->SetFileTypeIndex(1);
}

// Runs inside the dialog thread's own message pump after the bounded-cancel
// delay: cancels the modal dialog (IDCANCEL on its root window) so a stuck
// shell cannot hold the session open, and re-enables the main window in case
// the dialog's own restore has not happened yet. No window-class matching is
// involved; the timer only exists while this thread keeps pumping.
VOID CALLBACK CancelTimerProc(HWND, UINT, UINT_PTR timer_id, DWORD) {
  KillTimer(nullptr, timer_id);
  HWND active = GetActiveWindow();
  if (active) {
    HWND root = GetAncestor(active, GA_ROOT);
    if (root) {
      PostMessageW(root, WM_COMMAND, MAKEWPARAM(IDCANCEL, 0), 0);
    }
  }
  HWND owner = s_session_owner.load();
  if (owner && IsWindow(owner)) {
    EnableWindow(owner, TRUE);
  }
}

// Restore watchdog on the PLATFORM thread: independent of the picker
// thread's pump. Even if the picker thread wedges before its in-pump
// cancel timer, this fires (the platform thread keeps pumping messages)
// and re-enables the main window, so the Dart escape hatch always holds.
constexpr UINT_PTR kRestoreTimerId = 0x4249;

VOID CALLBACK RestoreTimerProc(HWND hwnd, UINT, UINT_PTR timer_id,
                               DWORD) {
  if (hwnd && IsWindow(hwnd)) {
    EnableWindow(hwnd, TRUE);
  }
  KillTimer(hwnd, timer_id);
}

std::wstring ModuleDirectory() {
  wchar_t path[MAX_PATH] = {};
  GetModuleFileNameW(nullptr, path, MAX_PATH);
  std::wstring dir(path);
  size_t slash = dir.find_last_of(L"\\/");
  return slash == std::wstring::npos ? std::wstring()
                                     : dir.substr(0, slash);
}

bool IsRemotePath(const std::wstring& path) {
  if (path.rfind(L"\\\\", 0) == 0) return true;  // UNC
  if (path.size() >= 2 && path[1] == L':') {
    wchar_t root[4] = {path[0], L':', L'\\', L'\0'};
    return GetDriveTypeW(root) == DRIVE_REMOTE;
  }
  return false;
}

// Runs on the dedicated STA thread; the caller has initialized COM for this
// thread. Throws on unexpected failures so the caller reports an error
// instead of mistaking them for a cancellation; returns an empty vector when
// the user cancels.
std::vector<std::string> ShowDialog(const PickerArgs& args, HWND owner) {
  ComPtr<IModalWindow> modal;
  ComPtr<IFileDialog> file_dialog;
  // Save flows need IFileSaveDialog so users can type brand-new names;
  // FOS_FILEMUSTEXIST would lock them to existing files.
  if (args.save) {
    ComPtr<IFileSaveDialog> save_dialog;
    HRESULT hr = CoCreateInstance(CLSID_FileSaveDialog, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&save_dialog));
    if (FAILED(hr)) throw std::runtime_error("CoCreateInstance failed");
    modal = save_dialog;
    file_dialog = save_dialog;
  } else {
    ComPtr<IFileOpenDialog> open_dialog;
    HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&open_dialog));
    if (FAILED(hr)) throw std::runtime_error("CoCreateInstance failed");
    modal = open_dialog;
    file_dialog = open_dialog;
  }
  DWORD options = 0;
  file_dialog->GetOptions(&options);
  options |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
  if (args.save) options |= FOS_OVERWRITEPROMPT;
  if (args.pick_folder) {
    options |= FOS_PICKFOLDERS;
  } else if (!args.save) {
    options |= FOS_FILEMUSTEXIST;
  }
  if (args.multi_select) options |= FOS_ALLOWMULTISELECT;
  file_dialog->SetOptions(options);
  ApplyFileTypes(file_dialog.Get(), args);
  if (args.save && !args.initial_name.empty()) {
    file_dialog->SetFileName(args.initial_name.c_str());
  }
  // Default the dialog to a local folder: automatic enumeration of a stale
  // mapped network drive is the main hang vector, so UNC or DRIVE_REMOTE
  // requests fall back to the (always local) application folder. Users can
  // still navigate to network locations manually.
  std::wstring folder = args.initial_directory;
  if (folder.empty() || IsRemotePath(folder)) {
    folder = ModuleDirectory();
  }
  if (!folder.empty() && !IsRemotePath(folder)) {
    ComPtr<IShellItem> folder_item;
    HRESULT hr = SHCreateItemFromParsingName(folder.c_str(), nullptr,
                                             IID_PPV_ARGS(&folder_item));
    if (SUCCEEDED(hr) && folder_item) {
      file_dialog->SetFolder(folder_item.Get());
    }
  }
  if (!args.ok_label.empty()) {
    file_dialog->SetOkButtonLabel(args.ok_label.c_str());
  }
  // Owned by the main window: IFileDialog disables it for the whole modal
  // phase and restores it afterwards, on every path including cancellation.
  // The bounded-cancel timer above re-enables the window even if this call
  // never returns.
  HRESULT hr = modal->Show(owner);
  std::vector<std::string> paths;
  if (FAILED(hr)) {
    if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
      return paths;  // User cancelled: empty list, not an error.
    }
    throw std::runtime_error("the dialog failed");
  }
  if (args.multi_select) {
    ComPtr<IFileOpenDialog> open_dialog;
    HRESULT qhr = file_dialog->QueryInterface(IID_PPV_ARGS(&open_dialog));
    if (FAILED(qhr) || !open_dialog) {
      throw std::runtime_error("QueryInterface failed");
    }
    ComPtr<IShellItemArray> items;
    if (FAILED(open_dialog->GetResults(&items)) || !items) {
      throw std::runtime_error("GetResults failed");
    }
    DWORD count = 0;
    items->GetCount(&count);
    for (DWORD i = 0; i < count; ++i) {
      ComPtr<IShellItem> entry;
      if (FAILED(items->GetItemAt(i, &entry)) || !entry) {
        throw std::runtime_error("result extraction failed");
      }
      PWSTR path = nullptr;
      if (FAILED(entry->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
        throw std::runtime_error("result extraction failed");
      }
      std::string converted = WideToUtf8(path);
      CoTaskMemFree(path);
      if (converted.empty()) {
        throw std::runtime_error("path conversion failed");
      }
      paths.push_back(std::move(converted));
    }
  } else {
    ComPtr<IShellItem> item;
    if (FAILED(file_dialog->GetResult(&item)) || !item) {
      throw std::runtime_error("GetResult failed");
    }
    PWSTR path = nullptr;
    if (FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
      throw std::runtime_error("result extraction failed");
    }
    std::string converted = WideToUtf8(path);
    CoTaskMemFree(path);
    if (converted.empty()) {
      throw std::runtime_error("path conversion failed");
    }
    paths.push_back(std::move(converted));
  }
  return paths;
}

void ReplyWith(MethodChannel& channel, const std::string& method,
               const std::optional<std::vector<std::string>>& paths,
               std::unique_ptr<MethodResult> reply, HWND owner) {
  if (!IsWindow(owner)) {
    // The application window is gone; replying would touch a dead engine.
    return;
  }
  if (!paths.has_value()) {
    reply->Error("dialog_error",
                 "The file dialog could not be shown. A mapped or network "
                 "location may be unreachable.");
    return;
  }
  if (method == "openFiles") {
    EncodableList list;
    for (const auto& path : *paths) list.emplace_back(path);
    reply->Success(EncodableValue(list));
    return;
  }
  if (!paths->empty()) {
    reply->Success(EncodableValue((*paths)[0]));
  } else {
    reply->Success(EncodableValue());
  }
}

}  // namespace

void Register(flutter::FlutterEngine* engine, HWND owner) {
  auto channel = std::make_shared<MethodChannel>(
      engine->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [channel, owner](const flutter::MethodCall<EncodableValue>& call,
                       std::unique_ptr<MethodResult> reply) {
        // Platform thread.
        {
          std::lock_guard<std::mutex> lock(s_state_mutex);
          if (s_session_active) {
            reply->Error("dialog_already_open",
                         "The previous file dialog has not been closed yet.");
            return;
          }
          if (!IsWindow(owner)) {
            reply->Error("app_closing", "The application window is closing.");
            return;
          }
          s_session_active = true;
          s_session_owner.store(owner);
          // Platform-thread restore watchdog: independent of the picker
          // thread's pump, so a wedged shell cannot leave the window grey.
          // Dropped by finish() on every completed path.
          SetTimer(owner, kRestoreTimerId, kRestoreWatchdogMs,
                   &RestoreTimerProc);
        }
        EncodableMap args_map;
        if (call.arguments() != nullptr) {
          if (const auto* map = std::get_if<EncodableMap>(call.arguments())) {
            args_map = *map;
          }
        }
        PickerArgs args = ParseArgs(args_map, call.method_name());
        // Release the session slot on every exit path below; the picker
        // thread itself cannot be terminated safely once Show is running.
        // The boxed reply lives outside the spawn closure so a failed
        // thread creation can still answer the pending call.
        auto reply_box = std::make_shared<std::unique_ptr<MethodResult>>(
            std::move(reply));
        auto finish = [channel, owner,
                       method = call.method_name(),
                       reply_box](std::optional<std::vector<std::string>>
                                      paths) {
          // Platform thread: drops the restore timer, answers the call and
          // releases the session slot on every completed path.
          KillTimer(owner, kRestoreTimerId);
          ReplyWith(*channel, method, paths, std::move(*reply_box), owner);
          std::lock_guard<std::mutex> lock(s_state_mutex);
          s_session_active = false;
        };
        auto spawn = [channel, owner, method = call.method_name(), args,
                      finish]() mutable {
          s_session_owner.store(owner);
          std::optional<std::vector<std::string>> paths;
          // COM init/uninit strictly paired on this thread.
          HRESULT com_init = CoInitializeEx(nullptr,
                                            COINIT_APARTMENTTHREADED |
                                                COINIT_DISABLE_OLE1DDE);
          struct ComGuard {
            bool active;
            ~ComGuard() {
              if (active) CoUninitialize();
            }
          } com_guard{SUCCEEDED(com_init)};
          if (!com_guard.active) {
            // COM unavailable on this thread: hand the failure to the
            // platform thread so the call is answered with an error and the
            // session slot is released.
            s_session_owner.store(nullptr);
            Win32Window::PostUiTask(owner, [finish]() mutable {
              finish(std::nullopt);
            });
            return;
          }
          try {
            // Bounded cancel: this thread timer fires inside the dialog's
            // own message pump (see CancelTimerProc) even while Show runs,
            // so a stuck shell leaves the window disabled at most until it
            // runs.
            const UINT_PTR cancel_timer = SetTimer(
                nullptr, kCancelTimerId, kDialogWatchdogMs, &CancelTimerProc);
            try {
              paths = ShowDialog(args, owner);
            } catch (...) {
              paths.reset();
            }
            if (cancel_timer) {
              KillTimer(nullptr, cancel_timer);
            }
          } catch (...) {
            paths.reset();
          }
          s_session_owner.store(nullptr);
          if (!IsWindow(owner)) {
            return;
          }
          Win32Window::PostUiTask(
              owner,
              [finish, paths = std::move(paths)]() mutable {
                finish(std::move(paths));
              });
        };
        try {
          std::thread(std::move(spawn)).detach();
        } catch (...) {
          // The failed constructor moved the spawn closure away, but the
          // outer reply_box still owns the pending reply.
          s_session_owner.store(nullptr);
          finish(std::nullopt);
        }
      });
}

}  // namespace file_dialog
