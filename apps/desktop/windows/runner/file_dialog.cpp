#include "file_dialog.h"

#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shobjidl_core.h>

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
using MethodChannel =
    flutter::MethodChannel<flutter::EncodableValue>;
using MethodResult = flutter::MethodResult<flutter::EncodableValue>;

constexpr char kChannelName[] = "bhe/native_file_dialog";

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) return std::wstring();
  int size = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                 static_cast<int>(text.size()), nullptr, 0);
  std::wstring wide(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      wide.data(), size);
  return wide;
}

std::string WideToUtf8(const wchar_t* text) {
  if (!text || !*text) return std::string();
  int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr,
                                 nullptr);
  if (size <= 1) return std::string();
  std::string narrow(size - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, narrow.data(), size - 1, nullptr,
                      nullptr);
  return narrow;
}

struct PickerArgs {
  bool save = false;
  bool pick_folder = false;
  bool multi_select = false;
  std::wstring initial_name;
  std::wstring ok_label;
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

// Runs on the dedicated STA thread. nullopt = the dialog could not be shown;
// an empty vector = the user cancelled.
std::optional<std::vector<std::string>> ShowDialog(const PickerArgs& args) {
  HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED |
                                            COINIT_DISABLE_OLE1DDE);
  std::optional<std::vector<std::string>> result;
  if (SUCCEEDED(init)) {
    IFileOpenDialog* dialog = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                  CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
    if (SUCCEEDED(hr)) {
      DWORD options = 0;
      dialog->GetOptions(&options);
      options |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
      if (args.save) options |= FOS_OVERWRITEPROMPT;
      if (args.pick_folder) {
        options |= FOS_PICKFOLDERS;
      } else {
        options |= FOS_FILEMUSTEXIST;
      }
      if (args.multi_select) options |= FOS_ALLOWMULTISELECT;
      dialog->SetOptions(options);
      if (!args.type_label.empty() && !args.extensions.empty()) {
        std::wstring pattern;
        for (size_t i = 0; i < args.extensions.size(); ++i) {
          if (i) pattern += L";";
          pattern += L"*." + args.extensions[i];
        }
        COMDLG_FILTERSPEC filters[1] = {{args.type_label.c_str(),
                                         pattern.c_str()}};
        dialog->SetFileTypes(1, filters);
        dialog->SetFileTypeIndex(1);
      }
      if (!args.initial_name.empty()) {
        dialog->SetFileName(args.initial_name.c_str());
      }
      if (!args.ok_label.empty()) {
        dialog->SetOkButtonLabel(args.ok_label.c_str());
      }
      // No owner: the dialog thread is not the owner window's thread, and the
      // Dart layer already provides the modal boundary for the flow.
      hr = dialog->Show(nullptr);
      if (SUCCEEDED(hr)) {
        std::vector<std::string> paths;
        if (args.multi_select) {
          IShellItemArray* items = nullptr;
          if (SUCCEEDED(dialog->GetResults(&items)) && items) {
            DWORD count = 0;
            items->GetCount(&count);
            for (DWORD i = 0; i < count; ++i) {
              IShellItem* item = nullptr;
              if (SUCCEEDED(items->GetItemAt(i, &item)) && item) {
                PWSTR path = nullptr;
                if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH,
                                                   &path))) {
                  paths.push_back(WideToUtf8(path));
                  CoTaskMemFree(path);
                }
                item->Release();
              }
            }
            items->Release();
          }
        } else {
          IShellItem* item = nullptr;
          if (SUCCEEDED(dialog->GetResult(&item)) && item) {
            PWSTR path = nullptr;
            if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
              paths.push_back(WideToUtf8(path));
              CoTaskMemFree(path);
            }
            item->Release();
          }
        }
        result = paths;
      } else if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
        result = std::vector<std::string>();
      }
      dialog->Release();
    }
    CoUninitialize();
  }
  return result;
}

void ReplyWith(MethodChannel& channel, const std::string& method,
               const std::optional<std::vector<std::string>>& paths,
               std::unique_ptr<MethodResult> reply) {
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
        EncodableMap args_map;
        if (call.arguments() != nullptr) {
          if (const auto* map = std::get_if<EncodableMap>(call.arguments())) {
            args_map = *map;
          }
        }
        PickerArgs args = ParseArgs(args_map, call.method_name());
        std::thread(
            [channel, owner, method = call.method_name(), args,
             reply = std::move(reply)]() mutable {
              auto paths = ShowDialog(args);
              // std::function requires copyable callables; box the
              // move-only reply in a shared_ptr.
              auto boxed_reply =
                  std::make_shared<std::unique_ptr<MethodResult>>(
                      std::move(reply));
              Win32Window::PostUiTask(
                  owner,
                  [channel, method, paths, boxed_reply]() {
                    ReplyWith(*channel, method, paths,
                              std::move(*boxed_reply));
                  });
            })
            .detach();
      });
}

}  // namespace file_dialog
