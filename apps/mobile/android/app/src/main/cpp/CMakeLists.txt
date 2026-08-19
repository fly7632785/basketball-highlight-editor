cmake_minimum_required(VERSION 3.22.1)
project(bhe_runtime_jni)

add_library(bhe_runtime SHARED IMPORTED)
set_target_properties(bhe_runtime PROPERTIES
    IMPORTED_LOCATION "${CMAKE_CURRENT_LIST_DIR}/../jniLibs/${ANDROID_ABI}/libbhe_runtime.so"
)

add_library(bhe_runtime_jni SHARED bhe_runtime_jni.cpp)
find_library(log-lib log)
target_link_libraries(bhe_runtime_jni bhe_runtime ${log-lib})
