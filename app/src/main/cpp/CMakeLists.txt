cmake_minimum_required(VERSION 3.22.1)
project("touchgrab")

# 随包的小帮助程序：以 root 运行，负责 EVIOCGRAB 独占触摸并把 14 字节帧写到 stdout。
# 名字故意做成 lib*.so → AGP 会打进 APK 的 lib/<abi>/，安装时解压到 nativeLibraryDir 且带可执行位。
add_executable(touchgrabfwd touch_fwd_main.cpp)
set_target_properties(touchgrabfwd PROPERTIES
        PREFIX "lib"
        SUFFIX ".so"
        POSITION_INDEPENDENT_CODE ON)
