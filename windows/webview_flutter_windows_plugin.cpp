#include <WebView2.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <wrl.h>

#include <cmath>
#include <cstdint>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "include/webview_flutter_windows/web_view_flutter_windows_plugin.h"

namespace webview_flutter_windows {
namespace {

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Result = flutter::MethodResult<Value>;
using Channel = flutter::MethodChannel<Value>;
constexpr char kChannel[] = "plugins.flutter.io/webview_flutter_windows";

std::wstring Wide(const std::string& value) {
  if (value.empty()) {
    return {};
  }
  int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                                   static_cast<int>(value.size()), nullptr, 0);
  if (!length) {
    throw std::invalid_argument("Invalid UTF-8 string.");
  }
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), length);
  return result;
}

std::string Utf8(const wchar_t* value) {
  if (!value || !*value) {
    return {};
  }
  int length =
      WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
  std::string result(length, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, -1, result.data(), length, nullptr,
                      nullptr);
  result.pop_back();
  return result;
}

std::string TakeString(LPWSTR value) {
  std::string result = Utf8(value);
  CoTaskMemFree(value);
  return result;
}

std::wstring ProfileFolder(const std::string& value) {
  const auto path = Wide(value);
  const bool drive_absolute = path.size() >= 3 &&
                              ((path[0] >= L'A' && path[0] <= L'Z') ||
                               (path[0] >= L'a' && path[0] <= L'z')) &&
                              path[1] == L':' &&
                              (path[2] == L'\\' || path[2] == L'/');
  if (value.find('\0') != std::string::npos ||
      (!drive_absolute && !PathIsUNCW(path.c_str()))) {
    throw std::invalid_argument("The profile folder must be an absolute path.");
  }
  const DWORD size = GetFullPathNameW(path.c_str(), 0, nullptr, nullptr);
  if (!size) {
    throw std::invalid_argument("Invalid profile folder.");
  }
  std::wstring full(size, L'\0');
  const DWORD written =
      GetFullPathNameW(path.c_str(), size, full.data(), nullptr);
  if (!written || written >= size) {
    throw std::invalid_argument("Invalid profile folder.");
  }
  full.resize(written);
  while (!full.empty() && full.back() == L'\\' && !PathIsRootW(full.c_str())) {
    full.pop_back();
  }
  return full;
}

bool SameFolder(const std::wstring& left, const std::wstring& right) {
  return CompareStringOrdinal(left.c_str(), -1, right.c_str(), -1, TRUE) ==
         CSTR_EQUAL;
}

const Value& Field(const Map& args, const char* key) {
  const auto entry = args.find(Value(key));
  if (entry == args.end()) {
    throw std::invalid_argument(std::string("Missing argument: ") + key);
  }
  return entry->second;
}

template <class T>
const T& Get(const Map& args, const char* key) {
  const auto* value = std::get_if<T>(&Field(args, key));
  if (!value) {
    throw std::invalid_argument(std::string("Invalid argument: ") + key);
  }
  return *value;
}

int64_t Integer(const Map& args, const char* key) {
  const Value& value = Field(args, key);
  if (const auto* number = std::get_if<int32_t>(&value)) {
    return *number;
  }
  if (const auto* number = std::get_if<int64_t>(&value)) {
    return *number;
  }
  throw std::invalid_argument(std::string("Invalid integer: ") + key);
}

bool Check(HRESULT hr, const std::shared_ptr<Result>& result,
           const char* operation) {
  if (SUCCEEDED(hr)) {
    return true;
  }
  std::ostringstream message;
  message << operation << " failed (HRESULT 0x" << std::hex
          << static_cast<unsigned long>(hr) << ").";
  result->Error("webview2Error", message.str());
  return false;
}

void Complete(HRESULT hr, const std::shared_ptr<Result>& result,
              const char* operation) {
  if (Check(hr, result, operation)) {
    result->Success();
  }
}

struct View {
  ComPtr<ICoreWebView2Controller> controller;
  ComPtr<ICoreWebView2> webview;
  ComPtr<ICoreWebView2_2> webview2;
  ComPtr<ICoreWebView2_21> webview21;
  ComPtr<ICoreWebView2Settings> settings;
  std::unique_ptr<Channel> events;
  std::wstring default_user_agent;
  bool navigated = false;
  bool closed = false;

  ~View() { Close(); }

  void Close() {
    if (!closed) {
      closed = true;
      if (controller) {
        controller->Close();
      }
      events.reset();
    }
  }

  void Emit(const char* method, Value value) {
    if (!closed && events) {
      events->InvokeMethod(method, std::make_unique<Value>(std::move(value)));
    }
  }

  std::string Url() {
    LPWSTR url = nullptr;
    if (FAILED(webview->get_Source(&url))) {
      return {};
    }
    return TakeString(url);
  }

  HRESULT ForwardMessage(ICoreWebView2WebMessageReceivedEventArgs* args) {
    LPWSTR json = nullptr;
    const HRESULT hr = args->get_WebMessageAsJson(&json);
    if (SUCCEEDED(hr)) {
      Emit("webMessage", Value(TakeString(json)));
    }
    return hr;
  }
};

class State : public std::enable_shared_from_this<State> {
 public:
  explicit State(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar) {}

  ~State() {
    for (auto& entry : views_) {
      entry.second->Close();
    }
    if (cookie_view_) {
      cookie_view_->Close();
    }
  }

  void NotifyParentWindowPositionChanged() {
    for (const auto& entry : views_) {
      const auto& view = entry.second;
      const HRESULT hr = view->controller->NotifyParentWindowPositionChanged();
      if (FAILED(hr)) {
        view->Emit(
            "webResourceError",
            Value(Map{
                {Value("errorCode"), Value(static_cast<int32_t>(hr))},
                {Value("description"),
                 Value("Unable to update the WebView2 window position.")},
                {Value("url"), Value(view->Url())},
            }));
      }
    }
  }

  void Handle(const flutter::MethodCall<Value>& call,
              std::shared_ptr<Result> result) {
    try {
      const std::string method = call.method_name();
      if (method == "create") {
        const int64_t id = next_id_++;
        CreateView(id, [weak = weak_from_this(), id, result](
                           HRESULT hr, std::shared_ptr<View> view) {
          if (const auto state = weak.lock()) {
            if (Check(hr, result,
                      "Create WebView2; install or update the WebView2 "
                      "Runtime")) {
              state->views_[id] = std::move(view);
              result->Success(Value(id));
            }
          }
        });
        return;
      }
      const auto* args =
          call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      const Map empty;
      if (method == "initializeEnvironment") {
        InitializeEnvironment(args ? *args : empty, result);
        return;
      }
      if (method == "setCookie" || method == "getCookies" ||
          method == "clearCookies") {
        CookieCommand(method, args ? *args : empty, result);
        return;
      }
      if (!args) {
        throw std::invalid_argument("Expected an argument map.");
      }
      const int64_t id = Integer(*args, "id");
      const auto entry = views_.find(id);
      if (entry == views_.end()) {
        result->Error("unknownWebView",
                      "The WebView2 controller does not exist.");
        return;
      }
      if (method == "dispose") {
        entry->second->Close();
        views_.erase(entry);
        result->Success();
        return;
      }
      Command(entry->second, method, *args, result);
    } catch (const std::invalid_argument& error) {
      result->Error("invalidArgument", error.what());
    }
  }

 private:
  using ViewCallback = std::function<void(HRESULT, std::shared_ptr<View>)>;
  flutter::PluginRegistrarWindows* registrar_;
  ComPtr<ICoreWebView2Environment> environment_;
  std::wstring user_data_folder_;
  bool environment_selected_ = false;
  bool custom_folder_ = false;
  bool profile_mismatch_ = false;
  bool environment_pending_ = false;
  std::vector<std::function<void(HRESULT)>> environment_callbacks_;
  std::map<int64_t, std::shared_ptr<View>> views_;
  int64_t next_id_ = 1;
  std::shared_ptr<View> cookie_view_;
  bool cookie_pending_ = false;
  std::vector<ViewCallback> cookie_callbacks_;

  void InitializeEnvironment(const Map& args, std::shared_ptr<Result> result) {
    if (args.find(Value("userDataFolder")) != args.end()) {
      const auto folder =
          ProfileFolder(Get<std::string>(args, "userDataFolder"));
      if (environment_selected_ && !SameFolder(folder, user_data_folder_)) {
        result->Error("environmentAlreadyInitialized",
                      "Select the profile before using a controller or cookie "
                      "manager. The active profile cannot be changed.");
        return;
      }
      user_data_folder_ = folder;
      custom_folder_ = true;
    }
    Environment([weak = weak_from_this(), result](HRESULT hr) {
      if (const auto state = weak.lock()) {
        if (state->profile_mismatch_) {
          result->Error("environmentProfileMismatch",
                        "WebView2 selected a different profile. Check WebView2 "
                        "environment overrides.");
          return;
        }
        if (!Check(hr, result,
                   "Initialize WebView2; check runtime and profile")) {
          return;
        }
        LPWSTR version = nullptr;
        if (Check(state->environment_->get_BrowserVersionString(&version),
                  result, "Read WebView2 runtime version")) {
          result->Success(Value(TakeString(version)));
        }
      }
    });
  }

  void Environment(std::function<void(HRESULT)> callback) {
    if (environment_) {
      callback(custom_folder_ ? VerifyProfile(environment_.Get()) : S_OK);
      return;
    }
    environment_callbacks_.push_back(std::move(callback));
    if (environment_pending_) {
      return;
    }
    environment_pending_ = true;
    environment_selected_ = true;
    HRESULT hr = S_OK;
    if (user_data_folder_.empty()) {
      PWSTR local_data = nullptr;
      hr = SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local_data);
      if (FAILED(hr)) {
        EnvironmentReady(hr, nullptr);
        return;
      }
      // Isolate the shared profile by executable path, not by install-directory
      // writability. A stable hash avoids MAX_PATH and invalid filename issues.
      wchar_t executable[32768] = {};
      const DWORD length = GetModuleFileNameW(nullptr, executable, 32768);
      uint64_t hash = 14695981039346656037ULL;
      for (DWORD i = 0; i < length; ++i) {
        hash ^= static_cast<uint64_t>(executable[i]);
        hash *= 1099511628211ULL;
      }
      user_data_folder_ = std::wstring(local_data) + L"\\flutter_webview\\" +
                          std::to_wstring(hash);
      CoTaskMemFree(local_data);
    }
    const int created =
        SHCreateDirectoryExW(nullptr, user_data_folder_.c_str(), nullptr);
    if (created != ERROR_SUCCESS && created != ERROR_ALREADY_EXISTS &&
        created != ERROR_FILE_EXISTS) {
      EnvironmentReady(HRESULT_FROM_WIN32(created), nullptr);
      return;
    }
    const DWORD attributes = GetFileAttributesW(user_data_folder_.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES) {
      EnvironmentReady(HRESULT_FROM_WIN32(GetLastError()), nullptr);
      return;
    }
    if (!(attributes & FILE_ATTRIBUTE_DIRECTORY)) {
      EnvironmentReady(HRESULT_FROM_WIN32(ERROR_DIRECTORY), nullptr);
      return;
    }
    hr = CreateCoreWebView2EnvironmentWithOptions(
        nullptr, user_data_folder_.c_str(), nullptr,
        Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
            [weak = weak_from_this()](HRESULT error,
                                      ICoreWebView2Environment* environment) {
              if (auto state = weak.lock()) {
                state->EnvironmentReady(error, environment);
              }
              return S_OK;
            })
            .Get());
    if (FAILED(hr)) {
      EnvironmentReady(hr, nullptr);
    }
  }

  HRESULT VerifyProfile(ICoreWebView2Environment* environment) {
    profile_mismatch_ = false;
    ComPtr<ICoreWebView2Environment7> environment7;
    HRESULT hr = environment->QueryInterface(IID_PPV_ARGS(&environment7));
    LPWSTR actual = nullptr;
    if (SUCCEEDED(hr)) {
      hr = environment7->get_UserDataFolder(&actual);
    }
    if (SUCCEEDED(hr)) {
      try {
        profile_mismatch_ =
            !SameFolder(ProfileFolder(Utf8(actual)), user_data_folder_);
        if (profile_mismatch_) hr = E_INVALIDARG;
      } catch (const std::invalid_argument&) {
        hr = E_INVALIDARG;
      }
    }
    CoTaskMemFree(actual);
    return hr;
  }

  void EnvironmentReady(HRESULT hr, ICoreWebView2Environment* environment) {
    if (SUCCEEDED(hr) && !environment) {
      hr = E_POINTER;
    }
    if (SUCCEEDED(hr) && custom_folder_) {
      hr = VerifyProfile(environment);
    }
    environment_ = SUCCEEDED(hr) ? environment : nullptr;
    environment_pending_ = false;
    auto callbacks = std::move(environment_callbacks_);
    environment_callbacks_.clear();
    for (auto& callback : callbacks) {
      callback(hr);
    }
  }

  void CreateView(int64_t id, ViewCallback callback) {
    Environment([weak = weak_from_this(), id, callback](HRESULT error) {
      const auto state = weak.lock();
      if (!state) {
        return;
      }
      if (FAILED(error)) {
        callback(error, nullptr);
        return;
      }
      const auto flutter_view = state->registrar_->GetViewById(0);
      if (!flutter_view) {
        callback(E_HANDLE, nullptr);
        return;
      }
      const HRESULT hr = state->environment_->CreateCoreWebView2Controller(
          flutter_view->GetNativeWindow(),
          Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
              [weak, id, callback](HRESULT error,
                                   ICoreWebView2Controller* controller) {
                const auto state = weak.lock();
                if (!state) {
                  if (controller) {
                    controller->Close();
                  }
                  return S_OK;
                }
                if (FAILED(error) || !controller) {
                  callback(FAILED(error) ? error : E_POINTER, nullptr);
                  return S_OK;
                }
                auto view = std::make_shared<View>();
                view->controller = controller;
                HRESULT hr = controller->put_IsVisible(FALSE);
                if (SUCCEEDED(hr)) {
                  hr = controller->get_CoreWebView2(&view->webview);
                }
                if (SUCCEEDED(hr)) {
                  hr = view->webview.As(&view->webview2);
                }
                if (SUCCEEDED(hr)) {
                  hr = view->webview.As(&view->webview21);
                }
                if (SUCCEEDED(hr)) {
                  hr = view->webview->get_Settings(&view->settings);
                }
                if (SUCCEEDED(hr)) {
                  hr = view->settings->put_IsScriptEnabled(FALSE);
                }
                ComPtr<ICoreWebView2Settings2> settings2;
                if (SUCCEEDED(hr)) {
                  hr = view->settings.As(&settings2);
                }
                if (SUCCEEDED(hr)) {
                  LPWSTR agent = nullptr;
                  hr = settings2->get_UserAgent(&agent);
                  if (SUCCEEDED(hr)) {
                    view->default_user_agent = agent;
                  }
                  CoTaskMemFree(agent);
                }
                if (SUCCEEDED(hr) && id != 0) {
                  view->events = std::make_unique<Channel>(
                      state->registrar_->messenger(),
                      std::string(kChannel) + "/" + std::to_string(id),
                      &flutter::StandardMethodCodec::GetInstance());
                  hr = state->RegisterEvents(view);
                }
                callback(hr, SUCCEEDED(hr) ? view : nullptr);
                return S_OK;
              })
              .Get());
      if (FAILED(hr)) {
        callback(hr, nullptr);
      }
    });
  }

  HRESULT RegisterEvents(const std::shared_ptr<View>& view) {
    const std::weak_ptr<View> weak = view;
    EventRegistrationToken token{};
    HRESULT hr = view->controller->add_GotFocus(
        Callback<ICoreWebView2FocusChangedEventHandler>(
            [weak](ICoreWebView2Controller*, IUnknown*) {
              if (auto view = weak.lock()) {
                view->Emit("gotFocus", Value());
              }
              return S_OK;
            })
            .Get(),
        &token);
    if (FAILED(hr)) {
      return hr;
    }
    hr = view->controller->add_MoveFocusRequested(
        Callback<ICoreWebView2MoveFocusRequestedEventHandler>(
            [weak](ICoreWebView2Controller*,
                   ICoreWebView2MoveFocusRequestedEventArgs* args) {
              if (auto view = weak.lock()) {
                COREWEBVIEW2_MOVE_FOCUS_REASON reason;
                HRESULT hr = args->get_Reason(&reason);
                if (FAILED(hr)) {
                  return hr;
                }
                hr = args->put_Handled(TRUE);
                if (SUCCEEDED(hr)) {
                  view->Emit(
                      "moveFocus",
                      Value(reason == COREWEBVIEW2_MOVE_FOCUS_REASON_PREVIOUS));
                }
                return hr;
              }
              return S_OK;
            })
            .Get(),
        &token);
    if (FAILED(hr)) {
      return hr;
    }
    hr = view->webview->add_NavigationStarting(
        Callback<ICoreWebView2NavigationStartingEventHandler>(
            [weak](ICoreWebView2*,
                   ICoreWebView2NavigationStartingEventArgs* args) {
              if (auto view = weak.lock()) {
                LPWSTR url = nullptr;
                const HRESULT hr = args->get_Uri(&url);
                if (FAILED(hr)) {
                  return hr;
                }
                view->navigated = true;
                view->Emit("pageStarted", Value(TakeString(url)));
              }
              return S_OK;
            })
            .Get(),
        &token);
    if (FAILED(hr)) {
      return hr;
    }
    hr = view->webview->add_SourceChanged(
        Callback<ICoreWebView2SourceChangedEventHandler>(
            [weak](ICoreWebView2*, ICoreWebView2SourceChangedEventArgs*) {
              if (auto view = weak.lock()) {
                view->Emit("urlChanged", Value(view->Url()));
              }
              return S_OK;
            })
            .Get(),
        &token);
    if (FAILED(hr)) {
      return hr;
    }
    hr = view->webview->add_NavigationCompleted(
        Callback<ICoreWebView2NavigationCompletedEventHandler>(
            [weak](ICoreWebView2*,
                   ICoreWebView2NavigationCompletedEventArgs* args) {
              if (auto view = weak.lock()) {
                BOOL success = FALSE;
                HRESULT hr = args->get_IsSuccess(&success);
                if (FAILED(hr)) {
                  return hr;
                }
                if (success) {
                  view->Emit("pageFinished", Value(view->Url()));
                } else {
                  COREWEBVIEW2_WEB_ERROR_STATUS status;
                  hr = args->get_WebErrorStatus(&status);
                  if (FAILED(hr)) {
                    return hr;
                  }
                  view->Emit(
                      "webResourceError",
                      Value(Map{
                          {Value("errorCode"), Value(static_cast<int>(status))},
                          {Value("description"),
                           Value("WebView2 navigation failed.")},
                          {Value("url"), Value(view->Url())},
                      }));
                }
              }
              return S_OK;
            })
            .Get(),
        &token);
    if (FAILED(hr)) {
      return hr;
    }
    hr = view->webview->add_WebMessageReceived(
        Callback<ICoreWebView2WebMessageReceivedEventHandler>(
            [weak](ICoreWebView2*,
                   ICoreWebView2WebMessageReceivedEventArgs* args) {
              if (auto view = weak.lock()) {
                return view->ForwardMessage(args);
              }
              return S_OK;
            })
            .Get(),
        &token);
    if (FAILED(hr)) {
      return hr;
    }
    ComPtr<ICoreWebView2_4> webview4;
    hr = view->webview.As(&webview4);
    if (FAILED(hr)) {
      return hr;
    }
    hr = webview4->add_FrameCreated(
        Callback<ICoreWebView2FrameCreatedEventHandler>(
            [weak](ICoreWebView2*, ICoreWebView2FrameCreatedEventArgs* args) {
              ComPtr<ICoreWebView2Frame> frame;
              ComPtr<ICoreWebView2Frame2> frame2;
              HRESULT hr = args->get_Frame(&frame);
              if (SUCCEEDED(hr)) {
                hr = frame.As(&frame2);
              }
              if (FAILED(hr)) {
                return hr;
              }
              EventRegistrationToken token{};
              return frame2->add_WebMessageReceived(
                  Callback<ICoreWebView2FrameWebMessageReceivedEventHandler>(
                      [weak](ICoreWebView2Frame*,
                             ICoreWebView2WebMessageReceivedEventArgs* args) {
                        if (auto view = weak.lock()) {
                          return view->ForwardMessage(args);
                        }
                        return S_OK;
                      })
                      .Get(),
                  &token);
            })
            .Get(),
        &token);
    if (FAILED(hr)) {
      return hr;
    }
    hr = view->webview2->add_WebResourceResponseReceived(
        Callback<ICoreWebView2WebResourceResponseReceivedEventHandler>(
            [weak](ICoreWebView2*,
                   ICoreWebView2WebResourceResponseReceivedEventArgs* args) {
              if (auto view = weak.lock()) {
                ComPtr<ICoreWebView2WebResourceResponseView> response;
                HRESULT hr = args->get_Response(&response);
                int status = 0;
                if (SUCCEEDED(hr)) {
                  hr = response->get_StatusCode(&status);
                }
                if (FAILED(hr) || status < 400) {
                  return hr;
                }
                ComPtr<ICoreWebView2WebResourceRequest> request;
                hr = args->get_Request(&request);
                LPWSTR url = nullptr;
                if (SUCCEEDED(hr)) {
                  hr = request->get_Uri(&url);
                }
                if (FAILED(hr)) {
                  return hr;
                }
                view->Emit("httpError",
                           Value(Map{
                               {Value("statusCode"), Value(status)},
                               {Value("url"), Value(TakeString(url))},
                           }));
              }
              return S_OK;
            })
            .Get(),
        &token);
    if (FAILED(hr)) {
      return hr;
    }
    hr = view->webview->add_NewWindowRequested(
        Callback<ICoreWebView2NewWindowRequestedEventHandler>(
            [](ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs* args) {
              return args->put_Handled(TRUE);
            })
            .Get(),
        &token);
    if (FAILED(hr)) {
      return hr;
    }
    hr = view->webview->add_PermissionRequested(
        Callback<ICoreWebView2PermissionRequestedEventHandler>(
            [](ICoreWebView2*,
               ICoreWebView2PermissionRequestedEventArgs* args) {
              return args->put_State(COREWEBVIEW2_PERMISSION_STATE_DENY);
            })
            .Get(),
        &token);
    if (FAILED(hr)) {
      return hr;
    }
    return view->webview->add_ProcessFailed(
        Callback<ICoreWebView2ProcessFailedEventHandler>(
            [weak](ICoreWebView2*, ICoreWebView2ProcessFailedEventArgs* args) {
              if (auto view = weak.lock()) {
                COREWEBVIEW2_PROCESS_FAILED_KIND kind;
                const HRESULT hr = args->get_ProcessFailedKind(&kind);
                if (FAILED(hr)) {
                  return hr;
                }
                view->Emit(
                    "webResourceError",
                    Value(Map{
                        {Value("errorCode"), Value(static_cast<int>(kind))},
                        {Value("description"),
                         Value("A WebView2 process exited unexpectedly.")},
                        {Value("url"), Value(view->Url())},
                    }));
              }
              return S_OK;
            })
            .Get(),
        &token);
  }

  void Command(const std::shared_ptr<View>& view, const std::string& method,
               const Map& args, const std::shared_ptr<Result>& result) {
    HRESULT hr = S_OK;
    if (method == "loadHtmlString") {
      hr = view->webview->NavigateToString(
          Wide(Get<std::string>(args, "html")).c_str());
    } else if (method == "loadRequest") {
      const std::wstring url = Wide(Get<std::string>(args, "url"));
      const std::wstring verb = Wide(Get<std::string>(args, "method"));
      const Map& headers = Get<Map>(args, "headers");
      const auto* bytes =
          std::get_if<std::vector<uint8_t>>(&Field(args, "body"));
      if (verb == L"GET" && headers.empty() && (!bytes || bytes->empty())) {
        hr = view->webview->Navigate(url.c_str());
      } else {
        std::wstring header_string;
        for (const auto& header : headers) {
          const auto* name = std::get_if<std::string>(&header.first);
          const auto* value = std::get_if<std::string>(&header.second);
          if (!name || !value ||
              name->find_first_of("\r\n:") != std::string::npos ||
              value->find_first_of("\r\n") != std::string::npos) {
            throw std::invalid_argument("Invalid HTTP header.");
          }
          header_string += Wide(*name) + L": " + Wide(*value) + L"\r\n";
        }
        ComPtr<IStream> body;
        if (bytes && !bytes->empty()) {
          body.Attach(SHCreateMemStream(bytes->data(),
                                        static_cast<UINT>(bytes->size())));
          if (!body) {
            result->Error("outOfMemory",
                          "Unable to allocate the request body.");
            return;
          }
        }
        ComPtr<ICoreWebView2Environment2> environment2;
        hr = environment_.As(&environment2);
        ComPtr<ICoreWebView2WebResourceRequest> request;
        if (SUCCEEDED(hr)) {
          hr = environment2->CreateWebResourceRequest(
              url.c_str(), verb.c_str(), body.Get(), header_string.c_str(),
              &request);
        }
        if (SUCCEEDED(hr)) {
          hr = view->webview2->NavigateWithWebResourceRequest(request.Get());
        }
      }
    } else if (method == "currentUrl" || method == "getTitle") {
      if (method == "currentUrl" && !view->navigated) {
        result->Success();
        return;
      }
      LPWSTR text = nullptr;
      hr = method == "currentUrl" ? view->webview->get_Source(&text)
                                  : view->webview->get_DocumentTitle(&text);
      const std::string value = TakeString(text);
      if (Check(hr, result, method.c_str())) {
        result->Success(Value(value));
      }
      return;
    } else if (method == "canGoBack" || method == "canGoForward" ||
               method == "goBack" || method == "goForward") {
      const bool back = method == "canGoBack" || method == "goBack";
      BOOL can = FALSE;
      hr = back ? view->webview->get_CanGoBack(&can)
                : view->webview->get_CanGoForward(&can);
      if (!Check(hr, result, method.c_str())) {
        return;
      }
      if (method == "canGoBack" || method == "canGoForward") {
        result->Success(Value(can != FALSE));
        return;
      }
      if (can) {
        hr = back ? view->webview->GoBack() : view->webview->GoForward();
      }
    } else if (method == "reload") {
      hr = view->webview->Reload();
    } else if (method == "executeScript") {
      const std::wstring script = Wide(Get<std::string>(args, "script"));
      hr = view->webview21->ExecuteScriptWithResult(
          script.c_str(),
          Callback<ICoreWebView2ExecuteScriptWithResultCompletedHandler>(
              [weak = weak_from_this(), result](
                  HRESULT error,
                  ICoreWebView2ExecuteScriptResult* script_result) {
                if (!weak.lock() || !Check(error, result, "Execute script")) {
                  return S_OK;
                }
                if (!script_result) {
                  Check(E_POINTER, result, "Execute script");
                  return S_OK;
                }
                BOOL succeeded = FALSE;
                if (!Check(script_result->get_Succeeded(&succeeded), result,
                           "Read script result")) {
                  return S_OK;
                }
                LPWSTR text = nullptr;
                HRESULT hr;
                if (succeeded) {
                  hr = script_result->get_ResultAsJson(&text);
                } else {
                  ComPtr<ICoreWebView2ScriptException> exception;
                  hr = script_result->get_Exception(&exception);
                  if (SUCCEEDED(hr)) {
                    hr = exception ? exception->get_Message(&text) : E_POINTER;
                  }
                }
                const std::string value = TakeString(text);
                if (Check(hr, result, "Read script result")) {
                  if (succeeded) {
                    result->Success(Value(value));
                  } else {
                    result->Error("javaScriptError", value);
                  }
                }
                return S_OK;
              })
              .Get());
      Check(hr, result, method.c_str());
      return;
    } else if (method == "addScript") {
      const std::wstring script = Wide(Get<std::string>(args, "script"));
      auto callback = [weak = weak_from_this(), result](HRESULT error,
                                                        LPCWSTR value) {
        if (weak.lock() && Check(error, result, "JavaScript")) {
          result->Success(Value(Utf8(value)));
        }
        return S_OK;
      };
      hr = view->webview->AddScriptToExecuteOnDocumentCreated(
          script.c_str(),
          Callback<
              ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler>(
              callback)
              .Get());
      Check(hr, result, method.c_str());
      return;
    } else if (method == "removeScript") {
      hr = view->webview->RemoveScriptToExecuteOnDocumentCreated(
          Wide(Get<std::string>(args, "scriptId")).c_str());
    } else if (method == "setJavaScriptMode") {
      hr = view->settings->put_IsScriptEnabled(Get<bool>(args, "enabled"));
    } else if (method == "enableZoom") {
      hr = view->settings->put_IsZoomControlEnabled(Get<bool>(args, "enabled"));
    } else if (method == "setUserAgent" || method == "getUserAgent") {
      ComPtr<ICoreWebView2Settings2> settings;
      hr = view->settings.As(&settings);
      if (!Check(hr, result, method.c_str())) {
        return;
      }
      if (method == "setUserAgent") {
        const Value& agent = Field(args, "userAgent");
        hr = settings->put_UserAgent(
            agent.IsNull() ? view->default_user_agent.c_str()
                           : Wide(Get<std::string>(args, "userAgent")).c_str());
      } else {
        LPWSTR agent = nullptr;
        hr = settings->get_UserAgent(&agent);
        const std::string value = TakeString(agent);
        if (Check(hr, result, method.c_str())) {
          result->Success(Value(value));
        }
        return;
      }
    } else if (method == "setBackgroundColor") {
      const uint32_t color = static_cast<uint32_t>(Integer(args, "color"));
      const BYTE alpha = static_cast<BYTE>(color >> 24);
      if (alpha != 0 && alpha != 255) {
        throw std::invalid_argument(
            "WebView2 supports only transparent or opaque backgrounds.");
      }
      ComPtr<ICoreWebView2Controller2> controller;
      hr = view->controller.As(&controller);
      if (SUCCEEDED(hr)) {
        hr = controller->put_DefaultBackgroundColor(
            {alpha, static_cast<BYTE>(color >> 16),
             static_cast<BYTE>(color >> 8), static_cast<BYTE>(color)});
      }
    } else if (method == "focus") {
      if (Get<bool>(args, "focused")) {
        hr = view->controller->MoveFocus(
            Get<bool>(args, "reverse") ? COREWEBVIEW2_MOVE_FOCUS_REASON_PREVIOUS
                                       : COREWEBVIEW2_MOVE_FOCUS_REASON_NEXT);
      } else {
        const auto flutter_view = registrar_->GetViewById(0);
        if (!flutter_view) {
          hr = E_HANDLE;
        } else {
          SetFocus(flutter_view->GetNativeWindow());
        }
      }
    } else if (method == "setBounds") {
      const double left = Get<double>(args, "left");
      const double top = Get<double>(args, "top");
      const double width = Get<double>(args, "width");
      const double height = Get<double>(args, "height");
      for (double value : {left, top, left + width, top + height}) {
        if (!std::isfinite(value) || value < std::numeric_limits<LONG>::min() ||
            value > std::numeric_limits<LONG>::max()) {
          throw std::invalid_argument(
              "WebView bounds must be finite Windows coordinates.");
        }
      }
      if (width < 0 || height < 0) {
        throw std::invalid_argument(
            "WebView bounds must have non-negative size.");
      }
      const RECT bounds{static_cast<LONG>(std::round(left)),
                        static_cast<LONG>(std::round(top)),
                        static_cast<LONG>(std::round(left + width)),
                        static_cast<LONG>(std::round(top + height))};
      hr = view->controller->put_Bounds(bounds);
      if (SUCCEEDED(hr)) {
        hr = view->controller->put_IsVisible(Get<bool>(args, "visible") &&
                                             width > 0 && height > 0);
      }
      if (SUCCEEDED(hr)) {
        hr = view->controller->NotifyParentWindowPositionChanged();
      }
    } else if (method == "clearCache" || method == "clearLocalStorage") {
      ComPtr<ICoreWebView2_13> webview13;
      ComPtr<ICoreWebView2Profile> profile;
      ComPtr<ICoreWebView2Profile2> profile2;
      hr = view->webview.As(&webview13);
      if (SUCCEEDED(hr)) {
        hr = webview13->get_Profile(&profile);
      }
      if (SUCCEEDED(hr)) {
        hr = profile.As(&profile2);
      }
      if (!Check(hr, result, method.c_str())) {
        return;
      }
      const auto kinds =
          method == "clearCache"
              ? static_cast<COREWEBVIEW2_BROWSING_DATA_KINDS>(
                    COREWEBVIEW2_BROWSING_DATA_KINDS_DISK_CACHE |
                    COREWEBVIEW2_BROWSING_DATA_KINDS_CACHE_STORAGE)
              : COREWEBVIEW2_BROWSING_DATA_KINDS_LOCAL_STORAGE;
      hr = profile2->ClearBrowsingData(
          kinds, Callback<ICoreWebView2ClearBrowsingDataCompletedHandler>(
                     [weak = weak_from_this(), result](HRESULT error) {
                       if (weak.lock()) {
                         Complete(error, result, "Clear browsing data");
                       }
                       return S_OK;
                     })
                     .Get());
      Check(hr, result, method.c_str());
      return;
    } else {
      result->NotImplemented();
      return;
    }
    Complete(hr, result, method.c_str());
  }

  void CookieCommand(const std::string& method, const Map& args,
                     const std::shared_ptr<Result>& result) {
    // Validate before asynchronous initialization, so no C++ exception escapes
    // a COM callback.
    std::wstring name, value, domain, path, url;
    if (method == "setCookie") {
      name = Wide(Get<std::string>(args, "name"));
      value = Wide(Get<std::string>(args, "value"));
      domain = Wide(Get<std::string>(args, "domain"));
      path = Wide(Get<std::string>(args, "path"));
    } else if (method == "getCookies") {
      url = Wide(Get<std::string>(args, "url"));
    }
    auto action = [weak = weak_from_this(), method, result, name, value, domain,
                   path, url](HRESULT hr, std::shared_ptr<View> view) {
      if (!weak.lock() || !Check(hr, result, "Create cookie manager")) {
        return;
      }
      ComPtr<ICoreWebView2CookieManager> manager;
      hr = view->webview2->get_CookieManager(&manager);
      if (!Check(hr, result, "Get cookie manager")) {
        return;
      }
      if (method == "setCookie") {
        ComPtr<ICoreWebView2Cookie> cookie;
        hr = manager->CreateCookie(name.c_str(), value.c_str(), domain.c_str(),
                                   path.c_str(), &cookie);
        if (SUCCEEDED(hr)) {
          hr = manager->AddOrUpdateCookie(cookie.Get());
        }
        Complete(hr, result, "Set cookie");
        return;
      }
      hr = manager->GetCookies(
          url.c_str(),
          Callback<ICoreWebView2GetCookiesCompletedHandler>(
              [weak, method, result, manager](HRESULT hr,
                                              ICoreWebView2CookieList* list) {
                if (!weak.lock() || !Check(hr, result, "Get cookies")) {
                  return S_OK;
                }
                UINT count = 0;
                if (!Check(list->get_Count(&count), result, "Count cookies")) {
                  return S_OK;
                }
                if (method == "clearCookies") {
                  if (Check(manager->DeleteAllCookies(), result,
                            "Clear cookies")) {
                    result->Success(Value(count != 0));
                  }
                  return S_OK;
                }
                flutter::EncodableList cookies;
                for (UINT i = 0; i < count; ++i) {
                  ComPtr<ICoreWebView2Cookie> cookie;
                  if (!Check(list->GetValueAtIndex(i, &cookie), result,
                             "Read cookie")) {
                    return S_OK;
                  }
                  Map data;
                  for (const char* field :
                       {"name", "value", "domain", "path"}) {
                    LPWSTR text = nullptr;
                    if (std::string(field) == "name") {
                      hr = cookie->get_Name(&text);
                    } else if (std::string(field) == "value") {
                      hr = cookie->get_Value(&text);
                    } else if (std::string(field) == "domain") {
                      hr = cookie->get_Domain(&text);
                    } else {
                      hr = cookie->get_Path(&text);
                    }
                    const std::string value = TakeString(text);
                    if (!Check(hr, result, "Read cookie property")) {
                      return S_OK;
                    }
                    data[Value(field)] = Value(value);
                  }
                  cookies.emplace_back(data);
                }
                result->Success(Value(cookies));
                return S_OK;
              })
              .Get());
      Check(hr, result, "Get cookies");
    };
    if (cookie_view_) {
      action(S_OK, cookie_view_);
      return;
    }
    cookie_callbacks_.push_back(std::move(action));
    if (cookie_pending_) {
      return;
    }
    cookie_pending_ = true;
    CreateView(
        0, [weak = weak_from_this()](HRESULT hr, std::shared_ptr<View> view) {
          if (auto state = weak.lock()) {
            state->cookie_view_ = view;
            state->cookie_pending_ = false;
            auto callbacks = std::move(state->cookie_callbacks_);
            state->cookie_callbacks_.clear();
            for (auto& callback : callbacks) {
              callback(hr, view);
            }
          }
        });
  }
};

class WebViewPlugin : public flutter::Plugin {
 public:
  explicit WebViewPlugin(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar),
        state_(std::make_shared<State>(registrar)),
        channel_(registrar->messenger(), kChannel,
                 &flutter::StandardMethodCodec::GetInstance()) {
    channel_.SetMethodCallHandler(
        [this, registrar](const flutter::MethodCall<Value>& call,
                          std::unique_ptr<Result> result) {
          if (call.method_name() == "initialize") {
            state_ = std::make_shared<State>(registrar);
            result->Success();
          } else {
            state_->Handle(call, std::move(result));
          }
        });
    window_proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [this](HWND, UINT message, WPARAM, LPARAM) -> std::optional<LRESULT> {
          if (message == WM_MOVE || message == WM_MOVING) {
            state_->NotifyParentWindowPositionChanged();
          }
          return std::nullopt;
        });
  }

  ~WebViewPlugin() override {
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
    channel_.SetMethodCallHandler(nullptr);
    state_.reset();
  }

 private:
  flutter::PluginRegistrarWindows* registrar_;
  int window_proc_id_ = -1;
  std::shared_ptr<State> state_;
  Channel channel_;
};

}  // namespace
}  // namespace webview_flutter_windows

void WebViewFlutterWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  auto* windows_registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  windows_registrar->AddPlugin(
      std::make_unique<webview_flutter_windows::WebViewPlugin>(
          windows_registrar));
}
