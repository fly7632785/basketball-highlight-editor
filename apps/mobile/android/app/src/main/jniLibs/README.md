将构建产物放在对应 ABI 目录后，Gradle 会自动启用 Rust JNI bridge：

```text
arm64-v8a/libbhe_runtime.so
arm64-v8a/libonnxruntime.so
```

`libbhe_runtime_jni.so` 由 `externalNativeBuild` 编译，不提交二进制文件。
