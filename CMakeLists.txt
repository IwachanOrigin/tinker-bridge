cmake_minimum_required(VERSION 3.16)
project(tinker-bridge CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# WSL側サーバー
add_executable(tinker-server
    src/server/main.cpp
)
target_include_directories(tinker-server PRIVATE src/common)
target_link_libraries(tinker-server PRIVATE pthread)

# ブリッジ（WSL内で動かしてTCPをUnix socketに中継）
add_executable(tinker-bridge
    src/client/main.cpp
)
target_include_directories(tinker-bridge PRIVATE src/common)
target_link_libraries(tinker-bridge PRIVATE pthread)
