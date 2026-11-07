#ifndef RUNNER_FILE_DIALOG_H_
#define RUNNER_FILE_DIALOG_H_

#include <windows.h>

namespace flutter {
class FlutterEngine;
}

namespace file_dialog {

// Registers the bhe/native_file_dialog method channel. Pickers run on a
// dedicated STA thread with their own message pump: when the shell stalls
// (for example on a half-dead mapped network drive), only the dialog thread
// waits while the platform thread keeps pumping and the UI stays operable.
// file_selector_windows runs IFileDialog on the platform thread, where the
// same stall freezes the whole application.
void Register(flutter::FlutterEngine* engine, HWND owner);

}  // namespace file_dialog

#endif  // RUNNER_FILE_DIALOG_H_
