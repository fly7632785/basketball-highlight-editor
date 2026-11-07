#include "file_dialog.h"

#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shlobj.h>

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

constexpr char kChannelName[] = "bhe/native_file_dialog";

// Matches the Dart-side escape hatch in ThreadedFileSelectorWindows: after
// this delay the watchdog tries to close a stuck dialog with IDCANCEL so the
// session slot is released and the user can retry.
constexpr DWORD kDialogWatchdogMs = 90 * 1000;

// Single-dialog policy: at most one native picker at a time, owned by the
// main window. A picker whose shell call never returns keeps the slot until
// the app restarts; further requests fail fast with dialog_already_open
// instead of stacking threads and unowned windows.
std::mutex s_state_mutex;
bool s_session_active = false;
std::atomic<DWORD> s_dialog_thread_id(0);
std::atomic<ULONG> s_session_generation(0);

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

// Runs on the dedicated STA thread. Throws on unexpected failures so the
// caller reports an error instead of mistaking them for a cancellation;
// returns an empty vector when the user cancels.
// Precondition: the calling thread has initialized COM (the picker thread
// body does so before invoking this function).
std::vector<std::string> ShowDialog(const PickerArgs& args, HWND owner) {
  IModalWindow* modal = nullptr;
  IFileDialog* file_dialog = nullptr;
  // Save flows need IFileSaveDialog so users can type brand-new names;
  // FOS_FILEMUSTEXIST would lock them to existing files.
  if (args.save) {
    IFileSaveDialog* save_dialog = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_FileSaveDialog, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&save_dialog));
    if (FAILED(hr)) throw std::runtime_error("CoCreateInstance failed");
    modal = save_dialog;
    file_dialog = save_dialog;
  } else {
    IFileOpenDialog* open_dialog = nullptr;
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
  ApplyFileTypes(file_dialog, args);
  if (args.save && !args.initial_name.empty()) {
    file_dialog->SetFileName(args.initial_name.c_str());
  }
  if (!args.pick_folder && !args.initial_directory.empty()) {
    IShellItem* folder = nullptr;
    HRESULT hr = SHCreateItemFromParsingName(args.initial_directory.c_str(),
                                             nullptr, IID_PPV_ARGS(&folder));
    if (SUCCEEDED(hr) && folder) {
      file_dialog->SetFolder(folder);
      folder->Release();
    }
  }
  if (!args.ok_label.empty()) {
    file_dialog->SetOkButtonLabel(args.ok_label.c_str());
  }
  // Owned by the main window: IFileDialog disables it for the whole modal
  // phase and restores it afterwards, on every path including cancellation.
  HRESULT hr = modal->Show(owner);
  std::vector<std::string> paths;
  if (SUCCEEDED(hr)) {
    IShellItemArray* items = nullptr;
    IShellItem* item = nullptr;
    bool extraction_failed = false;
    if (args.multi_select) {
      IFileOpenDialog* open_dialog = nullptr;
      if (FAILED(file_dialog->QueryInterface(IID_PPV_ARGS(&open_dialog))) ||
          !open_dialog) {
        throw std::runtime_error("QueryInterface failed");
      }
      hr = open_dialog->GetResults(&items);
      open_dialog->Release();
      if (FAILED(hr)) throw std::runtime_error("GetResults failed");
      DWORD count = 0;
      items->GetCount(&count);
      for (DWORD i = 0; i < count; ++i) {
        IShellItem* entry = nullptr;
        if (FAILED(items->GetItemAt(i, &entry)) || !entry) {
          extraction_failed = true;
          break;
        }
        PWSTR path = nullptr;
        if (FAILED(entry->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
          entry->Release();
          extraction_failed = true;
          break;
        }
        paths.push_back(WideToUtf8(path));
        CoTaskMemFree(path);
        entry->Release();
      }
    } else {
      if (FAILED(file_dialog->GetResult(&item)) || !item) {
        extraction_failed = true;
      } else {
        PWSTR path = nullptr;
        if (FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
          extraction_failed = true;
        } else {
          paths.push_back(WideToUtf8(path));
          CoTaskMemFree(path);
        }
        item->Release();
      }
    }
    if (items) items->Release();
    if (item) item->Release();
    if (extraction_failed) {
      throw std::runtime_error("result extraction failed");
    }
  } else if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    // User cancelled: empty list, not an error.
  } else {
    throw std::runtime_error("the dialog was dismissed by an error");
  }
  return paths;
}

// Closes common item dialogs (#32770) owned by the picker thread with
// IDCANCEL so a stuck-but-responsive picker unblocks and the session slot is
// released. Returns true if a dialog window was found.
bool CloseStuckDialogs(DWORD thread_id) {
  struct Context {
    DWORD thread_id;
    bool found = false;
  } context{thread_id, false};
  EnumWindows(
      [](HWND hwnd, LPARAM lParam) -> BOOL {
        auto* ctx = reinterpret_cast<Context*>(lParam);
        DWORD pid = 0;
        if (GetWindowThreadProcessId(hwnd, &pid) != ctx->thread_id) {
          return TRUE;
        }
        wchar_t class_name[16] = {};
        if (!GetClassNameW(hwnd, class_name, 16) ||
            wcscmp(class_name, L"#32770") != 0) {
          return TRUE;
        }
        PostMessageW(hwnd, WM_COMMAND, MAKEWPARAM(IDCANCEL, 0), 0);
        ctx->found = true;
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&context));
  return context.found;
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
          s_session_generation++;
        }
        const ULONG generation = s_session_generation.load();
        EncodableMap args_map;
        if (call.arguments() != nullptr) {
          if (const auto* map = std::get_if<EncodableMap>(call.arguments())) {
            args_map = *map;
          }
        }
        PickerArgs args = ParseArgs(args_map, call.method_name());
        std::thread(
            [channel, owner, method = call.method_name(), args, generation,
             reply = std::move(reply)]() mutable {
              s_dialog_thread_id = GetCurrentThreadId();
              // Release the session slot on every exit path, including the
              // unexpected ones below.
              struct SessionGuard {
                ~SessionGuard() {
                  std::lock_guard<std::mutex> lock(s_state_mutex);
                  s_session_active = false;
                }
              } session_guard;
              HRESULT init = CoInitializeEx(nullptr,
                                            COINIT_APARTMENTTHREADED |
                                                COINIT_DISABLE_OLE1DDE);
              if (FAILED(init)) {
                auto boxed_reply =
                    std::make_shared<std::unique_ptr<MethodResult>>(
                        std::move(reply));
                Win32Window::PostUiTask(
                    owner,
                    [channel, owner, method, boxed_reply]() {
                      ReplyWith(*channel, method, std::nullopt,
                                std::move(*boxed_reply), owner);
                    });
                return;
              }
              // Watchdog: mirrors the Dart escape hatch. Closes a stuck but
              // responsive dialog with IDCANCEL; a dialog stuck before any
              // window exists cannot be closed this way, so its session slot
              // intentionally stays taken until the app restarts.
              std::thread(
                  [owner, generation]() {
                    Sleep(kDialogWatchdogMs);
                    std::lock_guard<std::mutex> lock(s_state_mutex);
                    if (!s_session_active ||
                        s_session_generation.load() != generation) {
                      return;
                    }
                    CloseStuckDialogs(s_dialog_thread_id.load());
                  })
                  .detach();
              std::optional<std::vector<std::string>> paths;
              try {
                paths = ShowDialog(args, owner);
              } catch (...) {
                paths.reset();
              }
              CoUninitialize();
              if (!IsWindow(owner)) {
                return;
              }
              // std::function needs copyable callables; box the move-only
              // pieces.
              auto boxed_reply =
                  std::make_shared<std::unique_ptr<MethodResult>>(
                      std::move(reply));
              auto boxed_paths =
                  std::make_shared<std::optional<std::vector<std::string>>>(
                      std::move(paths));
              Win32Window::PostUiTask(
                  owner,
                  [channel, owner, method, boxed_paths, boxed_reply]() {
                    ReplyWith(*channel, method, *boxed_paths,
                              std::move(*boxed_reply), owner);
                  });
            })
            .detach();
      });
}

}  // namespace file_dialog
